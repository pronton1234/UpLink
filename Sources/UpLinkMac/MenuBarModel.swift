import Foundation
import Network
import NetworkExtension
import SystemExtensions
import Observation
import OSLog
import UpLinkKit

enum MacBridgeStatus: Equatable {
    case installingExtension
    case needsApproval
    case waiting
    case connected(peer: String, egress: EgressInterface)
    case failed(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// State behind the menu bar and the Devices window.
///
/// The listener and session host live in the **proxy system extension**, not
/// here: the extension owns the captured flows, and an established TLS session
/// cannot be handed across an XPC boundary. This class installs and enables
/// that extension, then talks to it over provider messages.
@MainActor
@Observable
final class MenuBarModel {

    fileprivate(set) var status: MacBridgeStatus = .waiting
    private(set) var pairedDevices: [PairedDevice] = []

    private(set) var activePairingCode: PairingCode?
    private(set) var pairingExpiresAt: Date?

    /// Multiple observers, not a single closure. The app delegate refreshes the
    /// status item and the watchdog reacts to bridge state; a lone `onChange`
    /// property meant whichever registered second silently disconnected the
    /// other.
    private var observers: [UUID: () -> Void] = [:]

    @discardableResult
    func observe(_ handler: @escaping () -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    func removeObserver(_ token: UUID) { observers.removeValue(forKey: token) }
    fileprivate func notifyObservers() { for (_, handler) in observers { handler() } }

    private let log = Logger(subsystem: UpLinkIdentifiers.logSubsystem, category: "model")
    /// The app is the only writer of durable state. The extension cannot reach
    /// the keychain (root, outside the login session), so it is seeded through
    /// providerConfiguration and reports new pairings back over the existing
    /// "devices" provider message.
    private let store = PairedDeviceStore()
    private let queue = DispatchQueue(label: "com.uplink.app.mac")

    // NOTE: no route check here, deliberately.
    //
    // It looked like a Mac with no default route could not originate anything,
    // so there would be no flow for the proxy to intercept. Measured and false:
    // during a run with Wi-Fi off, the hotspot off, and `DHCP en9: status = 'no
    // server'`, the proxy was still handed 11 TCP flows. `NETransparentProxy`
    // diverts at the socket layer, before the routing decision. A warning based
    // on that theory would have pushed the user onto the very hotspot this
    // product exists to avoid.

    private var manager: NETransparentProxyManager?
    private var pollTask: Task<Void, Never>?
    private var extensionDelegate: SystemExtensionDelegate?
    private let extensionBundleID = UpLinkIdentifiers.macProxyExtension

    // MARK: Menu text

    var statusHeadline: String {
        switch status {
        case .installingExtension: "Installing…"
        case .needsApproval: "Approval needed in System Settings"
        case .waiting: "Waiting for iPhone"
        case let .connected(peer, .cellular): "Connected — \(peer) · Cellular ✓"
        case let .connected(peer, egress): "⚠ \(peer) — via \(egress.displayName), not cellular"
        case .failed: "Something went wrong"
        }
    }

    var statusDetail: String? {
        switch status {
        case .installingExtension:
            "Setting up network routing"
        case .needsApproval:
            "System Settings → General → Login Items & Extensions → Network Extensions"
        case .waiting:
            "Open UpLink on your iPhone to start"
        case .connected(_, .cellular):
            "All apps routed — TCP and UDP"
        case .connected:
            "You are not bypassing hotspot limits right now"
        case let .failed(message):
            message
        }
    }

    // MARK: Lifecycle

    func start() {
        reloadPairedDevices()
        installSystemExtension()
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        // Stop the proxy on quit. The extension outlives this app, and a
        // running transparent proxy with no app behind it is worse than no
        // bridge at all.
        manager?.connection.stopVPNTunnel()
        disableProxyConfiguration()
    }

    /// Disables the saved configuration so the extension is not restarted.
    private func disableProxyConfiguration() {
        guard let manager else { return }
        manager.isEnabled = false
        // Synchronous wait: the app is quitting, and letting it exit before
        // this lands is how the Mac ends up needing a reboot.
        let done = DispatchSemaphore(value: 0)
        manager.saveToPreferences { _ in done.signal() }
        _ = done.wait(timeout: .now() + 3)
    }

    /// Asks macOS to activate the proxy system extension.
    ///
    /// The user approves it once in System Settings — the only interaction this
    /// side ever needs, and only on first install.
    private func installSystemExtension() {
        status = .installingExtension
        notifyObservers()

        let delegate = SystemExtensionDelegate { [weak self] result in
            Task { @MainActor in
                switch result {
                case .completed:
                    await self?.enableProxyConfiguration()
                case .needsApproval:
                    self?.status = .needsApproval
                    self?.notifyObservers()
                case let .failed(message):
                    self?.status = .failed(message)
                    self?.notifyObservers()
                }
            }
        }
        extensionDelegate = delegate

        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: extensionBundleID,
            queue: .main
        )
        request.delegate = delegate
        log.error("sysext: submitting activation for \(self.extensionBundleID, privacy: .public)")
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// Apps whose traffic must never be bridged.
    ///
    /// A developer escape hatch, deliberately not surfaced in the UI. The case
    /// it exists for: a device test is driven from this Mac, over this Mac's
    /// own connection, and a bridge fault takes that connection down — so the
    /// tool needed to diagnose the fault goes offline exactly when the fault
    /// happens. Recovering meant killing the app, which also ended the session
    /// being measured.
    ///
    /// Read from defaults so it can be changed without a rebuild, which for a
    /// notarized system extension is the difference between a minute and a
    /// quarter of an hour:
    ///
    ///     defaults write ~/Library/Preferences/com.uplink.app \
    ///         UpLinkDirectApps -array com.example.tooling
    ///
    /// **Write the path, not the bundle id.** `defaults write com.uplink.app`
    /// follows a sandbox container if one exists for that identifier, and a
    /// stale `~/Library/Containers/com.uplink.app` survives on any machine that
    /// ever ran a sandboxed build. This app is deliberately not sandboxed, so
    /// it reads `~/Library/Preferences/`, and the two silently disagree:
    /// `defaults read` shows the value, the app never sees it. The extension
    /// logs the list it actually received, empty or not — trust that over the
    /// write appearing to succeed.
    ///
    /// The value is a **signing identifier**, not a hostname. Hostnames cannot
    /// do this job: a UDP flow has no destination at claim time, and a datagram
    /// carries only an already-resolved address. See ``CapturePolicy/directApps``.
    ///
    /// Find an app's identifier by watching the extension's log while it makes
    /// a connection — the claim path records it.
    static func directApps() -> [String] {
        UserDefaults.standard.stringArray(forKey: "UpLinkDirectApps") ?? []
    }

    private func enableProxyConfiguration() async {
        do {
            let managers = try await NETransparentProxyManager.loadAllFromPreferences()
            let manager = managers.first ?? NETransparentProxyManager()

            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = extensionBundleID
            // Required by NetworkExtension but meaningless here: there is no
            // server, only a phone on the local link.
            proto.serverAddress = "UpLink"

            // A system extension runs as root, OUTSIDE the login session, so it
            // has no access to the user keychain — SecItemCopyMatching there
            // returns errSecNotAvailable (-25291). The app does have access, so
            // it owns the identity and hands the extension what it needs.
            //
            // Trade-off, stated plainly: providerConfiguration is persisted in
            // NetworkExtension's system preferences, which is root-readable
            // rather than keychain-protected. Anything that can read it already
            // has root on this Mac.
            let identity = try store.loadOrCreateIdentity()
            proto.providerConfiguration = [
                "identity": identity.rawRepresentation,
                "deviceName": Host.current().localizedName ?? "Mac",
                "pairedDevices": (try? JSONEncoder().encode(pairedDevices)) ?? Data(),
                "directApps": Self.directApps(),
            ]

            manager.protocolConfiguration = proto
            manager.localizedDescription = "UpLink"
            manager.isEnabled = true

            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            self.manager = manager
            try manager.connection.startVPNTunnel()

            status = .waiting
            notifyObservers()
            startPolling()
        } catch {
            status = .failed(error.localizedDescription)
            notifyObservers()
        }
    }

    /// Polls the extension for status.
    ///
    /// Provider messages are request/response only — the extension cannot push
    /// — so the app asks. Once a second is imperceptible for a menu bar item.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            var tick = 0
            while !Task.isCancelled {
                await self?.refreshStatus()
                // Once every five seconds is plenty: a pairing happens at human
                // speed, and this only has to land before the next relaunch.
                if tick % 5 == 0 { await self?.syncPairedDevicesFromExtension() }
                tick += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Pulls pairings the extension made into the app's keychain.
    ///
    /// Pairing happens in the extension, because the extension owns the
    /// listener — but the extension runs as root outside the login session and
    /// cannot reach the keychain, so its store is in memory and dies with the
    /// process. Nothing wrote those pairings back, so every relaunch started
    /// unpaired: the Mac advertised `sessionKeys=0`, the phone offered a key it
    /// had legitimately been given, and the handshake failed with "unknown PSK
    /// identity". The user's only recourse was to pair again, every single time.
    private func syncPairedDevicesFromExtension() async {
        guard let response = await sendToExtension("devices"),
              !response.isEmpty,
              let json = Data(base64Encoded: response),
              let devices = try? JSONDecoder().decode([PairedDevice].self, from: json)
        else { return }

        let known = Set(pairedDevices.map(\.fingerprint))
        let unknown = devices.filter { !known.contains($0.fingerprint) }
        guard !unknown.isEmpty else { return }

        for device in unknown {
            try? store.save(device)
            log.error("persisted pairing with \(device.name, privacy: .public)")
        }
        reloadPairedDevices()
    }

    private func refreshStatus() async {
        let response = await sendToExtension("status")

        switch BridgeStatusReply.parse(response) {
        case let .connected(peer, egress):
            let name = pairedDevices.first?.name ?? "iPhone"
            let new = MacBridgeStatus.connected(peer: name, egress: egress)
            if new != status { status = new; notifyObservers() }
            setBridgeInterface(peer)
        case .disconnected:
            if status != .waiting { status = .waiting; notifyObservers() }
            setBridgeInterface(nil)
        case .unintelligible:
            break  // ask again rather than act on noise
        }
    }

    @discardableResult
    private func sendToExtension(_ message: String) async -> String? {
        guard let session = manager?.connection as? NETunnelProviderSession else { return nil }
        return await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(Data(message.utf8)) { response in
                    continuation.resume(returning: response.flatMap { String(data: $0, encoding: .utf8) })
                }
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    func disconnect() {
        Task { await sendToExtension("disconnect") }
        status = .waiting
        notifyObservers()
    }

    // MARK: Pairing

    func beginPairing() {
        let code = PairingCode.random()
        activePairingCode = code
        pairingExpiresAt = Date().addingTimeInterval(PairingSession.validity)
        notifyObservers()

        Task { @MainActor [weak self] in
            await self?.sendToExtension("pair:\(code.digits)")
            // Codes expire on their own so an unattended Mac is never left
            // showing a usable credential.
            try? await Task.sleep(for: .seconds(PairingSession.validity))
            await self?.expirePairingCode()
        }
    }

    private func expirePairingCode() async {
        guard activePairingCode != nil else { return }
        activePairingCode = nil
        pairingExpiresAt = nil
        await sendToExtension("pair:off")
        reloadPairedDevices()
        notifyObservers()
    }

    func unpair(_ device: PairedDevice) {
        // Forgetting a device has to end the session using it, or the bridge
        // keeps running on revoked keys while the menu still reads "Connected".
        // A status display that can be wrong makes every test after it
        // worthless, which is worse than the stale pairing itself.
        try? store.remove(fingerprint: device.fingerprint)
        reloadPairedDevices()
        disconnect()
    }

    private func reloadPairedDevices() {
        pairedDevices = (try? store.pairedDevices()) ?? []
        notifyObservers()
    }

    // MARK: Watchdog input

    var bridgeInterfaceName: String? { status.isConnected ? currentBridgeInterface : nil }
    private(set) var currentBridgeInterface: String?
    func setBridgeInterface(_ name: String?) { currentBridgeInterface = name }
}

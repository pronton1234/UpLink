import CryptoKit
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
    /// The packet tunnel that supplies the route and resolver. Held separately
    /// because it is a separate NE configuration, though the same extension
    /// process serves both.
    private var routeManager: NETunnelProviderManager?

    /// Consecutive polls with no session. Teardown waits for a few, so a
    /// reconnecting phone does not blink the user's default route.
    private var quietTicks = 0
    /// Ten seconds of genuine silence, not three. The teardown is irreversible
    /// without another network, so it must never fire on a reconnect.
    private static let quietTicksBeforeDroppingTunnel = 10

    /// Is there a network besides our own tunnel?
    ///
    /// Decides whether handing the network back is safe. A real interface with a
    /// routable address means dropping the tunnel restores normal networking;
    /// nothing but tunnels and link-local means dropping it strands the Mac with
    /// no way to rebuild what it just threw away.
    static func hasAlternativeNetwork() -> Bool {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return false }
        defer { freeifaddrs(head) }

        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(interface.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: interface.pointee.ifa_name)
            // Our own tunnel, and anybody else's, prove nothing.
            guard !name.hasPrefix("utun"), !name.hasPrefix("ipsec") else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let text = String(cString: host)
            // Self-assigned link-local means the interface is up and has no
            // network behind it — which is the state this whole design is for.
            if !text.hasPrefix("169.254.") { return true }
        }
        return false
    }

    /// Consecutive reconcile passes that wanted the tunnel up and found it down.
    /// Non-zero for long is the signal that NE will not run a packet tunnel in
    /// this configuration at all.
    private var failedStarts = 0

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

        // The route tunnel MUST go down too, and this is not tidiness. It owns
        // the Mac's default route and points it at an interface that discards
        // everything, so leaving it up with no proxy behind it converts "the
        // bridge stopped" into "this Mac has no network at all" — and because
        // the extension outlives the app, that survives quitting.
        routeManager?.connection.stopVPNTunnel()
        if let routeManager {
            routeManager.isEnabled = false
            let done = DispatchSemaphore(value: 0)
            routeManager.saveToPreferences { _ in done.signal() }
            _ = done.wait(timeout: .now() + 3)
        }
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
            // `managers.first` was safe while there was one configuration and is
            // not any more. `NETransparentProxyManager` is a SUBCLASS of
            // `NETunnelProviderManager`, so each type's `loadAllFromPreferences`
            // can return the other's configuration, and picking the first would
            // silently reconfigure the wrong one.
            let managers = try await NETransparentProxyManager.loadAllFromPreferences()
            let manager = managers.first { $0 is NETransparentProxyManager }
                ?? NETransparentProxyManager()

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
            // The route tunnel is NOT started here. It follows the session —
            // see `setRouteTunnel(running:)`.
        } catch {
            status = .failed(error.localizedDescription)
            notifyObservers()
        }
    }

    /// Brings up the packet tunnel that gives this Mac a route and a resolver.
    ///
    /// Separate from the proxy configuration because they are separate
    /// NetworkExtension configurations, even though both are served by the same
    /// extension process. The proxy carries the traffic; this carries nothing
    /// and exists so the traffic can be originated at all — with no network
    /// service there is no default route, so `connect()` fails before the proxy
    /// is ever consulted, and no resolver, so names cannot be looked up.
    ///
    /// Failure here is deliberately not fatal to the session. Without it the
    /// bridge still works whenever the Mac has a network of its own, which is
    /// how it behaved before this existed.
    private func enableRouteConfiguration() async {
        do {
            let identity = try store.loadOrCreateIdentity()
            // Filter, and exclude the transparent proxy explicitly: it is a
            // subclass, so it comes back from this call too and `first` would
            // hand back the proxy configuration and reconfigure it as a tunnel.
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            let manager = managers.first { !($0 is NETransparentProxyManager) }
                ?? NETunnelProviderManager()

            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = extensionBundleID
            proto.serverAddress = "UpLink"
            // The route provider needs none of the session material — it never
            // talks to the phone — but the key must be present for the shared
            // extension's startup path.
            proto.providerConfiguration = ["identity": identity.rawRepresentation]

            manager.protocolConfiguration = proto
            manager.localizedDescription = "UpLink Route"
            manager.isEnabled = true

            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            self.routeManager = manager
            try manager.connection.startVPNTunnel()
            log.error("route: tunnel configuration started")
        } catch {
            // Logged, not surfaced. The user's mental model is "the bridge is
            // connected"; this is plumbing beneath that.
            log.error("route: could not start the tunnel: \(error.localizedDescription, privacy: .public)")
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
            await reconcileRouteTunnel(sessionLive: true)
        case .disconnected:
            if status != .waiting { status = .waiting; notifyObservers() }
            setBridgeInterface(nil)
            await reconcileRouteTunnel(sessionLive: false)
        case .unintelligible:
            // Ask again rather than act on noise — and in particular do NOT
            // tear the tunnel down over one unparsed reply.
            break
        }
    }

    /// **No session ⇒ no tunnel.** The invariant this method exists to hold.
    ///
    /// The route tunnel owns the Mac's default route and points it at an
    /// interface that discards everything, so it is only ever correct while
    /// something is carrying the traffic. Started from `enableProxyConfiguration`
    /// it was up from the moment the app configured the extension until the
    /// moment the app quit — which is why quitting both apps used to be the only
    /// way to get Wi-Fi back.
    ///
    /// **A reconciler, not an edge trigger, and that distinction is the whole
    /// bug it replaced.** The first version fired once on each transition and
    /// tracked its own belief in a `Bool`. Then a session flapped:
    ///
    ///     13:56:36.119  session ENDED
    ///     13:56:36.663  route: session gone — dropping the tunnel
    ///     13:56:36.992  route: stopTunnel
    ///     13:56:37.068  session started            ← 0.9s later
    ///     13:56:37.731  route: tunnel configuration started
    ///                   …and no "route: startTunnel" ever followed
    ///
    /// `startVPNTunnel()` while the previous session is still tearing down is a
    /// no-op, so the start was swallowed — and the flag said "running", so
    /// nothing ever tried again. The Mac was left with a live bridge, no route,
    /// and no way back.
    ///
    /// Comparing desired state against what NetworkExtension actually reports,
    /// once a second, makes every silent failure self-correcting: a swallowed
    /// start, a tunnel the system tore down on its own, a race with teardown.
    /// The cost of getting it wrong is the user's whole network, so it is worth
    /// re-deciding every tick rather than trusting a remembered edge.
    private func reconcileRouteTunnel(sessionLive: Bool) async {
        let status = routeManager?.connection.status

        guard sessionLive else {
            // Hysteresis before tearing down, and it is not politeness. A
            // session can flap — observed ENDED at 13:56:36.119 and started
            // again at 13:56:37.068, 0.9s later — and dropping the default
            // route on the first quiet tick means the user's network blinks out
            // every time the phone reconnects. Three consecutive ticks is ~3s:
            // long enough that a reconnect rides through it, short enough that a
            // genuinely dead bridge does not strand the Mac.
            //
            // The teardown itself stays unconditional once confirmed: leaving
            // the tunnel up with no bridge behind it converts "the bridge
            // stopped" into "this Mac has no network at all", and that outlives
            // the app.
            quietTicks += 1
            guard quietTicks >= Self.quietTicksBeforeDroppingTunnel else { return }
            guard let routeManager, status != .disconnected, status != .invalid else { return }

            // THE ASYMMETRY THAT MATTERS. Dropping this tunnel is cheap to do
            // and, in the configuration it exists for, IMPOSSIBLE TO UNDO:
            // NetworkExtension will not start a packet tunnel while the Mac has
            // no underlying network, so once it is down with Wi-Fi gone it stays
            // down. Measured, cable-free over AWDL:
            //
            //   14:57:20  session started (peer=…%awdl0)
            //   14:57:21  route: up                      <- working
            //   14:57:31  session ENDED                  <- a 3.5s blip
            //   14:57:34  dropping the tunnel            <- this line
            //   14:57:35  session started                <- back already
            //   14:57:55  THE TUNNEL WILL NOT START
            //
            // A working state was destroyed by a blip and could not be rebuilt.
            // So: only hand the network back when there is a network to hand it
            // back TO. With an alternative present, dropping is safe and
            // reversible; without one it strands the Mac, and keeping a stale
            // tunnel is strictly better than that.
            guard Self.hasAlternativeNetwork() else {
                if quietTicks % 30 == 0 {
                    log.error("route: no session for \(self.quietTicks, privacy: .public) ticks, but this Mac has no other network — keeping the tunnel, because it could not be restarted")
                }
                return
            }

            log.error("route: no session for \(self.quietTicks, privacy: .public) ticks and another network is available — dropping the tunnel")
            routeManager.connection.stopVPNTunnel()
            return
        }
        quietTicks = 0

        switch status {
        case .connected, .connecting, .reasserting:
            failedStarts = 0
            return  // already where we want to be
        case nil, .invalid:
            // Never configured, or the configuration was removed.
            await enableRouteConfiguration()
        case .disconnected, .disconnecting:
            // Includes the case that broke: a start swallowed because teardown
            // was still in flight. Trying again next tick is the fix.
            guard let routeManager else { return }
            failedStarts += 1
            do {
                try routeManager.connection.startVPNTunnel()
                // Rate-limited, because this runs at 1Hz and the interesting
                // signal is "still not up after N attempts", not each attempt.
                if failedStarts == 1 || failedStarts % 10 == 0 {
                    log.error("route: session is live but the tunnel is not — (re)starting, attempt \(self.failedStarts, privacy: .public)")
                }
            } catch {
                log.error("route: start threw: \(error.localizedDescription, privacy: .public)")
            }
            // The question this whole design rests on, made answerable in one
            // test run: does NetworkExtension keep a packet tunnel alive when
            // the Mac has NO network service of its own? If it does not, this
            // line is what says so, unambiguously, instead of the user seeing
            // "it just does not work".
            if failedStarts == 20 {
                log.error("route: THE TUNNEL WILL NOT START — 20 attempts with a live session. NetworkExtension is refusing to run a packet tunnel with no underlying network, which is the architecture's load-bearing assumption. Route and DNS must come from somewhere else.")
            }
        @unknown default:
            return
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

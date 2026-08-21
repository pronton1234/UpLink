import CryptoKit
import Foundation
import Network
import NetworkExtension
import SystemExtensions
import Observation
import OSLog
import UpLinkKit

/// What the Mac can truthfully say about the bridge.
///
/// **"Waiting" used to be one case, and that was the bug.** Not bridging has
/// several causes with completely different remedies — no cable, cable but the
/// phone's app is not running, cable and app but no pairing — and collapsing
/// them meant the menu bar said "Waiting for iPhone" at a user whose iPhone was
/// plugged in and sitting right there. Now the cable's state is carried
/// through, so the sentence on screen names the thing to fix.
enum MacBridgeStatus: Equatable {
    case installingExtension
    case needsApproval
    /// The Mac is not hosting its access point, so there is no link at all.
    /// The only state here the user can personally fix, which is why it gets
    /// an action rather than a description.
    case accessPointDown
    /// The access point is up and no phone has joined it yet.
    case waitingForPhone
    /// No cabled iPhone attached.
    case waitingForCable
    /// Attached, but nothing answered on either UpLink port.
    case deviceNotResponding
    /// Attached and answering, but this Mac has no pairing for it.
    case deviceNotPaired
    /// Attached, paired, dialling.
    case connecting
    /// The phone answers and refuses this Mac's key.
    case pairingLost
    /// The user switched the bridge off by hand. Not a fault, and not
    /// something to keep retrying — but it needs saying, or the menu bar looks
    /// identical to a bridge that is failing to connect.
    case switchedOff
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

    fileprivate(set) var status: MacBridgeStatus = .waitingForCable
    private(set) var pairedDevices: [PairedDevice] = []
    /// Last peer announcement, so the log records changes rather than a
    /// line every few seconds.
    private var lastAnnouncedPeer: String?

    private(set) var activePairingCode: PairingCode?
    private(set) var pairingExpiresAt: Date?

    /// Multiple observers, not a single closure. The app delegate refreshes the
    /// status item and the Devices window both react to bridge state; a lone `onChange`
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
    /// Set when a start fails with `configurationInvalid`, so the next pass
    /// rebuilds rather than retries. See `reconcileRouteTunnel`.
    private var routeManagerNeedsRebuild = false

    /// Remembers deliberate removals so the device poll cannot re-learn them.
    /// See ``PairedDeviceMerge`` for the two ways that used to undo a removal.
    private var merge = PairedDeviceMerge()

    private var pollTask: Task<Void, Never>?
    private var extensionDelegate: SystemExtensionDelegate?
    private let extensionBundleID = UpLinkIdentifiers.macProxyExtension

    /// The names the two NetworkExtension configurations are stored under.
    /// They are the only reliable way to tell them apart; see the note in
    /// `enableProxyConfiguration`.
    private static let proxyConfigurationName = "UpLink"
    private static let routeConfigurationName = "UpLink Route"

    // MARK: Menu text

    var statusHeadline: String {
        switch status {
        case .installingExtension: "Installing…"
        case .needsApproval: "Approval needed in System Settings"
        case .accessPointDown: LinkStatus.accessPointDown.headline
        case .waitingForPhone: LinkStatus.waitingForPhone.headline
        case .waitingForCable: LinkStatus.waitingForCable.headline
        case .deviceNotResponding: LinkStatus.deviceNotResponding.headline
        case .deviceNotPaired: LinkStatus.deviceNotPaired.headline
        case .connecting: LinkStatus.connecting.headline
        case .pairingLost: LinkStatus.pairingLost.headline
        case .switchedOff: LinkStatus.switchedOff.headline
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
        case .accessPointDown: LinkStatus.accessPointDown.detail
        case .waitingForPhone: LinkStatus.waitingForPhone.detail
        case .waitingForCable: LinkStatus.waitingForCable.detail
        case .deviceNotResponding: LinkStatus.deviceNotResponding.detail
        case .deviceNotPaired: LinkStatus.deviceNotPaired.detail
        case .connecting: LinkStatus.connecting.detail
        case .pairingLost: LinkStatus.pairingLost.detail
        case .switchedOff: LinkStatus.switchedOff.detail
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
        startRelay()
        // BEFORE the extension work, so a tunnel left behind by a previous
        // launch is reachable from the very first reconcile tick. Otherwise a
        // crash or a quit at the wrong moment leaves the Mac with no network
        // and no way for the app to give it back.
        Task { @MainActor [weak self] in await self?.adoptExistingRouteTunnel() }
        installSystemExtension()
    }

    func stop() {
        relayFeed?.finish()
        relayFeed = nil
        relayConsumer?.cancel()
        relayConsumer = nil
        relay.stop()
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
            // Two configurations now exist under this app — the proxy and the
            // route tunnel — and reconfiguring the wrong one silently breaks
            // capture. They are matched by name.
            //
            // NOT by `is NETransparentProxyManager`, which is what this used to
            // do on the belief that it was a subclass of
            // `NETunnelProviderManager`. It is not: both descend from
            // `NEVPNManager` as SIBLINGS, so that test was a no-op the compiler
            // warned about, and the reasoning behind it was simply wrong.
            let managers = try await NETransparentProxyManager.loadAllFromPreferences()
            let manager = managers.first { $0.localizedDescription == Self.proxyConfigurationName }
                ?? managers.first
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
            manager.localizedDescription = Self.proxyConfigurationName
            manager.isEnabled = true

            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            self.manager = manager
            try manager.connection.startVPNTunnel()

            setIdleStatus()
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
    /// Adopts a route tunnel this app did not start.
    ///
    /// **Without this, a failure becomes a Mac with no network that nothing can
    /// fix.** `routeManager` used to be assigned only by
    /// ``enableRouteConfiguration``, which runs only on the session-live path —
    /// so after the app was quit and relaunched with no session, the property
    /// was nil, `reconcileRouteTunnel`'s teardown guard returned silently, and
    /// the tunnel started by the PREVIOUS instance stayed up forever. The
    /// default route pointed into a packet tunnel that drops everything, the
    /// bridge behind it was dead, and the running app was structurally
    /// incapable of taking it down.
    ///
    /// Measured 2026-08-15: `curl` timed out, `default … utun5` outranked en0,
    /// and the only way back was `scutil --nc stop "UpLink Route"` by hand.
    /// This is the hazard `reconcileRouteTunnel` calls "impossible to undo",
    /// reached by nothing more exotic than restarting the app.
    ///
    /// Called at startup, before anything else can go wrong.
    private func adoptExistingRouteTunnel() async {
        guard routeManager == nil else { return }
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            guard let existing = managers.first(
                where: { $0.localizedDescription == Self.routeConfigurationName }
            ) else { return }
            routeManager = existing
            let status = existing.connection.status
            if status != .disconnected && status != .invalid {
                log.error("route: adopted a tunnel left running by a previous launch (status \(String(describing: status), privacy: .public))")
            }
        } catch {
            log.error("route: could not look for an existing tunnel: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func enableRouteConfiguration() async {
        do {
            let identity = try store.loadOrCreateIdentity()
            // By name, for the reason given in `enableProxyConfiguration`: the
            // `is NETransparentProxyManager` test that used to be here could
            // never fire, because the two manager types are siblings rather
            // than parent and child.
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            let manager = managers.first { $0.localizedDescription == Self.routeConfigurationName }
                ?? managers.first
                ?? NETunnelProviderManager()

            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = extensionBundleID
            proto.serverAddress = "UpLink"
            // The route provider needs none of the session material — it never
            // talks to the phone — but the key must be present for the shared
            // extension's startup path.
            proto.providerConfiguration = ["identity": identity.rawRepresentation]

            manager.protocolConfiguration = proto
            manager.localizedDescription = Self.routeConfigurationName
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

        // `pairedDevices` is read AFTER the await on purpose, and the merge
        // additionally screens out anything removed while that round trip was in
        // flight — the reply was composed before the removal, so without this
        // the device looks new and is written straight back.
        merge.expire()
        let unknown = merge.devicesToPersist(
            reportedByExtension: devices,
            alreadyKnown: Set(pairedDevices.map(\.fingerprint))
        )
        guard !unknown.isEmpty else { return }

        var learned = false
        for device in unknown {
            do {
                try store.save(device)
                merge.notePaired(device.fingerprint)
                learned = true
                log.error("persisted pairing with \(device.name, privacy: .public)")
            } catch {
                // Was logged as success unconditionally, so a keychain refusal
                // read as a stored pairing that then vanished on relaunch.
                log.error("COULD NOT persist pairing with \(device.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        guard learned else { return }
        reloadPairedDevices()
        // The extension re-seeds from this snapshot on every restart, so a new
        // pairing that never reaches it is lost the moment the extension dies.
        await reseedExtension()
    }

    /// Rewrites the extension's persisted seed to match the keychain.
    ///
    /// THE FIX FOR RESURRECTION. `providerConfiguration` was written exactly
    /// once per app launch, and the extension's directory is in memory and
    /// rebuilt from it on every extension restart. So a device removed after
    /// launch came back — with its PSK re-advertised — and the device poll then
    /// copied it into the keychain again. The mirror image lost new pairings:
    /// one made after launch existed only in the extension's memory and the
    /// keychain, never in the snapshot, so an extension restart dropped it and
    /// the phone was refused with `sessionKeys` that omitted it.
    private func reseedExtension() async {
        guard let manager,
              let proto = manager.protocolConfiguration as? NETunnelProviderProtocol,
              var configuration = proto.providerConfiguration
        else { return }

        do {
            configuration["pairedDevices"] = try JSONEncoder().encode(pairedDevices)
            // NO TOMBSTONES HERE ANY MORE. They belong to whichever side holds
            // the listener, because keeping a revoked peer's key on the air
            // long enough to tell it is a listener's job — and that is the
            // PHONE now. This round trip was asking an extension that no longer
            // has the verb (so it answered "unknown") and writing a
            // `revokedDevices` key nothing reads.
            configuration.removeValue(forKey: "revokedDevices")
            proto.providerConfiguration = configuration
            manager.protocolConfiguration = proto
            try await manager.saveToPreferences()
            log.error("reseeded extension with \(self.pairedDevices.count, privacy: .public) device(s)")
        } catch {
            log.error("could not reseed extension: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func refreshStatus() async {
        let response = await sendToExtension("status")
        let reply = BridgeStatusReply.parse(response)

        switch reply {
        case let .connected(peer, egress):
            pairingRefused = false
            let name = pairedDevices.first?.name ?? "iPhone"
            let new = MacBridgeStatus.connected(peer: name, egress: egress)
            if new != status { status = new; notifyObservers() }
        case .disconnected:
            pairingRefused = false
            // The extension has no relay to dial. If the app can see a ready
            // cable, the extension missed the handover — it may have restarted,
            // or not been up when the device attached. Re-announce rather than
            // waiting for a replug, which is what a user would otherwise have
            // to work out for themselves.
            if case let .ready(udid, port, _) = relayState, !userDisconnected {
                _ = await sendToExtension("usbrelay:\(port):\(udid)")
            }
            setIdleStatus()
        case let .unpaired(fingerprint):
            // The phone removed this Mac. The extension has already dropped its
            // in-memory copy; only the app can drop the durable one, and if it
            // does not the pairing returns on the next re-seed.
            if let fingerprint, !fingerprint.isEmpty {
                merge.noteRemoved(fingerprint)
                do {
                    try store.remove(fingerprint: fingerprint)
                    log.error("phone \(fingerprint, privacy: .public) unpaired us — forgotten")
                } catch {
                    log.error("could not forget \(fingerprint, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            reloadPairedDevices()
            await reseedExtension()
            setIdleStatus()
        case .connecting:
            pairingRefused = false
            // RE-ANNOUNCED HERE TOO, not only on `.disconnected`.
            //
            // FOUND ON HARDWARE. The relay announces its port once, as soon as
            // the cable is seen — which at launch is before the proxy IPC
            // channel exists, so the message is silently dropped. The extension
            // then still holds the PREVIOUS launch's port, so it answers
            // "connecting" rather than "disconnected", and a re-announce gated
            // on "disconnected" never fired. The result was a dead bridge that
            // recovered only by unplugging the cable.
            //
            // Safe to send every tick: `startRedialing` is idempotent on the
            // port the loop is actually dialling, so a repeat is a no-op and a
            // genuinely new port restarts the loop.
            if case let .ready(udid, port, _) = relayState, !userDisconnected {
                _ = await sendToExtension("usbrelay:\(port):\(udid)")
            }
            setIdleStatus()

        case .refused:
            // The phone answered and refused our key on several dials running.
            // Retrying cannot fix it; the user has to pair again.
            pairingRefused = true
            // The Mac's own extension does not send this — it is the phone's
            // vocabulary, for a Mac that refuses its key. Handled so the switch
            // stays exhaustive and a future sender is not silently ignored.
            setIdleStatus()
        case .unintelligible:
            // Ask again rather than act on noise — and in particular do NOT
            // tear the tunnel down over one unparsed reply.
            //
            // But DO re-announce the relay. "unavailable" lands here, and the
            // extension answers that whenever it has no client yet — which is
            // precisely the window in which the relay's one announcement was
            // dropped. Observed on hardware: the app announced port 54636, the
            // extension never received it, and nothing retried for twenty
            // minutes while the phone sat there answering.
            //
            // The re-announce is now on every not-connected reply rather than
            // an enumerated subset, because each time it was gated on a subset
            // the real failure turned out to be the case left out.
            if case let .ready(udid, port, _) = relayState, !userDisconnected {
                _ = await sendToExtension("usbrelay:\(port):\(udid)")
            }
        }

        // RECONCILED EVERY TICK, OUTSIDE THE SWITCH.
        //
        // This used to be called from four of the six branches, and the two it
        // missed were `.refused` and `.unintelligible` — the second of which is
        // exactly what an unreachable extension looks like. So the one state in
        // which the route tunnel most needs re-deriving was the one state that
        // skipped it, and a tunnel left capturing there would take the Mac's
        // network down with nothing behind it.
        //
        // Gating this on an enumerated subset of replies has been wrong every
        // time it has been tried, in this function and in the relay: the real
        // failure is always the case the subset left out. The reconciler is
        // cheap and idempotent, so it runs unconditionally.
        var sessionLive = false
        if case .connected = reply { sessionLive = true }
        await reconcileRouteTunnel(sessionLive: sessionLive)
    }

    /// **No session ⇒ no capture.** The invariant this method exists to hold.
    ///
    /// It used to be "no session ⇒ no tunnel", and that is what broke
    /// reconnecting. See ``RouteTunnelReconciler``: NetworkExtension will not
    /// START a packet tunnel on a Mac with no network, but it will happily keep
    /// one RUNNING — so a tunnel dropped while Wi-Fi was on could not be
    /// rebuilt once Wi-Fi went off, which is the exact order the product is
    /// used in. The tunnel now stays up for the life of the app and switches
    /// between capturing and standby instead.
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
        let status: RouteTunnelStatus
        if let connection = routeManager?.connection {
            switch connection.status {
            case .invalid: status = .invalid
            case .disconnected: status = .disconnected
            case .connecting: status = .connecting
            case .connected: status = .connected
            case .reasserting: status = .reasserting
            case .disconnecting: status = .disconnecting
            @unknown default: status = .disconnected
            }
        } else {
            status = .unconfigured
        }

        // The DECISION lives in the kit, so every transition is provable with
        // no NetworkExtension and no Mac. This only carries it out. Note that
        // nothing it can return stops the tunnel — see the type for why.
        switch RouteTunnelReconciler.next(
            status: status,
            sessionLive: sessionLive,
            // While the access point is up, the mode is pinned: Internet
            // Sharing is sourced from this tunnel and rebuilds the access point
            // on every reconfiguration. See RouteTunnelReconciler.
            // Intent OR observation. While the access point is coming up the
            // interface does not exist yet, and reporting not-hosting in that
            // window makes the reconciler reconfigure the very tunnel Internet
            // Sharing is building on. See AccessPointHost.intendsToHost.
            hostingAccessPoint: AccessPointHost.intendsToHost
                || TransportParameters.hostedNetworkAddress() != nil,
            needsRebuild: routeManagerNeedsRebuild
        ) {
        case .wait:
            return

        case let .setMode(mode):
            failedStarts = 0
            // Sent every tick rather than on a change. The provider no-ops when
            // the mode already matches, and re-deriving beats remembering: a
            // missed edge here costs the user their whole network.
            await sendToRouteTunnel(mode == .capture ? "capture" : "standby")

        case .configure:
            await enableRouteConfiguration()

        case .rebuild:
            log.error("route: the saved configuration cannot be started — rebuilding it")
            routeManagerNeedsRebuild = false
            routeManager = nil
            failedStarts = 0
            await enableRouteConfiguration()

        case .start:
            guard let routeManager else { return }
            failedStarts += 1
            do {
                try routeManager.connection.startVPNTunnel()
                if failedStarts == 1 || failedStarts % 10 == 0 {
                    log.error("route: the tunnel is down — starting it, attempt \(self.failedStarts, privacy: .public)")
                }
            } catch {
                log.error("route: start threw: \(error.localizedDescription, privacy: .public)")
                // AN UNUSABLE CONFIGURATION IS NOT WORTH RETRYING, and THE CODE
                // MATTERS — I checked the wrong one first. `NEVPNErrorDomain
                // error 2` is `configurationDisabled`, not `configurationInvalid`
                // (which is 1). A disabled configuration throws every time,
                // forever, so checking only for `invalid` meant the rebuild arm
                // never fired and this retried a config that could not start.
                //
                // All three mean "not usable as it stands", and the answer to
                // all three is to write a fresh one.
                let ns = error as NSError
                let unusable: Set<Int> = [
                    NEVPNError.configurationInvalid.rawValue,
                    NEVPNError.configurationDisabled.rawValue,
                    NEVPNError.configurationStale.rawValue,
                ]
                if ns.domain == NEVPNErrorDomain, unusable.contains(ns.code) {
                    routeManagerNeedsRebuild = true
                }
            }

            // THE ONE FAILURE THIS CANNOT FIX BY ITSELF, named precisely.
            //
            // Launch the app with no network at all and there is nothing to
            // start the tunnel with — NetworkExtension accepts the start, logs
            // "No network available", and stops the session milliseconds later.
            // Retrying cannot help. Say what fixes it instead of retrying in
            // silence, which is what the user saw for thirty-one seconds.
            if failedStarts == 20 {
                if Self.hasAlternativeNetwork() {
                    log.error("""
                        route: THE TUNNEL WILL NOT START — 20 attempts, and this Mac DOES \
                        have another network, so this is NOT NetworkExtension refusing to \
                        run without one. Read the "start threw" line above for the real error.
                        """)
                } else {
                    log.error("""
                        route: THE TUNNEL WILL NOT START — 20 attempts, and this Mac has no \
                        network at all. NetworkExtension will not start a packet tunnel in \
                        that state. Turn Wi-Fi on for a moment: the tunnel will start, drop \
                        straight into standby harming nothing, and then stay up — so this \
                        cannot happen again.
                        """)
                }
            }
        }
    }

    /// Tells the route tunnel what to capture.
    ///
    /// A separate NE configuration from the proxy, so a separate session, even
    /// though the same extension process serves both.
    @discardableResult
    private func sendToRouteTunnel(_ message: String) async -> String? {
        guard let session = routeManager?.connection as? NETunnelProviderSession else { return nil }
        return await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(Data(message.utf8)) { reply in
                    continuation.resume(returning: reply.map { String(decoding: $0, as: UTF8.self) })
                }
            } catch {
                // Throws when the session is not running. The next tick
                // re-derives everything, so there is nothing to recover here.
                continuation.resume(returning: nil)
            }
        }
    }

    @discardableResult
    /// Tells the extension where the phone is on the network this Mac hosts.
    ///
    /// **Not Bonjour, deliberately.** The Mac is the DHCP server for its own
    /// access point, so it already knows every address it handed out. Browsing
    /// for a service would add a discovery protocol, a local-network permission
    /// prompt, and a thing that has to survive radio changes — to learn
    /// something already written down in `/var/db/dhcpd_leases`.
    ///
    /// The UDID is the paired device's, not anything read off the network.
    /// Over the cable it identified which handset was plugged in; here it only
    /// selects which pairing to use, and the TLS-PSK handshake is what actually
    /// establishes who the peer is.
    func announcePeerIfPossible() async {
        // No access point means no network to find the phone on, and the lease
        // file outlives the network — so this check is what stops a stale entry
        // being announced as a live peer.
        guard FileManager.default.fileExists(atPath: "/dev/null"),
              (try? String(contentsOfFile: DHCPLease.path, encoding: .utf8)) != nil,
              isHostingAccessPoint() else { return }

        guard let contents = try? String(contentsOfFile: DHCPLease.path, encoding: .utf8),
              let lease = DHCPLease.mostRecent(in: contents) else { return }

        // A record with no UDID matches any device on the extension's side, so
        // an empty string is the honest thing to send when we have no pairing
        // yet rather than inventing an identifier.
        let udid = pairedDevices.first?.udid ?? ""
        let message = "peer:\(lease.address):\(UpLinkUSB.extensionPort):\(udid)"
        if message != lastAnnouncedPeer {
            lastAnnouncedPeer = message
            log.error("announcing peer at \(lease.address, privacy: .public)")
        }
        _ = await sendToExtension(message)
    }

    /// Whether this Mac is currently hosting its access point.
    ///
    /// Read from the interfaces. The preference file says what was asked for,
    /// which has repeatedly not been what is running.
    private func isHostingAccessPoint() -> Bool {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return false }
        defer { freeifaddrs(addresses) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next })
        where String(cString: pointer.pointee.ifa_name) == "bridge100" {
            return pointer.pointee.ifa_flags & UInt32(IFF_RUNNING) != 0
        }
        return false
    }

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
        userDisconnected = true
        setIdleStatus()
        notifyObservers()
    }

    /// Whether the user has switched the bridge off by hand.
    ///
    /// Held here as well as in the extension so the menu can offer the way
    /// back. Without one, Disconnect had no inverse short of unplugging the
    /// cable.
    private(set) var userDisconnected = false

    /// Bridge again after an explicit Disconnect.
    func reconnect() {
        userDisconnected = false
        if case let .ready(udid, port, _) = relayState {
            Task { @MainActor [weak self] in
                // The order matters: the extension refuses a relay while it
                // still believes the user has disconnected, and the relay is
                // for the same cable so nothing else clears that belief.
                _ = await self?.sendToExtension("reconnect")
                _ = await self?.sendToExtension("usbrelay:\(port):\(udid)")
            }
        }
        setIdleStatus()
        notifyObservers()
    }

    // MARK: Pairing

    func beginPairing() {
        // Pairing runs over the cable, so there has to be one. Saying so beats
        // showing a code that cannot possibly be used and letting the user
        // discover that by typing it.
        guard case let .ready(udid, port, _) = relayState else {
            status = .failed("Start the UpLink network and join it from your iPhone before pairing.")
            notifyObservers()
            return
        }

        // Pairing is an unambiguous "bridge again", so it undoes a Disconnect.
        //
        // Without this the two states contradicted each other: Disconnect
        // clears the extension's relay port, but the app's `relayState` is
        // still `.ready`, so the guard above passed and the extension answered
        // `error|nocable` with a perfectly good cable attached — and the
        // message told the user to check the cable.
        let wasDisconnected = userDisconnected
        userDisconnected = false

        let code = PairingCode.random()
        activePairingCode = code
        pairingExpiresAt = Date().addingTimeInterval(PairingSession.validity)
        notifyObservers()

        Task { @MainActor [weak self] in
            // Re-armed IN THIS TASK, before `pair:`, not in a separate one.
            //
            // Pairing is an unambiguous "bridge again", so it undoes a
            // Disconnect — but the re-arm has to complete first. Sent from a
            // second task, `pair:` could overtake it and hit `relayPort == nil`,
            // answering `error|nocable` with a perfectly good cable attached
            // and a message telling the user to check it.
            if wasDisconnected {
                _ = await self?.sendToExtension("reconnect")
                _ = await self?.sendToExtension("usbrelay:\(port):\(udid)")
            }

            let reply = await self?.sendToExtension("pair:\(code.digits)")
            if reply?.hasPrefix("error") == true {
                self?.log.error("pairing could not start: \(reply ?? "", privacy: .public)")
                self?.status = .failed("Couldn't start pairing. Check your iPhone is on the UpLink network and try again.")
                // Take the code down with it. Leaving it up rendered a
                // six-digit code that could not possibly work, indefinitely,
                // because this path returned before anything cleared it.
                await self?.expirePairingCode()
                self?.notifyObservers()
                return
            }
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
        //
        // Recorded BEFORE the store write, so a poll that is already in flight
        // cannot re-learn the device from the reply it is about to deliver.
        merge.noteRemoved(device.fingerprint)
        do {
            try store.remove(fingerprint: device.fingerprint)
        } catch {
            // Surfaced rather than swallowed: a failed removal used to leave
            // the row on screen with no explanation at all.
            log.error("COULD NOT remove \(device.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            status = .failed("Could not forget \(device.name): \(error.localizedDescription)")
        }
        reloadPairedDevices()
        // AND it has to reach the phone. The extension owns the session and the
        // listener, so it is the only side that can say so before tearing down.
        // Without this the phone keeps the pairing, keeps dialling, and keeps
        // being refused by a listener advertising `sessionKeys=0` — which looks
        // from here like a phone that will not connect.
        Task { [weak self] in
            _ = await self?.sendToExtension("unpair:\(device.fingerprint)")
            await self?.reseedExtension()
            await MainActor.run { self?.reloadPairedDevices() }
        }
    }

    private func reloadPairedDevices() {
        pairedDevices = (try? store.pairedDevices()) ?? []
        notifyObservers()
    }


    // MARK: The cable

    /// Pumps the USB cable onto a loopback port the extension can dial.
    ///
    /// Owned by the app because the extension is sandboxed and cannot open
    /// `/var/run/usbmuxd`. See ``USBRelay``.
    private let relay = USBRelay()

    /// Told when the cable is pulled mid-session, so the app can notify.
    var onCableRemoved: (() -> Void)?
    private(set) var relayState: USBRelayState = .noDevice
    /// Set when the extension reports the phone refusing our key, cleared the
    /// moment anything else is reported.
    private var pairingRefused = false
    private var relayFeed: AsyncStream<USBRelayState>.Continuation?
    private var relayConsumer: Task<Void, Never>?

    private func startRelay() {
        // Serialised through one consumer, deliberately.
        //
        // Spawning an independent Task per change looked equivalent and is not:
        // unstructured tasks have no ordering guarantee, and `relayChanged`
        // awaits a provider round trip in the middle. A `.ready` → `.noDevice`
        // pair — unplugging right after the probe — could land in either order,
        // leaving the app believing a cable is present that has gone, and
        // delivering `usbrelay:<stale port>` AFTER `usbgone`.
        let (states, feed) = AsyncStream<USBRelayState>.makeStream(bufferingPolicy: .unbounded)
        relayFeed = feed
        relay.onStateChange = { state in feed.yield(state) }
        relayConsumer = Task { @MainActor [weak self] in
            for await state in states {
                await self?.relayChanged(state)
            }
        }
        relay.start()
    }

    private func relayChanged(_ state: USBRelayState) async {
        relayState = state
        switch state {
        case let .ready(udid, port, _):
            _ = await sendToExtension("usbrelay:\(port):\(udid)")
        case .noDevice, .attachedNotAnswering, .failed:
            // Replugging is unambiguously "bridge again".
            userDisconnected = false
            // Tell the user once, and only if they were actually bridging: the
            // link they were using has physically gone.
            if case .noDevice = state, status.isConnected { onCableRemoved?() }
            _ = await sendToExtension("usbgone")
        }
        // The extension's own status poll decides connected-versus-not; this
        // only fills in WHICH not-connected, which is the part only the app can
        // see.
        if !status.isConnected { setIdleStatus() }
        notifyObservers()
    }

    /// The honest name for "not bridging right now".
    ///
    /// There are three of them and they need different actions from the user,
    /// so they must not collapse into one string. The cable is the only source
    /// of truth for which one applies.
    private func setIdleStatus() {
        // The decision itself lives in ``LinkStatus``, in the kit, because the
        // Mac app has no test target — so while this switch was here, every arm
        // of it could only be checked by physically arranging the state. That
        // is why "Waiting for iPhone" survived being shown to users whose
        // iPhone was plugged in.
        let presence: LinkPresence
        var paired = false
        switch relayState {
        case .noDevice:
            presence = .noDevice
        case .attachedNotAnswering:
            presence = .attachedNotAnswering
        case let .failed(reason):
            presence = .failed(reason)
        case let .ready(udid, _, _):
            presence = .answering(udid: udid)
            // A record with no UDID adopts the first device it sessions with,
            // so it counts as paired or the migration could never happen.
            paired = pairedDevices.contains { $0.udid == udid || $0.udid == nil }
        }

        let new: MacBridgeStatus
        switch LinkStatus.resolve(
            presence: presence,
            isPaired: paired,
            userDisconnected: userDisconnected,
            pairingRefused: pairingRefused
        ) {
        case .accessPointDown: new = .accessPointDown
        case .waitingForPhone: new = .waitingForPhone
        case .waitingForCable: new = .waitingForCable
        case .deviceNotResponding: new = .deviceNotResponding
        case .deviceNotPaired: new = .deviceNotPaired
        case .connecting: new = .connecting
        case .pairingLost: new = .pairingLost
        case .switchedOff: new = .switchedOff
        case let .failed(reason): new = .failed(reason)
        }
        guard new != status else { return }
        status = new
        notifyObservers()
    }
}

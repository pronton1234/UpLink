import Foundation
import NetworkExtension
import Network
import CryptoKit
import OSLog
import UpLinkKit

/// Keeps the bridge alive while the phone is locked and the app is closed.
///
/// This is a packet tunnel that deliberately routes **nothing**. iOS suspends
/// ordinary apps within seconds of backgrounding, which would drop the bridge
/// the moment the user locks their phone — the one thing the user said was
/// non-negotiable. A Network Extension is a separate process that the system
/// keeps running, so the tunnel exists purely as a host for the session. The
/// phone's own traffic is untouched: `includedRoutes` is empty, so nothing is
/// captured from this device.
///
/// The user starts and stops this explicitly from the app. There is no
/// on-demand rule, because a bridge that silently re-enables itself would burn
/// cellular data without being asked.
/// `@unchecked Sendable` because NetworkExtension calls provider methods from
/// its own serial context and this class holds no mutable state of its own —
/// everything that changes lives in ``SessionState``, an actor. The unchecked
/// conformance is what lets `self` be captured for `cancelTunnelWithError`.
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {

    private let log = Logger(subsystem: UpLinkIdentifiers.logSubsystem, category: "tunnel")
    private let queue = DispatchQueue(label: "com.uplink.app.tunnel")
    private let state = SessionState()

    // Completion-handler form rather than the async override: the async
    // variant receives a non-Sendable `[String: NSObject]?` across an isolation
    // boundary, which Swift 6 rejects.
    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        log.error("startTunnel")

        // Route-less settings. The tunnel is a process host, not a capture
        // mechanism — we are proxying the *Mac's* traffic, not this phone's.
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.55.0.2"], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = []                       // capture nothing
        ipv4.excludedRoutes = [NEIPv4Route.default()]  // and explicitly exclude everything
        settings.ipv4Settings = ipv4
        settings.mtu = 1500

        guard let config = BridgeConfiguration(
            providerConfiguration: (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        ) else {
            log.error("missing or malformed provider configuration")
            completionHandler(BridgeStartupError.notConfigured)
            return
        }

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error {
                completionHandler(error)
                return
            }
            guard let self else {
                completionHandler(BridgeStartupError.notConfigured)
                return
            }
            let task = Task { await self.runSession(config: config) }
            Task { await self.state.setTask(task) }
            completionHandler(nil)
        }
    }

    /// Keeps a session up for as long as the user leaves the tunnel running.
    ///
    /// Reconnects on its own, because dropping is normal rather than
    /// exceptional here: the user walks between rooms, the Mac sleeps, the
    /// hotspot re-hands an address. Network framework offers nothing for this,
    /// so the retry schedule is ours.
    private func runSession(config: BridgeConfiguration) async {
        let discovery = PeerDiscovery(profile: config.profile)
        await discovery.start(on: queue)

        // Half a second, capped at five — NOT the 1s/30s default.
        //
        // The default is tuned for a service that is one of many: back off hard,
        // do not hammer. This link is the Mac's ONLY network, so the trade runs
        // the other way. Retrying costs a Bonjour browse and a TCP connect on a
        // local radio link; NOT retrying costs the user their entire internet.
        //
        // Measured 2026-08-14: an AWDL session dropped at 15:05:29 and the phone
        // did not get back in until 15:07:12 — 100 seconds, most of it sitting
        // in a 30-second backoff while the Mac had no network at all and the
        // user watched browser tabs fail.
        var policy = ReconnectPolicy(baseDelay: 0.5, maxDelay: 5)

        while !Task.isCancelled {
            do {
                try await connectOnce(config: config, discovery: discovery)
                policy.recordSuccess()
                log.error("session ended cleanly (peer closed the link); will look for the Mac again")
            } catch {
                let delay = policy.recordFailure()
                log.error(
                    "session failed (attempt \(policy.attempt)): \(String(describing: error), privacy: .public); retrying in \(delay)s"
                )
                try? await Task.sleep(for: .seconds(delay))
            }
        }

        await discovery.stop()
    }

    private func connectOnce(config: BridgeConfiguration, discovery: PeerDiscovery) async throws {
        guard let peer = await firstMatchingPeer(from: discovery, fingerprint: config.macFingerprint) else {
            throw BridgeStartupError.peerNotFound
        }

        let parameters = TransportParameters.session(
            psk: config.preSharedKey,
            identity: config.localFingerprint,
            profile: peer.profile
        )
        let connection = NWConnection(to: peer.endpoint, using: parameters)
        let channel = NWConnectionChannel(connection: connection)
        await state.setChannel(channel)
        try await channel.start(on: queue)

        log.error("connected to \(peer.name, privacy: .public) via \(peer.profile.rawValue, privacy: .public) at \(String(describing: peer.endpoint), privacy: .public)")

        // The dialer is where traffic actually leaves the phone, pinned to the
        // cellular radio so the carrier sees app data.
        let dialer = CellularDialer(queue: queue, requiredInterface: .cellular)
        let responder = BridgeResponder(
            channel: channel,
            dialer: dialer,
            localFingerprint: config.localFingerprint
        )
        // Retained so `handleAppMessage` can report the observed egress. The
        // app cannot see this for itself — the sockets live in this process —
        // and without it the phone's UI has nothing but a placeholder to show.
        await state.setResponder(responder)
        defer { Task { await state.setResponder(nil) } }
        try await responder.run()
    }

    /// How long to wait for the paired Mac to appear before giving up and
    /// letting the reconnect loop back off and try again.
    /// Six seconds, not fifteen.
    ///
    /// This is spent on EVERY reconnect attempt before the backoff even starts,
    /// so a fifteen-second wait plus a thirty-second backoff is three quarters
    /// of a minute per try — while the Mac, whose only network this is, has
    /// none. A Bonjour browse over AWDL that has not produced the Mac in six
    /// seconds is not going to; failing fast and browsing again is cheaper than
    /// waiting, because a fresh browse re-issues the query.
    private static let discoveryTimeout: TimeInterval = 6

    /// Waits for the paired Mac to appear, rather than failing on the first
    /// empty browse result — discovery takes a moment to populate.
    ///
    /// The deadline lives in ``PeerResolver/firstMatch(in:fingerprint:timeout:)``
    /// so it can be tested without a radio. It must be enforced independently of
    /// the browse stream; see that method for what happens when it is not.
    private func firstMatchingPeer(
        from discovery: PeerDiscovery,
        fingerprint: String
    ) async -> DiscoveredPeer? {
        // Matched on the long-term key, never the address — on a local link the
        // address changes on essentially every reconnect.
        await PeerResolver.firstMatch(
            in: await discovery.peers(),
            fingerprint: fingerprint,
            timeout: Self.discoveryTimeout
        )
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        log.error("stopTunnel: \(reason.rawValue)")
        let state = self.state
        let done = UncheckedSendableBox(completionHandler)
        Task {
            await state.teardown()
            done.value()
        }
    }

    /// Status queries from the containing app.
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let request = String(data: messageData, encoding: .utf8) else {
            completionHandler?(nil)
            return
        }
        switch request {
        case "status":
            let state = self.state
            let reply = UncheckedSendableBox(completionHandler)
            Task {
                guard await state.isConnected else {
                    reply.value?(Data("disconnected".utf8))
                    return
                }
                // Same shape the Mac's proxy extension uses, so both UIs read a
                // real observation rather than assuming cellular.
                let egress = await state.observedEgress ?? .unknown
                reply.value?(Data("connected|\(egress.rawValue)".utf8))
            }
        default:
            completionHandler?(nil)
        }
    }
}

/// Carries a non-`Sendable` value into a task.
///
/// NetworkExtension's completion handlers predate strict concurrency and are
/// not annotated `@Sendable`, yet the framework's own contract is simply that
/// each is invoked exactly once — which is what the call sites here do.
struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Owns everything mutable about a live session.
///
/// Keeping this in an actor rather than in stored properties on the provider
/// means the provider itself has no mutable state to race on, which is what
/// makes its `@unchecked Sendable` conformance honest rather than a shortcut.
private actor SessionState {

    private var channel: NWConnectionChannel?
    private var task: Task<Void, Never>?
    private var responder: BridgeResponder?

    var isConnected: Bool { channel != nil }

    /// What the phone last observed about how traffic is actually leaving.
    var observedEgress: EgressInterface? {
        get async { await responder?.observedEgress }
    }

    func setChannel(_ channel: NWConnectionChannel?) { self.channel = channel }
    func setTask(_ task: Task<Void, Never>?) { self.task = task }
    func setResponder(_ responder: BridgeResponder?) { self.responder = responder }

    func teardown() async {
        task?.cancel()
        task = nil
        responder = nil
        await channel?.close()
        channel = nil
    }
}

enum BridgeStartupError: Error {
    case notConfigured
    case peerNotFound
}

/// What the app hands the extension when the user taps Connect.
struct BridgeConfiguration {
    let macFingerprint: String
    let localFingerprint: String
    let preSharedKey: SymmetricKey
    let profile: TransportProfile

    init?(providerConfiguration: [String: Any]?) {
        guard let config = providerConfiguration,
              let fingerprint = config["macFingerprint"] as? String,
              let localFingerprint = config["localFingerprint"] as? String,
              let keyData = config["preSharedKey"] as? Data
        else { return nil }

        self.macFingerprint = fingerprint
        self.localFingerprint = localFingerprint
        self.preSharedKey = SymmetricKey(data: keyData)
        self.profile = (config["profile"] as? String).flatMap(TransportProfile.init(rawValue:)) ?? .localLink
    }
}

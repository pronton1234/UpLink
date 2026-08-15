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
/// everything that changes lives in ``PhoneSessionState``, an actor. The unchecked
/// conformance is what lets `self` be captured for `cancelTunnelWithError`.
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {

    private let log = Logger(subsystem: UpLinkIdentifiers.logSubsystem, category: "tunnel")

    /// Survives the run, unlike the unified log, which needs a cable to read —
    /// and the cable changes the peer link being tested.
    private let diagnostics = PhoneDiagnosticLog.shared
    private let queue = DispatchQueue(label: "com.uplink.app.tunnel")
    private let state = PhoneSessionState()

    // Completion-handler form rather than the async override: the async
    // variant receives a non-Sendable `[String: NSObject]?` across an isolation
    // boundary, which Swift 6 rejects.
    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        log.error("startTunnel")
        diagnostics.write("=== startTunnel (diagnostic log available: \(PhoneDiagnosticLog.shared.isAvailable)) ===")

        // A fresh configuration carries fresh pairing material, so no revocation
        // observed under the previous one can still apply.
        //
        // `runningSession` also clears this, but not soon enough on its own: the
        // app polls `status` from the moment it starts the tunnel, and discovery
        // plus a handshake takes seconds. In that window a stale flag answers
        // "unpaired" and the app deletes the pairing the user has just created.
        Task { await self.state.clearUnpairedByPeer() }

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
                diagnostics.write("session ended cleanly; looking for the Mac again")
                await state.setPendingChannel(nil)
            } catch {
                let delay = policy.recordFailure()
                log.error(
                    "session failed (attempt \(policy.attempt)): \(String(describing: error), privacy: .public); retrying in \(delay)s"
                )
                // The line that has been missing. On the Mac a failed attempt is
                // invisible — there is simply no inbound connection — so "the
                // phone never dialled" and "the phone dialled and was refused"
                // look identical from there. They have completely different
                // causes.
                diagnostics.write("attempt \(policy.attempt) FAILED: \(error); retrying in \(delay)s")
                try? await Task.sleep(for: .seconds(delay))
                // A FRESH browse, not another look at the same one. The browser
                // is scoped to an interface, and the interface is exactly what
                // changed underneath us; asking a wedged browser again returns
                // the same nothing forever.
                await discovery.restart()
            }
        }

        await discovery.stop()
    }

    private func connectOnce(config: BridgeConfiguration, discovery: PeerDiscovery) async throws {
        diagnostics.write("looking for the Mac (fingerprint \(config.macFingerprint.prefix(8)))")
        guard let peer = await firstMatchingPeer(from: discovery, fingerprint: config.macFingerprint) else {
            // THE distinction the Mac cannot make. No inbound connection there
            // means either "the phone never found me" or "the phone found me and
            // could not connect" — opposite causes, identical silence.
            diagnostics.write("NOT FOUND — discovery produced no matching Mac; never dialled")
            throw BridgeStartupError.peerNotFound
        }

        let parameters = TransportParameters.session(
            psk: config.preSharedKey,
            identity: config.localFingerprint,
            profile: peer.profile
        )
        let connection = NWConnection(to: peer.endpoint, using: parameters)
        let channel = NWConnectionChannel(connection: connection)
        // Pending, not connected: recorded so `teardown` can cancel a dial that
        // never completes, but never reported to the UI as a session.
        await state.setPendingChannel(channel)
        do {
            try await channel.start(on: queue)
        } catch {
            // Otherwise a handshake that fails leaves the channel behind and
            // the phone claims a session it never had.
            await state.setPendingChannel(nil)
            await channel.close()
            throw error
        }

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
        //
        // `runningSession` owns the whole lifetime and clears both on every exit
        // path. The previous shape cleared the responder in a `defer` and left
        // the channel set forever, which is what made the phone claim a session
        // the Mac had never heard of.
        // The Mac forgetting this phone must be acted on here, where the
        // session is. Previously it was only visible as a TLS-PSK handshake
        // that started failing, which is indistinguishable from every other
        // connection failure — so the phone retried forever against a listener
        // advertising `sessionKeys=0`.
        _ = await responder.onUnpairedByPeer { [weak self] in
            Task { await self?.state.noteUnpairedByPeer() }
        }

        await state.setPeerFingerprint(config.macFingerprint)
        try await state.runningSession(channel: channel, responder: responder) {
            try await responder.run()
        }
        await channel.close()
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
        case _ where request.hasPrefix("unpair"):
            // Announce over the live session, then stop. The other order
            // guarantees the notice is never delivered, since it travels on the
            // connection being torn down.
            // `unpair:<fingerprint>` names which Mac. A bare "unpair" is
            // accepted for compatibility but the addressed form is what the app
            // now sends: acting on whichever session happened to be live is how
            // deleting one Mac could revoke another.
            let wanted = request.hasPrefix("unpair:")
                ? String(request.dropFirst("unpair:".count))
                : nil
            let state = self.state
            let reply = UncheckedSendableBox(completionHandler)
            Task {
                if let wanted, let live = await state.peerFingerprint, live != wanted {
                    self.log.error("ipc: refusing unpair of \(wanted, privacy: .public) — live session is \(live, privacy: .public)")
                    reply.value?(Data("wrong-peer".utf8))
                    return
                }
                await state.announceUnpaired()
                await state.teardown()
                reply.value?(Data("ok".utf8))
            }

        case "diagnostics":
            // Answered synchronously: it is a file read, and the point is to be
            // able to get it out even when the session machinery is wedged.
            //
            // The header is not padding. Last time this produced nothing, the
            // question "did the extension never run, or did it run and fail to
            // write?" could not be answered — and those have completely
            // different fixes. Now the reply says which, even when the log
            // itself is empty.
            let log = PhoneDiagnosticLog.shared
            var report = "extension running, pid \(ProcessInfo.processInfo.processIdentifier)\n"
            report += "log available: \(log.isAvailable)\n"
            if !log.diagnosis.isEmpty { report += "log unavailable because: \(log.diagnosis)\n" }
            report += "---\n"
            report += log.contents()
            completionHandler?(Data(report.utf8))
        case "status":
            let state = self.state
            let reply = UncheckedSendableBox(completionHandler)
            Task {
                // Checked before `isConnected`, because the notice arrives as
                // the session is ending and the app's next poll is the only
                // chance to deliver it.
                if await state.wasUnpairedByPeer {
                    reply.value?(Data("unpaired".utf8))
                    return
                }
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

/// The session state lives in ``PhoneSessionState`` in the kit.
///
/// It was a `private actor` here, where nothing could test it, and it carried a
/// bug that survived every on-device round: the channel was set on connect and
/// never cleared, so the phone reported itself connected for the life of the
/// tunnel. See that type for the full account.

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

import Foundation
import NetworkExtension
import Network
import OSLog
import UpLinkKit

/// Captures every app's outbound traffic and hands it to the phone.
///
/// `NETransparentProxyProvider` delivers ready-made TCP and UDP **flows**
/// rather than raw IP packets, so there is no TCP/IP stack to implement — the
/// work is pumping bytes between a flow and a multiplexed stream. Unlike a
/// SOCKS proxy plus system proxy settings, this captures apps that use raw
/// sockets or ignore proxy configuration entirely.
///
/// What it does **not** capture: ICMP, raw IP sockets, and traffic from other
/// system extensions. That is a limit of the API, not of this code, and the app
/// blocks ICMP while bridging so nothing exits silently instead.
///
/// `@unchecked Sendable` because NetworkExtension drives providers from its own
/// serial context and this class holds no mutable state — everything that
/// changes lives in ``ProxyState``, an actor.
final class TransparentProxyProvider: NETransparentProxyProvider, @unchecked Sendable {

    private let log = Logger(subsystem: UpLinkIdentifiers.logSubsystem, category: "proxy")
    private let queue = DispatchQueue(label: "com.uplink.app.proxy")
    private let state = ProxyState()

    override func startProxy(options: [String: Any]?, completionHandler: @escaping (Error?) -> Void) {
        let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        // Capture all outbound TCP and UDP. Which flows actually cross the
        // bridge is decided per-flow by CapturePolicy; at this point we do not
        // yet know what address the phone will have.
        // The `…NetworkEndpoint:` spelling takes nw_endpoint_t; the older
        // NWHostEndpoint form was deprecated in macOS 15, which is our floor.
        let tcp = NENetworkRule(
            remoteNetworkEndpoint: nil, remotePrefix: 0,
            localNetworkEndpoint: nil, localPrefix: 0,
            protocol: .TCP, direction: .outbound
        )
        let udp = NENetworkRule(
            remoteNetworkEndpoint: nil, remotePrefix: 0,
            localNetworkEndpoint: nil, localPrefix: 0,
            protocol: .UDP, direction: .outbound
        )
        settings.includedNetworkRules = [tcp, udp]

        // NOTE: setting `settings.dnsSettings` here does nothing.
        //
        // `NETransparentProxyNetworkSettings` inherits `DNSSettings` from
        // `NETunnelNetworkSettings`, and applying it is accepted without error
        // — but the resolvers never appear in `scutil --dns`. A transparent
        // proxy has no virtual interface for them to attach to. Measured, not
        // assumed: the settings were applied, `transparent proxy started` was
        // logged, and the system resolver list was unchanged.
        //
        // DNS is instead redirected per query in `pumpUDP`. See
        // ``UpLinkDNS`` for why it has to be redirected at all.

        let log = self.log
        let state = self.state
        let queue = self.queue
        let done = UncheckedSendableBox(completionHandler)
        let configuration = UncheckedSendableBox(
            (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        )

        setTunnelNetworkSettings(settings) { error in
            if let error {
                log.error("could not apply settings: \(error.localizedDescription, privacy: .public)")
                done.value(error)
                return
            }
            Task {
                do {
                    try await state.startHosting(
                        queue: queue, log: log, configuration: configuration.value
                    )
                    log.info("transparent proxy started")
                    done.value(nil)
                } catch {
                    log.error("host failed: \(String(describing: error), privacy: .public)")
                    done.value(error)
                }
            }
        }
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        log.info("stopProxy: \(reason.rawValue)")
        let state = self.state
        let done = UncheckedSendableBox(completionHandler)
        Task {
            await state.stopHosting()
            done.value()
        }
    }

    /// The admission gate, rebuilt per flow from the current snapshot.
    ///
    /// The decision must be made synchronously — `handleNewFlow` returns a
    /// `Bool` and the system will not wait for an actor hop — so this reads the
    /// cached `hasSession` / `currentPolicy` rather than the actor's state.
    ///
    /// The rules themselves live in `UpLinkKit`'s ``FlowAdmission`` and are
    /// called, not restated, so the regression suite tests this code rather
    /// than a copy of it.
    private var admission: FlowAdmission {
        FlowAdmission(
            hasSession: state.hasSession,
            policy: state.currentPolicy,
            flowsPerApp: state.flowsPerApp
        )
    }

    /// Says so, once, when an app is being held at its limit.
    ///
    /// Logged on the transition only. The condition that motivates the cap is a
    /// process opening 87 flows a second, so a line per refusal would bury the
    /// diagnostics under the very flood it is reporting.
    private func noteIfOverLimit(_ source: String?, gate: FlowAdmission) {
        guard let source, !gate.withinFlowLimit(source) else { return }
        guard !cappedApps.contains(source) else { return }
        cappedApps.insert(source)
        log.error("\(source, privacy: .public) is at its flow limit (\(FlowAdmission.perAppFlowLimit, privacy: .public)) — declining further flows so other apps keep working")
    }

    /// Apps already reported as capped, so the message is not repeated.
    private var cappedApps: Set<String> = []

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        let source = flow.metaData.sourceAppSigningIdentifier
        let gate = admission

        if let tcpFlow = flow as? NEAppProxyTCPFlow {
            return handle(tcpFlow, from: source, gate: gate)
        }
        if let udpFlow = flow as? NEAppProxyUDPFlow {
            return handle(udpFlow, from: source, gate: gate)
        }
        return false
    }

    // MARK: TCP

    private func handle(
        _ flow: NEAppProxyTCPFlow,
        from source: String?,
        gate: FlowAdmission
    ) -> Bool {
        guard case let .hostPort(host, port) = flow.remoteFlowEndpoint else { return false }
        let remote = "\(host):\(port)"

        guard gate.shouldClaim(remoteEndpoint: remote, sourceSigningIdentifier: source) else {
            // false means "system, handle this normally", which for our own
            // link to the phone is exactly right.
            noteIfOverLimit(source, gate: gate)
            return false
        }

        // The claiming app is logged, not just the destination. It is the value
        // `UpLinkDirectApps` takes, and there is no other way to discover it —
        // an app that needs keeping off the bridge has to be nameable first.
        log.error("claim tcp \(remote, privacy: .public) by \(source ?? "?", privacy: .public)")

        let destination = StreamOpen(proto: .tcp, host: "\(host)", port: port.rawValue)
        let handle = TCPFlowHandle(flow)
        let log = self.log
        let state = self.state

        state.flowStarted(source)
        Task {
            defer { state.flowFinished(source) }
            guard let initiator = await state.initiator else {
                handle.closeBoth(BridgeError.noSession)
                return
            }
            await pumpTCP(handle, to: destination, via: initiator, log: log)
        }
        return true
    }

    // MARK: UDP

    /// One UDP flow becomes one *session*, not one connection.
    ///
    /// `NEAppProxyUDPFlow` carries datagrams to many destinations — a browser
    /// doing QUIC to several hosts, a resolver talking to several nameservers.
    /// Each datagram therefore carries its own destination across the bridge.
    private func handle(
        _ flow: NEAppProxyUDPFlow,
        from source: String?,
        gate: FlowAdmission
    ) -> Bool {
        // `NEAppProxyUDPFlow` has no remote endpoint — a UDP flow is a session
        // that sends to many destinations, so the only thing judgeable here is
        // who is asking. Everything else must be claimed, which means the pump
        // has to be able to service *every* datagram, including the ones the
        // policy says must not cross the bridge.
        //
        // Dropping those, as this used to, is a black hole: the sender gets no
        // answer and no error, and eventually closes the flow. That filled the
        // log with "The peer closed the flow" 296 times in 25 minutes — and
        // because DNS lives here, every lookup aimed at a router the phone
        // cannot reach stalled until it timed out. The bridge felt throttled
        // while correctly reporting cellular egress. Hence the direct outlet in
        // `pumpUDP`.
        guard gate.shouldClaimDatagramSession(sourceSigningIdentifier: source) else {
            noteIfOverLimit(source, gate: gate)
            return false
        }

        log.error("claim udp by \(source ?? "?", privacy: .public)")

        let handle = UDPFlowHandle(flow)
        let log = self.log
        let state = self.state

        state.flowStarted(source)
        Task {
            defer { state.flowFinished(source) }
            guard let initiator = await state.initiator else {
                handle.close(BridgeError.noSession)
                return
            }
            await pumpUDP(handle, via: initiator, policy: state.currentPolicy, log: log)
        }
        return true
    }

    /// Control channel from the containing app.
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let message = String(data: messageData, encoding: .utf8) else {
            completionHandler?(nil)
            return
        }
        let state = self.state
        let reply = UncheckedSendableBox(completionHandler)
        Task {
            let response = await state.handle(message: message)
            reply.value?(response.data(using: .utf8))
        }
    }
}

enum BridgeError: Error {
    case noSession
}

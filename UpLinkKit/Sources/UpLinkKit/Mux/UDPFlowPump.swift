import Foundation
import Network
import OSLog

// Deliberately does NOT import NetworkExtension. It re-exports a legacy
// `NWEndpoint` *class* that collides with `Network.NWEndpoint`, and every
// endpoint below would silently become ambiguous — the compiler happens to
// resolve it today, which is not a property worth depending on. The one thing
// this file needs from that framework, recognising a benign flow teardown, is
// passed in by the caller instead.

/// One UDP flow, as the pump needs to see it.
///
/// The production conformance wraps `NEAppProxyUDPFlow`, which lives in the
/// system extension and cannot be linked, instantiated or faked off-device.
/// That boundary is why this pump and everything it routes to used to have zero
/// tests despite being the least-proven code in the product — the three-way
/// routing below decides where every datagram on the machine goes, and none of
/// it could be exercised without a signed, notarized, user-approved extension.
public protocol UDPFlow: Sendable {
    func open() async throws
    /// One read delivers a *batch*: several datagrams, each with the endpoint
    /// it is addressed to. That batching is why the pump iterates.
    func read() async throws -> [(Data, NWEndpoint)]
    func write(_ datagram: Data, to endpoint: NWEndpoint) async throws
    /// `async` so an actor can conform. A synchronous method still witnesses
    /// it, which is what the NetworkExtension-backed handle does.
    func close(_ error: Error?) async
}

/// How long a UDP session keeps listening for answers after the client has
/// stopped sending.
///
/// A client having nothing more to *send* does not mean it has nothing more to
/// *receive*. `readDatagrams` completes once the client is done sending, which
/// for DNS is immediately after the single query goes out; closing the stream
/// at that moment discards the answer.
///
/// Bounded rather than open-ended: the flow holds a multiplexed stream, and
/// mDNSResponder opens a fresh flow per lookup, so keeping them alive
/// indefinitely accumulates streams for no benefit. Ten seconds is far longer
/// than any resolver round trip and shorter than a client's own giving-up time.
public enum UDPReplyWindow {
    public static let duration: Duration = .seconds(10)
}

/// Shuttles one UDP flow across the bridge.
///
/// The flow is a session: datagrams go out to many destinations and come back
/// from many, so each direction carries the address with the packet. Every
/// datagram takes one of three routes, decided per packet because a UDP flow
/// has no single remote endpoint to decide once:
///
/// 1. **Bridged** — the ordinary case, sent to the phone.
/// 2. **DNS-redirected** — a query aimed at a resolver we must not bridge,
///    which is nearly always the home router and unreachable the moment the
///    Mac is running on the phone alone.
/// 3. **Direct** — anything else the policy excludes, sent out this Mac's own
///    interface by ``LocalDatagramRelay``.
///
/// Route 3 is not optional. Refusing to bridge is not the same as being able to
/// ignore: the flow is ours, so the system will not deliver what we declined,
/// and dropping those datagrams is a black hole the sender never gets an answer
/// or an error from.
public func pumpDatagramFlow(
    _ flow: any UDPFlow,
    via initiator: BridgeInitiator,
    policy: CapturePolicy,
    dialer: any DestinationDialer,
    replyWindow: Duration = UDPReplyWindow.duration,
    isExpectedTeardown: @escaping @Sendable (Error) -> Bool = { _ in false },
    log: Logger
) async {
    do {
        // Logged like the TCP path. Without these, a UDP flow that is claimed
        // and then goes nowhere leaves no trace at all — the extension looks
        // idle whether it is working perfectly or dropping every datagram, and
        // "no log line" was read as "not captured" for far too long.
        log.error("udp claim")
        try await withFlowDeadline("flow.open") { try await flow.open() }
        log.error("udp opened-flow")

        // Host and port are placeholders: a UDP session has no single
        // destination, and every datagram names its own. The responder must not
        // try to dial this — doing so closed the stream out from under the flow.
        let stream = try await withFlowDeadline("openStream") {
            try await initiator.openStream(
                to: StreamOpen(proto: .udp, host: "*", port: 0)
            )
        }
        log.error("udp stream open")

        let direct = LocalDatagramRelay(flow: flow, dialer: dialer, log: log)
        defer { Task { await direct.close() } }
        let dns = DNSRedirect()

        await withTaskGroup(of: Void.self) { group in
            // App → phone → destinations
            group.addTask {
                // Declared INSIDE the task, not outside it: only this
                // direction writes it, and sharing a `var` across a task group
                // is a data race the compiler rejects outright.
                var seenDestinations = Set<String>()
                while true {
                    guard let batch = try? await flow.read(), !batch.isEmpty else { break }
                    for (datagram, endpoint) in batch {
                        guard case let .hostPort(host, port) = endpoint else { continue }

                        if policy.shouldCapture(remoteEndpoint: "\(host):\(port)") {
                            // ONE error-level line per destination, then debug
                            // for the rest.
                            //
                            // Per-datagram at error level is not an option —
                            // QUIC sends thousands, and a 150 MB HTTP/3
                            // transfer would bury every other line in the log.
                            // But debug-only was the opposite mistake: debug
                            // lives in the memory ring buffer and is the first
                            // thing evicted, so `log show` never surfaces it.
                            //
                            // That left UDP unable to answer the question this
                            // codebase insists on asking — "confirm a flow
                            // actually traversed the bridge, by grepping the
                            // proxy log for that exact destination IP". TCP
                            // could answer it; UDP could not, which is exactly
                            // the traffic class where a silent leak matters
                            // most, because QUIC and DNS are what bypass a
                            // proxy when something is wrong.
                            //
                            // First-sighting is the whole fix: one greppable
                            // line per destination, no volume.
                            if seenDestinations.insert("\(host):\(port.rawValue)").inserted {
                                log.error("udp open  \("\(host)", privacy: .public):\(port.rawValue)")
                            }
                            log.debug("udp -> bridge \("\(host)", privacy: .public):\(port.rawValue) \(datagram.count)B")
                            _ = try? await stream.sendDatagram(
                                datagram, to: "\(host)", port: port.rawValue
                            )
                        } else if port.rawValue == UpLinkDNS.port {
                            log.error("udp -> redirect \("\(host)", privacy: .public):\(port.rawValue)")
                            // Ask a public resolver across the bridge instead,
                            // and hand the answer back as if it came from the
                            // resolver the client asked. Failing DNS stops every
                            // connection before it starts.
                            await dns.remember(original: endpoint, query: datagram)
                            _ = try? await stream.sendDatagram(
                                datagram, to: UpLinkDNS.primary, port: UpLinkDNS.port
                            )
                        } else {
                            await direct.send(datagram, to: endpoint)
                        }
                    }
                }
                // NOT closed here — see ``UDPReplyWindow``.
                try? await Task.sleep(for: replyWindow)
                await stream.close()
            }
            // Destinations → phone → app
            group.addTask {
                while let envelope = await stream.receiveDatagram() {
                    var endpoint = NWEndpoint.hostPort(
                        host: NWEndpoint.Host(envelope.host),
                        port: NWEndpoint.Port(rawValue: envelope.port) ?? .any
                    )
                    // Undo the redirect. A resolver client checks that the reply
                    // came from the address it queried and discards it
                    // otherwise, so the answer has to be re-addressed.
                    if envelope.port == UpLinkDNS.port,
                       let original = await dns.original(forReply: envelope.payload) {
                        endpoint = original
                    }
                    guard (try? await flow.write(envelope.payload, to: endpoint)) != nil else { break }
                }
                await flow.close(nil)
            }
        }
    } catch {
        // "The peer closed the flow" is ordinary churn here, not a fault: short
        // UDP exchanges (DNS above all) finish and close while the flow is
        // still being set up. Logging it at error level produced hundreds of
        // entries an hour that evicted the session diagnostics from the log
        // buffer — the noise actively cost us the signal.
        if isExpectedTeardown(error) {
            log.debug("udp flow closed by peer before setup")
        } else {
            log.error("udp flow failed: \(String(describing: error), privacy: .public)")
        }
        await flow.close(error)
    }
}

/// Remembers which resolver a client believed it was talking to.
///
/// The reply must appear to come from the address the client asked, or the
/// resolver library discards it as unsolicited. Thin actor around
/// ``DNSRedirectTable``: the bookkeeping lives there so it can be tested
/// without a system extension; this adds isolation and the `NWEndpoint`
/// conversion.
public actor DNSRedirect {

    private var table = DNSRedirectTable()
    /// Descriptions are what the table stores; this maps back to a real
    /// endpoint for the write.
    private var endpoints: [String: NWEndpoint] = [:]

    public init() {}

    public func remember(original: NWEndpoint, query: Data) {
        let key = String(describing: original)
        endpoints[key] = original
        table.remember(query: query, endpoint: key)
    }

    public func original(forReply reply: Data) -> NWEndpoint? {
        guard let key = table.original(forReply: reply) else { return nil }
        return endpoints[key]
    }
}

/// Sends datagrams that must NOT cross the bridge straight out of this Mac,
/// and relays the replies back into the flow.
///
/// A claimed UDP flow is ours to service completely. The capture policy
/// legitimately refuses some destinations — this Mac's DNS resolvers, the local
/// network, the link to the phone — but refusing is not the same as being able
/// to ignore them: the system will not deliver a datagram on a flow we have
/// taken. Without this outlet those datagrams vanish, and since DNS is the
/// first thing every connection does, the whole machine feels throttled.
///
/// Safe from re-capture by construction: every destination handled here is one
/// `CapturePolicy` already excludes, and `FlowAdmission` declines flows from
/// the extension's own signing identifier regardless — so the socket opened
/// below is never handed back to us.
public actor LocalDatagramRelay {

    private let flow: any UDPFlow
    private let dialer: any DestinationDialer
    private let log: Logger

    private var connections: [String: DestinationConnection] = [:]
    private var pumps: [String: Task<Void, Never>] = [:]

    public init(flow: any UDPFlow, dialer: any DestinationDialer, log: Logger) {
        self.flow = flow
        self.dialer = dialer
        self.log = log
    }

    public func send(_ datagram: Data, to endpoint: NWEndpoint) async {
        guard case let .hostPort(host, port) = endpoint else { return }
        let key = "\(host):\(port)"

        if let existing = connections[key] {
            try? await existing.send(datagram)
            return
        }

        let destination = StreamOpen(proto: .udp, host: "\(host)", port: port.rawValue)
        guard let connection = try? await dialer.connect(to: destination) else {
            log.debug("direct datagram to \(key, privacy: .public) could not be opened")
            return
        }
        connections[key] = connection

        pumps[key] = Task { [weak self] in
            guard let self else { return }
            await self.pumpReplies(from: connection, to: endpoint)
        }
        try? await connection.send(datagram)
    }

    private func pumpReplies(from connection: DestinationConnection, to endpoint: NWEndpoint) async {
        while !Task.isCancelled {
            guard let reply = try? await connection.receive(), !reply.isEmpty else { break }
            guard (try? await flow.write(reply, to: endpoint)) != nil else { break }
        }
    }

    public func close() async {
        for (_, pump) in pumps { pump.cancel() }
        pumps.removeAll()
        for (_, connection) in connections { await connection.close() }
        connections.removeAll()
    }
}

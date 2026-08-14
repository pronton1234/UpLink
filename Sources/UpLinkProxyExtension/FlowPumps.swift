import Foundation
import NetworkExtension
import OSLog
import UpLinkKit

// Flow objects are not Sendable, and the pumps are free functions rather than
// methods so they capture only Sendable values — the provider itself is a
// non-Sendable NSObject subclass and must not cross into a task.

/// How long any single step of claiming a flow may take.
///
/// **Nothing on this path may wait forever.** `handleNewFlow` returning `true`
/// means the extension owns that connection; the system will not deliver it,
/// and the app has no timeout of its own beyond its own patience. A step that
/// hangs therefore produces a flow owned by us and serviced by nobody, which
/// the user experiences as "no connectivity" while both ends report a healthy
/// session. Failing fast is strictly better: the app sees a closed connection
/// and can retry or report an error.
let flowStepTimeout: Duration = .seconds(10)

/// Runs `operation`, or throws if it does not finish in time.
func withFlowDeadline<T: Sendable>(
    _ label: String,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: flowStepTimeout)
            throw FlowTimeout(step: label)
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

struct FlowTimeout: Error, CustomStringConvertible {
    let step: String
    var description: String { "timed out in \(step)" }
}

/// Shuttles one TCP flow across the bridge in both directions.
///
/// Bytes move flow → stream → socket and back with no intermediate storage:
/// each `Data` is handed straight on and released. Nothing touches disk.
func pumpTCP(
    _ handle: TCPFlowHandle,
    to destination: StreamOpen,
    via initiator: BridgeInitiator,
    log: Logger
) async {
    do {
        // Logged on the way IN, not just on failure. Only failures were logged
        // before, so "no tcp flow lines" was ambiguous between "every flow
        // succeeded" and "no flow was ever created" — and those two have
        // opposite causes. Distinguishing them took several rounds of guessing.
        let where_ = "\(destination.host):\(destination.port)"
        log.error("tcp claim \(where_, privacy: .public)")

        // Two awaits, logged separately: which one hangs decides where the
        // fault is, and until they were distinguishable the two were
        // indistinguishable in the log.
        try await withFlowDeadline("flow.open") { try await handle.open() }
        log.error("tcp opened-flow \(where_, privacy: .public)")

        let stream = try await withFlowDeadline("openStream") {
            try await initiator.openStream(to: destination)
        }
        log.error("tcp open  \(where_, privacy: .public)")

        // Read and write run concurrently on purpose: a flow's two directions
        // are independent, and serialising them would halve throughput on any
        // duplex connection. Each direction also keeps one read outstanding *while* the previous chunk
        // is being written. Asking the flow for more bytes only after the send
        // has completed end to end — mux framing, actor hops, socket write
        // acknowledgement — leaves the link idle for that whole round, and
        // NetworkExtension hands back whatever is buffered, so those rounds are
        // frequent and small. Exactly one read is ever in flight, which is what
        // the flow API requires.
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                var inFlight = Task { try? await handle.read() }
                while true {
                    guard let data = await inFlight.value, !data.isEmpty else { break }
                    inFlight = Task { try? await handle.read() }
                    guard (try? await stream.send(data)) != nil else { break }
                }
                inFlight.cancel()
                await stream.close()
            }
            group.addTask {
                var inFlight = Task { await stream.receive() }
                while true {
                    guard let data = await inFlight.value else { break }
                    inFlight = Task { await stream.receive() }
                    guard (try? await handle.write(data)) != nil else { break }
                }
                inFlight.cancel()
                handle.closeBoth(nil)
            }
        }
    } catch {
        log.error("tcp FAIL  \(destination.host, privacy: .public):\(destination.port, privacy: .public) — \(String(describing: error), privacy: .public)")
        handle.closeBoth(error)
    }
}

/// Shuttles one UDP flow across the bridge.
///
/// The flow is a session: datagrams go out to many destinations and come back
/// from many, so each direction carries the address with the packet.
/// How long a UDP session keeps listening for answers after the client has
/// stopped sending. See the note in ``pumpUDP`` for what closing early cost.
enum UDPReplyWindow {
    static let seconds: TimeInterval = 10
}

func pumpUDP(
    _ handle: UDPFlowHandle,
    via initiator: BridgeInitiator,
    policy: CapturePolicy,
    log: Logger
) async {
    do {
        // Logged like the TCP path. Without these, a UDP flow that is claimed
        // and then goes nowhere leaves no trace at all — the extension looks
        // idle whether it is working perfectly or dropping every datagram, and
        // "no log line" was read as "not captured" for far too long.
        log.error("udp claim")
        try await withFlowDeadline("flow.open") { try await handle.open() }
        log.error("udp opened-flow")
        // Host/port are placeholders: a UDP session has no single destination,
        // and every datagram names its own.
        let stream = try await withFlowDeadline("openStream") {
            try await initiator.openStream(
                to: StreamOpen(proto: .udp, host: "*", port: 0)
            )
        }
        log.error("udp stream open")
        let direct = LocalDatagramRelay(handle: handle, log: log)
        defer { Task { await direct.close() } }
        let dns = DNSRedirect()

        await withTaskGroup(of: Void.self) { group in
            // App → phone → destinations
            group.addTask {
                while true {
                    guard let batch = try? await handle.read(), !batch.isEmpty else { break }
                    for (datagram, endpoint) in batch {
                        guard case let .hostPort(host, port) = endpoint else { continue }
                        // Same gate as TCP: never bridge our own link to the
                        // phone, loopback, mDNS, the local network, or this
                        // Mac's DNS resolvers. A UDP flow has no single remote
                        // endpoint, so this is judged per datagram.
                        if policy.shouldCapture(remoteEndpoint: "\(host):\(port)") {
                            log.error("udp -> bridge \("\(host)", privacy: .public):\(port.rawValue) \(datagram.count)B")
                            _ = try? await stream.sendDatagram(
                                datagram, to: "\(host)", port: port.rawValue
                            )
                        } else if port.rawValue == UpLinkDNS.port {
                            log.error("udp -> redirect \("\(host)", privacy: .public):\(port.rawValue)")
                            // A DNS query aimed at a resolver we must not
                            // bridge — nearly always the home router, and
                            // unreachable the moment the Mac is running on the
                            // phone alone. Sending it out the Mac's own
                            // interface would fail, and failing DNS stops every
                            // connection before it starts.
                            //
                            // So redirect it: ask a public resolver across the
                            // bridge instead, and hand the answer back as if it
                            // came from the resolver the client asked.
                            await dns.remember(original: endpoint, query: datagram)
                            _ = try? await stream.sendDatagram(
                                datagram, to: UpLinkDNS.primary, port: UpLinkDNS.port
                            )
                        } else {
                            // Not bridged — but the flow is ours, so the system
                            // will not deliver this for us. Dropping it silently
                            // is what broke DNS. Send it out this Mac's own
                            // interface instead and relay the reply back.
                            await direct.send(datagram, to: endpoint)
                        }
                    }
                }
                // NOT closed here. A client having nothing more to *send* does
                // not mean it has nothing more to *receive*.
                //
                // `readDatagrams` completes with nil once the client is done
                // sending, which for DNS is immediately after the single query
                // goes out. Closing the stream at that moment made the phone
                // run `closeStream` and cancel the destination roughly 3 ms
                // after dialling it — measured on device:
                //
                //     23:55:13.541  udp dial ok 1.1.1.1:53
                //     23:55:13.544  udp 1.1.1.1:53 ended after 0 replies
                //
                // so the answer was discarded before it could arrive. One
                // datagram out and one back loses that race every time, which
                // is why no hostname resolved while TCP ran at full speed.
                //
                // The reply window is bounded rather than open-ended: the flow
                // holds a multiplexed stream, and mDNSResponder opens a fresh
                // flow per lookup, so keeping them alive indefinitely would
                // accumulate streams for no benefit. Ten seconds is far longer
                // than any resolver round trip and shorter than the client's
                // own giving-up time.
                try? await Task.sleep(for: .seconds(UDPReplyWindow.seconds))
                await stream.close()
            }
            // Destinations → phone → app
            group.addTask {
                while let envelope = await stream.receiveDatagram() {
                    var endpoint = NWEndpoint.hostPort(
                        host: NWEndpoint.Host(envelope.host),
                        port: NWEndpoint.Port(rawValue: envelope.port) ?? .any
                    )
                    // Undo the redirect. A resolver client checks that the
                    // reply came from the address it queried and discards it
                    // otherwise, so the answer has to be re-addressed.
                    if envelope.port == UpLinkDNS.port,
                       let original = await dns.original(forReply: envelope.payload) {
                        endpoint = original
                    }
                    guard (try? await handle.write(envelope.payload, to: endpoint)) != nil else { break }
                }
                handle.close(nil)
            }
        }
    } catch {
        // "The peer closed the flow" is ordinary churn here, not a fault: short
        // UDP exchanges (DNS above all) finish and close while the flow is
        // still being set up. Logging it at error level produced hundreds of
        // entries an hour that evicted the session diagnostics from the log
        // buffer — the noise actively cost us the signal. Real faults still
        // surface.
        if (error as NSError).code == NEAppProxyFlowError.peerReset.rawValue {
            log.debug("udp flow closed by peer before setup")
        } else {
            log.error("udp flow failed: \(String(describing: error), privacy: .public)")
        }
        handle.close(error)
    }
}

/// Remembers which resolver a client believed it was talking to.
///
/// DNS queries are redirected to a public resolver across the bridge, because
/// the resolver the Mac is configured with is usually the home router and is
/// unreachable whenever the Mac is running on the phone alone. The reply must
/// still appear to come from the address the client asked, or the resolver
/// library discards it as unsolicited.
///
/// One entry per flow rather than a table: a DNS flow talks to a single
/// resolver, and holding the most recent original is enough to re-address its
/// replies. If a client did rotate resolvers within one flow, the worst case is
/// a reply attributed to the wrong one of its own resolvers, which it retries.
/// Thin actor around ``DNSRedirectTable``.
///
/// The bookkeeping lives in the kit so it can be tested without a system
/// extension; this only adds isolation and the `NWEndpoint` conversion. See
/// `DNSRedirectTable` for why a single stored endpoint was wrong.
actor DNSRedirect {

    private var table = DNSRedirectTable()
    /// Descriptions are what the table stores; this maps back to a real
    /// endpoint for the write.
    private var endpoints: [String: NWEndpoint] = [:]

    func remember(original: NWEndpoint, query: Data) {
        let key = String(describing: original)
        endpoints[key] = original
        table.remember(query: query, endpoint: key)
    }

    func original(forReply reply: Data) -> NWEndpoint? {
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
/// `CapturePolicy` already excludes, so the socket opened below is declined by
/// `handleNewFlow` and routed normally instead of looping back into the bridge.
actor LocalDatagramRelay {

    private let handle: UDPFlowHandle
    private let log: Logger
    /// No cellular pin: the point is to use this Mac's own path.
    private let dialer = CellularDialer(
        queue: DispatchQueue(label: "com.uplink.app.proxy.direct.dial"),
        requiredInterface: nil
    )

    private var connections: [String: DestinationConnection] = [:]
    private var pumps: [String: Task<Void, Never>] = [:]

    init(handle: UDPFlowHandle, log: Logger) {
        self.handle = handle
        self.log = log
    }

    func send(_ datagram: Data, to endpoint: NWEndpoint) async {
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
            guard (try? await handle.write(reply, to: endpoint)) != nil else { break }
        }
    }

    func close() async {
        for (_, pump) in pumps { pump.cancel() }
        pumps.removeAll()
        for (_, connection) in connections { await connection.close() }
        connections.removeAll()
    }
}

/// Holds one TCP flow across isolation boundaries.
///
/// `NEAppProxyTCPFlow` is not `Sendable`, but NetworkExtension documents it as
/// safe to use from any queue provided each *direction* is driven serially —
/// exactly how it is used here: one task owns reads, another owns writes,
/// neither touches the other's direction.
final class TCPFlowHandle: @unchecked Sendable {

    private let flow: NEAppProxyTCPFlow

    init(_ flow: NEAppProxyTCPFlow) { self.flow = flow }

    func open() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            flow.open(withLocalFlowEndpoint: nil) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func read() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            flow.readData { data, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: data ?? Data()) }
            }
        }
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            flow.write(data) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func closeBoth(_ error: Error?) {
        flow.closeReadWithError(error)
        flow.closeWriteWithError(error)
    }
}

/// Holds one UDP flow across isolation boundaries.
///
/// The read API is batched — one callback delivers several datagrams with their
/// endpoints — which is why the pump iterates rather than handling one packet.
final class UDPFlowHandle: @unchecked Sendable {

    private let flow: NEAppProxyUDPFlow

    init(_ flow: NEAppProxyUDPFlow) { self.flow = flow }

    func open() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            flow.open(withLocalFlowEndpoint: nil) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    /// One read delivers a *batch*: several datagrams, each paired with the
    /// endpoint it is addressed to. That batching is why the pump iterates
    /// rather than handling a single packet per call.
    func read() async throws -> [(Data, NWEndpoint)] {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<[(Data, NWEndpoint)], Error>) in
            flow.readDatagrams { batch, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: batch ?? []) }
            }
        }
    }

    func write(_ datagram: Data, to endpoint: NWEndpoint) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            flow.writeDatagrams([(datagram, endpoint)]) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func close(_ error: Error?) {
        flow.closeReadWithError(error)
        flow.closeWriteWithError(error)
    }
}

/// Carries a non-`Sendable` value into a task.
///
/// NetworkExtension's completion handlers predate strict concurrency and are
/// not annotated `@Sendable`, yet the framework's contract is simply that each
/// is invoked exactly once — which is what the call sites here do.
struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

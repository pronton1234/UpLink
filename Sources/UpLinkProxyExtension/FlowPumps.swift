import Foundation
import NetworkExtension
import OSLog
import UpLinkKit

// Flow objects are not Sendable, and the pumps are free functions rather than
// methods so they capture only Sendable values — the provider itself is a
// non-Sendable NSObject subclass and must not cross into a task.

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
        // COUNTED, because "the stream opened" and "the stream carried
        // something" are different facts and only the first was observable.
        //
        // A flow that opens and then moves nothing looks identical in the log
        // to one that works — and that is precisely the difference between an
        // application that loads and one that hangs. Reported once per flow, on
        // the way out, so a session's log says what actually crossed.
        let moved = await withTaskGroup(of: (Bool, Int).self) { group -> (Int, Int) in
            group.addTask {
                var sent = 0
                var inFlight = Task { try? await handle.read() }
                while true {
                    guard let data = await inFlight.value, !data.isEmpty else { break }
                    inFlight = Task { try? await handle.read() }
                    guard (try? await stream.send(data)) != nil else { break }
                    sent += data.count
                }
                inFlight.cancel()
                await stream.close()
                return (true, sent)
            }
            group.addTask {
                var received = 0
                var inFlight = Task { await stream.receive() }
                while true {
                    guard let data = await inFlight.value else { break }
                    inFlight = Task { await stream.receive() }
                    guard (try? await handle.write(data)) != nil else { break }
                    received += data.count
                }
                inFlight.cancel()
                handle.closeBoth(nil)
                return (false, received)
            }
            var up = 0
            var down = 0
            for await (isUp, count) in group {
                if isUp { up = count } else { down = count }
            }
            return (up, down)
        }
        log.error(
            "tcp done  \(where_, privacy: .public) — \(moved.0, privacy: .public) up / \(moved.1, privacy: .public) down"
        )
    } catch {
        log.error("tcp FAIL  \(destination.host, privacy: .public):\(destination.port, privacy: .public) — \(String(describing: error), privacy: .public)")
        handle.closeBoth(error)
    }
}

/// Bridges one UDP flow.
///
/// A thin adapter now: the routing, the reply window, the DNS redirect and the
/// direct outlet all live in `UpLinkKit`'s ``pumpDatagramFlow``, where they can
/// be tested against a fake flow and a real socket. They used to live here, in
/// an app target the test bundle cannot import, which is why the least-proven
/// code in the product had no tests at all.
func pumpUDP(
    _ handle: UDPFlowHandle,
    via initiator: BridgeInitiator,
    policy: CapturePolicy,
    log: Logger
) async {
    await pumpDatagramFlow(
        handle,
        via: initiator,
        policy: policy,
        // No cellular pin: the point of the direct outlet is to use this Mac's
        // own path, for destinations the phone could not reach anyway.
        dialer: CellularDialer(
            queue: DispatchQueue(label: "com.uplink.app.proxy.direct.dial"),
            requiredInterface: nil
        ),
        // Short UDP exchanges — DNS above all — finish and close while the flow
        // is still being set up. That is ordinary churn, not a fault, and
        // logging it at error level produced hundreds of entries an hour that
        // evicted the session diagnostics from the log buffer.
        isExpectedTeardown: { ($0 as NSError).code == NEAppProxyFlowError.peerReset.rawValue },
        log: log
    )
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
final class UDPFlowHandle: UDPFlow, @unchecked Sendable {

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

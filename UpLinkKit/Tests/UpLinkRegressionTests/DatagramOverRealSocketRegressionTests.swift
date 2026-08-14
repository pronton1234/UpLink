import Testing
import Foundation
import Network
@testable import UpLinkKit

// SYMPTOM: on hardware, with the bridge up and TCP running at 98 Mbps, no
// hostname would resolve. The phone's own log showed the destination being
// dialled successfully and then dying before any answer arrived:
//
//     23:55:13.541  udp dial ok 1.1.1.1:53
//     23:55:13.544  udp 1.1.1.1:53 ended after 0 replies     ← 3 ms later
//
// Three milliseconds is not a network timeout — a cellular round trip is ~50 ms
// — so the destination was being torn down locally, immediately, before the
// reply could land. DNS is one datagram out and one back, so it lost that race
// every single time, while TCP was untouched.
//
// WHY THE EXISTING LOOPBACK TESTS MISSED IT: `LoopbackDatagramTests` wires the
// session actors to a *stub* `EchoDestination` whose `receive()` simply suspends
// forever when it has nothing to give. The real `NWDestinationConnection`
// returns nil once it considers itself closed, and the whole defect lives in
// when that happens. A stub can only ever confirm the author's assumptions
// about the framework; this suite uses a real socket so it cannot.

// `.serialized`: this binds a real loopback UDP listener and races a real
// dialler against it. Run concurrently with the rest of the suite it competes
// for sockets and scheduler time, and a timing-sensitive test that fails for
// reasons unrelated to the defect is worse than no test.
@Suite("Regression: datagrams over a real socket, end to end", .serialized)
struct DatagramOverRealSocketRegressionTests {

    /// A real UDP echo server on loopback.
    private actor EchoServer {
        private var listener: NWListener?
        private var connections: [NWConnection] = []

        func start(on queue: DispatchQueue) throws -> UInt16 {
            let parameters = NWParameters(dtls: nil, udp: NWProtocolUDP.Options())
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters)
            self.listener = listener

            listener.newConnectionHandler = { connection in
                connection.start(queue: queue)
                Task { await self.hold(connection) }
                func receiveLoop() {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, error in
                        if let data, !data.isEmpty {
                            connection.send(content: data + Data([0xEE]), completion: .contentProcessed { _ in })
                        }
                        if error == nil { receiveLoop() }
                    }
                }
                receiveLoop()
            }
            listener.start(queue: queue)

            for _ in 0 ..< 300 {
                if let port = listener.port, port.rawValue != 0 { return port.rawValue }
                usleep(10_000)
            }
            throw ChannelError.handshakeFailed("echo listener never bound")
        }

        private func hold(_ connection: NWConnection) { connections.append(connection) }

        func stop() {
            listener?.cancel()
            for connection in connections { connection.cancel() }
        }
    }

    private func awaitDatagram(
        _ stream: ProxiedStream,
        timeout: TimeInterval = 10
    ) async -> DatagramEnvelope? {
        await withTaskGroup(of: DatagramEnvelope?.self) { group in
            group.addTask { await stream.receiveDatagram() }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // SYMPTOM: found by this suite going red only when run alongside the rest
    // of the tests, and passing in isolation — a race, not a flake.
    //
    // `BridgeResponder.handle` sends every `.openRequested` to
    // `openDestination`, which dials. But a UDP OPEN does not name a
    // destination: it registers a *session*, with the placeholder
    // `StreamOpen(proto: .udp, host: "*", port: 0)`, and every datagram
    // carries its own address. So the phone dialled `*:0`, that failed, and
    // `failStream` wrote a CLOSE — killing the stream the flow had just been
    // given. Every UDP flow was racing that CLOSE: win and the datagrams got
    // through, lose and the stream was gone before the first reply.
    //
    // WHY EVERY OTHER DATAGRAM TEST MISSES IT: `LoopbackDatagramTests` and the
    // rest wire the responder to a *stub* dialer (`FanOutDialer`) that answers
    // for any host, `*` included. The bogus connection is registered, nothing
    // fails, nothing closes. Only a real `CellularDialer` can refuse to dial
    // `*`, which is the whole reason this suite exists.
    //
    // Deterministic on purpose: the sleep puts the failed dial firmly in the
    // past before the first datagram, so this asserts the property instead of
    // re-running the race.
    @Test("A UDP session OPEN does not dial its placeholder destination")
    func udpOpenDoesNotDialThePlaceholder() async throws {
        let queue = DispatchQueue(label: "regression.udp.open")
        let server = EchoServer()
        let port = try await server.start(on: queue)
        defer { Task { await server.stop() } }

        let dialer = CellularDialer(queue: queue, requiredInterface: nil)
        let (macSide, phoneSide) = await InMemoryFrameChannel.makePair()
        let initiator = BridgeInitiator(channel: macSide)
        let responder = BridgeResponder(channel: phoneSide, dialer: dialer)
        let tasks = [
            Task { do { try await responder.run() } catch {} },
            Task { do { try await initiator.run() } catch {} },
        ]
        defer { tasks.forEach { $0.cancel() } }

        let stream = try await initiator.openStream(
            to: StreamOpen(proto: .udp, host: "*", port: 0)
        )

        // Long enough that a dial of "*" has certainly resolved and failed.
        try await Task.sleep(for: .milliseconds(1000))

        let payload = Data("still-here".utf8)
        try await stream.sendDatagram(payload, to: "127.0.0.1", port: port)

        let reply = await awaitDatagram(stream, timeout: 5)
        #expect(
            reply?.payload.prefix(payload.count) == payload,
            "the UDP session stream was closed by a dial it should never have made"
        )
    }

    /// The device failure, reduced to one process: a resolver is a single
    /// destination that must answer repeatedly. Before the fix the first reply
    /// arrived and everything after it was lost.
    @Test("One destination answers several datagrams in a row")
    func destinationAnswersRepeatedly() async throws {
        let queue = DispatchQueue(label: "regression.udp.e2e")
        let server = EchoServer()
        let port = try await server.start(on: queue)
        defer { Task { await server.stop() } }

        // The REAL dialer against a real socket — the point of this suite.
        let dialer = CellularDialer(queue: queue, requiredInterface: nil)
        let (macSide, phoneSide) = await InMemoryFrameChannel.makePair()
        let initiator = BridgeInitiator(channel: macSide)
        let responder = BridgeResponder(channel: phoneSide, dialer: dialer)
        let tasks = [
            Task { do { try await responder.run() } catch {} },
            Task { do { try await initiator.run() } catch {} },
        ]
        defer { tasks.forEach { $0.cancel() } }

        let stream = try await initiator.openStream(
            to: StreamOpen(proto: .udp, host: "*", port: 0)
        )

        for attempt in 1 ... 3 {
            let payload = Data("query-\(attempt)".utf8)
            try await stream.sendDatagram(payload, to: "127.0.0.1", port: port)

            let reply = await awaitDatagram(stream)
            #expect(
                reply?.payload.prefix(payload.count) == payload,
                "datagram \(attempt) never came back — the destination died early"
            )
        }
    }
}

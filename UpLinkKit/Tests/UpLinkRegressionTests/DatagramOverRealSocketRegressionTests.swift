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

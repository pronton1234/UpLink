import Testing
import Foundation
import Network
@testable import UpLinkKit

// SYMPTOM: with the bridge up, carrying TCP at 98 Mbps and correctly reporting
// cellular egress, every hostname failed to resolve after ~30 seconds and the
// Mac's log filled with:
//
//     udp flow failed: Error Domain=NEAppProxyFlowErrorDomain Code=5
//                      "The flow was aborted"
//
// Raw-IP transfers were untouched — 5 MB in 0.407s — so the bridge was healthy
// and only UDP was broken. It also *looked* intermittent: a lookup would
// succeed, then the same name would fail moments later, which sent the
// investigation towards DNS bookkeeping twice before landing here.
//
// CAUSE: `NWDestinationConnection.pump()` treated `isComplete` as end-of-
// connection:
//
//     if isComplete || error != nil { finish() } else { pump() }
//
// That is right for TCP, where `isComplete` means FIN. For a UDP connection the
// flag marks the end of each *message*. So the first reply datagram closed the
// connection, `receive()` returned nil forever after, `pumpDatagrams` broke out
// of its loop, and that destination was dead. One answer per destination, ever.
//
// DNS is the worst possible victim: a resolver is a single destination that
// must answer many queries, so the first lookup worked and everything after it
// hung until the flow was aborted.

@Suite("Regression: a UDP destination must survive its first reply")
struct DatagramConnectionRegressionTests {

    /// A loopback UDP echo server. Real sockets rather than a stub, because the
    /// bug is entirely in how Network framework's `isComplete` is interpreted —
    /// a stub would have echoed whatever semantics the test author assumed.
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
                            connection.send(content: data, completion: .contentProcessed { _ in })
                        }
                        if error == nil { receiveLoop() }
                    }
                }
                receiveLoop()
            }
            listener.start(queue: queue)

            for _ in 0 ..< 200 {
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

    /// The defect, reduced: send three datagrams to one destination and expect
    /// three replies. Before the fix exactly one arrived and the rest hung.
    @Test("A UDP destination answers more than once")
    func udpDestinationSurvivesFirstReply() async throws {
        let queue = DispatchQueue(label: "regression.udp.echo")
        let server = EchoServer()
        let port = try await server.start(on: queue)
        defer { Task { await server.stop() } }

        // requiredInterface nil: loopback, not a radio. Same code path otherwise.
        let dialer = CellularDialer(queue: queue, requiredInterface: nil)
        let connection = try await dialer.connect(
            to: StreamOpen(proto: .udp, host: "127.0.0.1", port: port)
        )
        defer { Task { await connection.close() } }

        for attempt in 1 ... 3 {
            let payload = Data("query-\(attempt)".utf8)
            try await connection.send(payload)

            let reply = try await withThrowingTaskGroup(of: Data?.self) { group in
                group.addTask { try await connection.receive() }
                group.addTask {
                    try await Task.sleep(for: .seconds(3))
                    return nil
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                return first
            }

            #expect(
                reply == payload,
                "datagram \(attempt) was not echoed back — the destination died after reply 1"
            )
        }
    }
}

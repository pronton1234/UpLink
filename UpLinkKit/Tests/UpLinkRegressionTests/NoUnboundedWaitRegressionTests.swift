import Testing
import Foundation
import Network
@testable import UpLinkKit

// SYMPTOM: every TCP row of the coverage matrix reported "no connectivity"
// while both UIs showed a healthy session and the phone had just measured
// 666 Mbps on its own. The flow log showed the shape of it exactly:
//
//   21:29:50  egress: Cellular          ← the channel was working
//   21:29:54  tcp claim 191.96.106.7:443
//   21:29:57  tcp claim 45.83.223.233:443
//   …four claims, zero opens, zero failures…
//
// `handleNewFlow` returning true means the extension OWNS that connection: the
// system will not deliver it and the app has no recourse. A step that hangs
// leaves the flow owned by us and serviced by nobody, which is indistinguishable
// from a dead network — and worse than an error, because an error is
// recoverable.
//
// CAUSE, and the third instance of it in one evening: an unbounded await on the
// critical path. First the TLS handshake resuming only on .ready/.failed while
// the failure arrived as .waiting. Then CellularDialer hanging on a dial that
// could never be satisfied. Now `NWConnectionChannel.send`, which awaited
// `.contentProcessed` with no deadline — so a peer that stops draining blocks
// every writer, including the one sending the OPEN frame for a new flow.
//
// Receives were already bounded by `receiveHighWater`. Sends were not. That
// asymmetry was the bug.

@Suite("Regression: nothing on the flow path waits forever")
struct NoUnboundedWaitRegressionTests {

    @Test("Every timeout on the critical path is bounded and usable")
    func timeoutsAreBounded() {
        // A hung step must fail inside a browser's patience, not outlast it.
        #expect(NWConnectionChannel.sendTimeout > 0)
        #expect(NWConnectionChannel.sendTimeout <= 30)
        #expect(NWConnectionChannel.connectTimeout > 0)
        #expect(NWConnectionChannel.connectTimeout <= 30)
        #expect(NWDestinationConnection.connectTimeout > 0)
        #expect(NWDestinationConnection.connectTimeout <= 30)
    }

    /// The actual defect: a peer that accepts a connection and then never reads
    /// must not block the writer forever.
    @Test("A write to a peer that never drains fails instead of hanging")
    func stalledPeerFailsTheWrite() async throws {
        let queue = DispatchQueue(label: "regression.stall")

        // A listener that accepts and then deliberately never receives.
        let listener = try NWListener(using: .tcp)
        let held = Box<NWConnection?>(nil)
        listener.newConnectionHandler = { connection in
            held.value = connection
            connection.start(queue: queue)   // started, but never `receive`s
        }
        listener.start(queue: queue)
        defer { listener.cancel() }

        var bound: NWEndpoint.Port?
        for _ in 0 ..< 100 {
            if let port = listener.port, port.rawValue != 0 { bound = port; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let port = try #require(bound)

        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let channel = NWConnectionChannel(connection: connection)
        defer { connection.cancel() }
        try await channel.start(on: queue)

        // Enough to overrun the socket buffers so `.contentProcessed` stops
        // being called. Before the fix this loop never returned.
        let started = Date()
        let chunk = Data(repeating: 0xEE, count: 1 << 20)
        await #expect(throws: (any Error).self) {
            for _ in 0 ..< 512 { try await channel.send(chunk) }
        }
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < NWConnectionChannel.sendTimeout * 3,
                "took \(elapsed)s — a stalled peer should fail the write, not block on it")
    }
}

/// Minimal holder so an inbound connection is not deallocated.
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

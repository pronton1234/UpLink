import Testing
import Foundation
import Network
@testable import UpLinkKit

// SYMPTOM: the bridge worked but was no faster than the throttled hotspot it
// exists to replace. Every correctness test passed, because every one of them
// used a dialer that answered instantly and a destination that never blocked.
//
// CAUSE: `BridgeResponder.run()` is a single sequential task — until
// `handle(_:)` returns, the next frame is not decoded. Both the destination
// dial (DNS + TCP handshake, 60–230 ms on cellular) and the destination write
// were awaited inside it, so one connection being established or one congested
// socket stalled *every* stream on the link. A page opening thirty connections
// serialised into seconds of dead air.
//
// These tests pin the property that actually broke: work for one stream must
// not delay another. They assert on wall-clock separation, with margins wide
// enough to survive a loaded CI machine but far too tight to pass if the work
// is serialised again.

/// A destination that can be made slow to dial and slow to write, per host.
private actor ControllableDestination: DestinationConnection {

    private var pendingResponse: [Data]
    private let writeDelay: Duration
    private var closed = false

    init(response: [Data], writeDelay: Duration = .zero) {
        self.pendingResponse = response
        self.writeDelay = writeDelay
    }

    func egressInterface() async -> EgressInterface { .cellular }

    func send(_ data: Data) async throws {
        if writeDelay != .zero { try? await Task.sleep(for: writeDelay) }
    }

    func receive() async throws -> Data? {
        guard !pendingResponse.isEmpty else {
            // Park instead of returning nil: a closed stream would let the test
            // finish for the wrong reason.
            try? await Task.sleep(for: .seconds(30))
            return nil
        }
        return pendingResponse.removeFirst()
    }

    func close() async { closed = true }
}

/// Applies a per-host delay before returning a connection.
private actor SlowDialer: DestinationDialer {

    private let slowHost: String
    private let dialDelay: Duration
    private let writeDelay: Duration
    private let response: Data

    init(slowHost: String, dialDelay: Duration = .zero, writeDelay: Duration = .zero, response: Data) {
        self.slowHost = slowHost
        self.dialDelay = dialDelay
        self.writeDelay = writeDelay
        self.response = response
    }

    private func isSlow(_ host: String) -> Bool { slowHost == "*" || host == slowHost }

    func connect(to destination: StreamOpen) async throws -> DestinationConnection {
        if isSlow(destination.host), dialDelay != .zero {
            try await Task.sleep(for: dialDelay)
        }
        return ControllableDestination(
            response: [response],
            writeDelay: isSlow(destination.host) ? writeDelay : .zero
        )
    }
}

@Suite("Regression: one stream must not stall another")
struct ConcurrencyRegressionTests {

    private let reply = Data("HTTP/1.1 200 OK\r\n\r\nok".utf8)

    private func makeBridge(
        dialer: DestinationDialer
    ) async -> (initiator: BridgeInitiator, tasks: [Task<Void, Never>]) {
        let (macSide, phoneSide) = await InMemoryFrameChannel.makePair()
        let initiator = BridgeInitiator(channel: macSide)
        let responder = BridgeResponder(channel: phoneSide, dialer: dialer)
        return (initiator, [
            Task { do { try await responder.run() } catch {} },
            Task { do { try await initiator.run() } catch {} },
        ])
    }

    /// The dominant bottleneck. A dial that takes 600 ms must not hold up a
    /// stream to a destination that answers immediately.
    @Test("A slow dial does not delay an unrelated stream")
    func slowDialDoesNotBlockOtherStreams() async throws {
        let dialer = SlowDialer(slowHost: "slow.test", dialDelay: .milliseconds(600), response: reply)
        let (initiator, tasks) = await makeBridge(dialer: dialer)
        defer { tasks.forEach { $0.cancel() } }

        // Opened first, so a serialised implementation must finish it before it
        // even looks at the fast stream.
        let slow = try await initiator.openStream(
            to: StreamOpen(proto: .tcp, host: "slow.test", port: 443))
        try await slow.send(Data("GET /slow\r\n\r\n".utf8))

        let started = Date()
        let fast = try await initiator.openStream(
            to: StreamOpen(proto: .tcp, host: "fast.test", port: 443))
        try await fast.send(Data("GET /fast\r\n\r\n".utf8))

        var body = Data()
        while body.count < reply.count, let chunk = await fast.receive() {
            body.append(chunk)
        }
        let elapsed = Date().timeIntervalSince(started)

        #expect(body == reply)
        #expect(elapsed < 0.4,
                "the fast stream waited \(elapsed)s behind a 0.6s dial — dialling is back on the frame loop")
    }

    /// The same property for writes: a destination whose socket blocks must not
    /// head-of-line-block the whole connection.
    @Test("A slow destination write does not delay an unrelated stream")
    func slowWriteDoesNotBlockOtherStreams() async throws {
        let dialer = SlowDialer(slowHost: "slow.test", writeDelay: .milliseconds(600), response: reply)
        let (initiator, tasks) = await makeBridge(dialer: dialer)
        defer { tasks.forEach { $0.cancel() } }

        let slow = try await initiator.openStream(
            to: StreamOpen(proto: .tcp, host: "slow.test", port: 443))
        try await slow.send(Data("GET /slow\r\n\r\n".utf8))

        // Drain the slow stream's reply first. That proves its connection is
        // established, so the *next* write to it reaches a real socket rather
        // than a queue that is still waiting on the dial — which is what makes
        // this a test of the write path and not of the dial path.
        var slowBody = Data()
        while slowBody.count < reply.count, let chunk = await slow.receive() {
            slowBody.append(chunk)
        }

        // Now issue a write that will block in the destination for 600 ms.
        try await slow.send(Data("POST /slow-upload\r\n\r\n".utf8))

        let started = Date()
        let fast = try await initiator.openStream(
            to: StreamOpen(proto: .tcp, host: "fast.test", port: 443))
        try await fast.send(Data("GET /fast\r\n\r\n".utf8))

        var body = Data()
        while body.count < reply.count, let chunk = await fast.receive() {
            body.append(chunk)
        }
        let elapsed = Date().timeIntervalSince(started)

        #expect(body == reply)
        #expect(elapsed < 0.4,
                "the fast stream waited \(elapsed)s behind a 0.6s write — writes are back on the frame loop")
    }

    /// Many streams opened at once should complete in roughly the time of one
    /// dial, not the sum of all of them. This is the page-load case.
    @Test("Twenty concurrent opens do not serialise")
    func concurrentOpensDoNotSerialise() async throws {
        // Every host is slow here, so serialised behaviour costs 20 x 150 ms.
        let dialer = SlowDialer(slowHost: "*", dialDelay: .milliseconds(150), response: reply)
        let (initiator, tasks) = await makeBridge(dialer: dialer)
        defer { tasks.forEach { $0.cancel() } }

        let started = Date()
        var streams: [ProxiedStream] = []
        for index in 0 ..< 20 {
            let stream = try await initiator.openStream(
                to: StreamOpen(proto: .tcp, host: "host\(index).test", port: 443))
            try await stream.send(Data("GET /\(index)\r\n\r\n".utf8))
            streams.append(stream)
        }

        for stream in streams {
            var body = Data()
            while body.count < reply.count, let chunk = await stream.receive() {
                body.append(chunk)
            }
            #expect(body == reply)
        }
        #expect(Date().timeIntervalSince(started) < 2)
    }

    /// A destination that refuses the connection must fail promptly. Before the
    /// fix, `NWConnection` reported this as `.waiting` — which the dialer did
    /// not handle — so the dial never returned and the stream hung until the
    /// Mac's own flow gave up. That is what produced the flood of
    /// `udp flow failed: The peer closed the flow` in the device logs.
    @Test("A refused destination fails fast rather than hanging")
    func refusedDestinationFailsFast() async throws {
        // Port 1 on loopback: nothing listens there, so the connection is
        // refused immediately. No cellular pin — this machine has no radio.
        let dialer = CellularDialer(queue: DispatchQueue(label: "regression.dial"), requiredInterface: nil)

        let started = Date()
        await #expect(throws: (any Error).self) {
            _ = try await dialer.connect(to: StreamOpen(proto: .tcp, host: "127.0.0.1", port: 1))
        }
        let elapsed = Date().timeIntervalSince(started)

        #expect(elapsed < NWDestinationConnection.connectTimeout,
                "took \(elapsed)s — a refused connection should not wait for the timeout")
    }

    @Test("The destination connect timeout is bounded")
    func connectTimeoutIsBounded() {
        #expect(NWDestinationConnection.connectTimeout > 0)
        #expect(NWDestinationConnection.connectTimeout <= 30)
    }

    /// Credit exhaustion must resolve by being woken, not by spinning. A body
    /// several windows long can only complete if WINDOW frames are processed
    /// while senders are blocked.
    @Test("A transfer larger than the window completes")
    func transferLargerThanWindowCompletes() async throws {
        let large = Data(repeating: 0xAB, count: Multiplexer.initialWindow * 3)
        let dialer = SlowDialer(slowHost: "none", response: large)
        let (initiator, tasks) = await makeBridge(dialer: dialer)
        defer { tasks.forEach { $0.cancel() } }

        let stream = try await initiator.openStream(
            to: StreamOpen(proto: .tcp, host: "bulk.test", port: 443))
        try await stream.send(Data("GET /bulk\r\n\r\n".utf8))

        var body = Data()
        while body.count < large.count, let chunk = await stream.receive() {
            body.append(chunk)
        }
        #expect(body == large)
    }

    /// The receive buffer must stop growing rather than consume the extension's
    /// whole memory budget.
    @Test("The channel declares a bounded receive high-water mark")
    func receiveBufferIsBounded() {
        #expect(NWConnectionChannel.receiveHighWater > 0)
        #expect(NWConnectionChannel.receiveHighWater <= 16 * 1024 * 1024)
    }
}

// The heartbeat is new production behaviour: the phone pings the Mac every
// `heartbeatInterval` so a dead peer is distinguishable from an idle one, and
// so an iOS Network Extension sees periodic socket activity on a quiet bridge.
// Nothing else exercises the ping path — both ends answered pings, but until
// now no code ever sent one.
@Suite("Regression: heartbeat")
struct HeartbeatRegressionTests {

    @Test("A ping is answered with a pong rather than rejected")
    func pingRoundTrips() async throws {
        var mac = Multiplexer(role: .initiator)
        let ping = Frame(kind: .ping, streamID: Multiplexer.controlStreamID)

        // The mux must accept a control-stream ping; an earlier reading of the
        // frame rules would have made this a protocol error.
        let events = try mac.receive(ping)
        #expect(events == [.pingReceived])

        var phone = Multiplexer(role: .responder)
        let pong = Frame(kind: .pong, streamID: Multiplexer.controlStreamID)
        #expect(try phone.receive(pong) == [.pongReceived])
    }

    @Test("The heartbeat interval is set and not absurd")
    func heartbeatIntervalIsSane() {
        #expect(BridgeResponder.heartbeatInterval > .zero)
        #expect(BridgeResponder.heartbeatInterval <= .seconds(60))
    }
}

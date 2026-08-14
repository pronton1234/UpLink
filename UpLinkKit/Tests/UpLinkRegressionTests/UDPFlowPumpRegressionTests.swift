import Testing
import Foundation
import Network
import OSLog
@testable import UpLinkKit

// The three-way datagram routing decides where every UDP packet on the machine
// goes, and until this suite existed none of it had a single test. It lived in
// `Sources/UpLinkProxyExtension/FlowPumps.swift`, an app target the test bundle
// cannot import, so the least-proven code in the product was also the only code
// that could not be exercised without a signed, notarized, user-approved system
// extension. `pumpDatagramFlow` was moved into the kit to close that gap.

/// A `UDPFlow` with no NetworkExtension behind it.
///
/// Stands in for the *app's* end of the flow, not for the network: everything
/// downstream of the routing decision is a real socket.
private actor FakeFlow: UDPFlow {

    /// Batches the pump will read, in order. A `nil` marks the client having
    /// nothing more to send — which is where the reply window starts mattering.
    private var outbound: [[(Data, NWEndpoint)]?]
    private var written: [(Data, NWEndpoint)] = []
    private var closed = false

    init(sending outbound: [[(Data, NWEndpoint)]?]) {
        self.outbound = outbound
    }

    func open() async throws {}

    func read() async throws -> [(Data, NWEndpoint)] {
        guard !outbound.isEmpty else {
            // Nothing further, ever. Suspending rather than returning empty
            // repeatedly keeps this from spinning the pump's loop.
            try await Task.sleep(for: .seconds(60))
            return []
        }
        guard let batch = outbound.removeFirst() else { return [] }
        return batch
    }

    func write(_ datagram: Data, to endpoint: NWEndpoint) async throws {
        guard !closed else { throw ChannelError.peerClosed }
        written.append((datagram, endpoint))
    }

    func close(_ error: Error?) { closed = true }

    var receivedPayloads: [Data] { written.map(\.0) }
    var receivedEndpoints: [NWEndpoint] { written.map(\.1) }

    /// Waits for the flow to be written to, or gives up.
    ///
    /// Polled rather than signalled: each `await` here suspends the actor, so
    /// `write` still runs, and the alternative — parking a continuation — has
    /// to be resumed from a nonisolated context this actor cannot offer.
    func waitForWrite(timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while written.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// A real UDP echo server that answers after a delay.
///
/// The delay is the whole point: an answer that arrives instantly cannot lose a
/// race against a stream being torn down, so a zero-latency fixture proves the
/// reply window is present but never that it is load-bearing.
private actor SlowEchoServer {
    private var listener: NWListener?
    private var connections: [NWConnection] = []

    func start(on queue: DispatchQueue, delay: TimeInterval) throws -> UInt16 {
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
                        queue.asyncAfter(deadline: .now() + delay) {
                            connection.send(content: data, completion: .contentProcessed { _ in })
                        }
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

@Suite("Regression: the UDP flow pump", .serialized)
struct UDPFlowPumpRegressionTests {

    private static let log = Logger(subsystem: "com.uplink.tests", category: "udp-pump")

    /// Wires a pump to a live initiator/responder pair and runs it.
    private func runPump(
        flow: FakeFlow,
        policy: CapturePolicy,
        dialer: any DestinationDialer,
        replyWindow: Duration,
        responderDialer: (any DestinationDialer)? = nil
    ) async -> [Task<Void, Never>] {
        let (macSide, phoneSide) = await InMemoryFrameChannel.makePair()
        let initiator = BridgeInitiator(channel: macSide)
        let responder = BridgeResponder(
            channel: phoneSide,
            dialer: responderDialer ?? dialer
        )
        return [
            Task { do { try await responder.run() } catch {} },
            Task { do { try await initiator.run() } catch {} },
            Task {
                await pumpDatagramFlow(
                    flow,
                    via: initiator,
                    policy: policy,
                    dialer: dialer,
                    replyWindow: replyWindow,
                    log: Self.log
                )
            },
        ]
    }

    // SYMPTOM: on hardware, with TCP running at 98 Mbps, no hostname would
    // resolve. The phone's log showed a destination dialled and dead before any
    // answer arrived:
    //
    //     23:55:13.541  udp dial ok 1.1.1.1:53
    //     23:55:13.544  udp 1.1.1.1:53 ended after 0 replies     ← 3 ms later
    //
    // `readDatagrams` completes as soon as the client is done SENDING, which for
    // DNS is immediately after the single query. The pump treated that as the
    // end of the flow and closed the stream, so the answer was discarded before
    // it could land. One datagram out and one back loses that race every time.
    //
    // A client having nothing more to send does not mean it has nothing more to
    // receive.
    @Test("A reply that arrives after the client stops sending still gets through")
    func replyAfterClientStopsSendingIsDelivered() async throws {
        let queue = DispatchQueue(label: "regression.udp.pump.window")
        let server = SlowEchoServer()
        let port = try await server.start(on: queue, delay: 0.4)
        defer { Task { await server.stop() } }

        let endpoint = NWEndpoint.hostPort(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!
        )
        let payload = Data("late-answer".utf8)

        // Loopback is excluded from the bridge, so this takes the direct route
        // through LocalDatagramRelay — which the reply window bounds just as it
        // bounds the bridged one, and which had no test of its own either.
        let flow = FakeFlow(sending: [[(payload, endpoint)], nil])
        let dialer = CellularDialer(queue: queue, requiredInterface: nil)

        let tasks = await runPump(
            flow: flow,
            policy: CapturePolicy(),
            dialer: dialer,
            replyWindow: .seconds(3)
        )
        defer { tasks.forEach { $0.cancel() } }

        await flow.waitForWrite(timeout: .seconds(5))
        let received = await flow.receivedPayloads
        #expect(
            received.first == payload,
            "the answer was discarded because the flow closed when the client stopped sending"
        )
    }

    // The other half, and the one that makes the test above mean something: with
    // no window the same answer is lost. Without this, a passing test proves
    // only that a reply can arrive, not that the window is why.
    @Test("With no reply window the same answer is lost")
    func withoutWindowTheReplyIsLost() async throws {
        let queue = DispatchQueue(label: "regression.udp.pump.nowindow")
        let server = SlowEchoServer()
        let port = try await server.start(on: queue, delay: 0.4)
        defer { Task { await server.stop() } }

        let endpoint = NWEndpoint.hostPort(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!
        )
        let flow = FakeFlow(sending: [[(Data("late-answer".utf8), endpoint)], nil])
        let dialer = CellularDialer(queue: queue, requiredInterface: nil)

        let tasks = await runPump(
            flow: flow,
            policy: CapturePolicy(),
            dialer: dialer,
            replyWindow: .zero
        )
        defer { tasks.forEach { $0.cancel() } }

        await flow.waitForWrite(timeout: .seconds(2))
        let received = await flow.receivedPayloads
        #expect(received.isEmpty, "the flow outlived its window, so the window bounds nothing")
    }

    // Route 3. Refusing to bridge is not the same as being able to ignore: the
    // flow is ours, so the system will not deliver what we declined. Datagrams
    // the policy rejected were simply dropped, which is a black hole the sender
    // gets neither an answer nor an error from — and since DNS is the first
    // thing every connection does, the whole machine felt throttled.
    @Test("An excluded destination goes out directly and its reply comes back")
    func excludedDestinationTakesTheDirectRoute() async throws {
        let queue = DispatchQueue(label: "regression.udp.pump.direct")
        let server = SlowEchoServer()
        let port = try await server.start(on: queue, delay: 0.05)
        defer { Task { await server.stop() } }

        let endpoint = NWEndpoint.hostPort(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!
        )
        let payload = Data("direct-please".utf8)

        // Loopback: excluded by rule 2 of the capture policy, so if this comes
        // back at all it came back through LocalDatagramRelay.
        #expect(CapturePolicy().shouldCapture(remoteEndpoint: "127.0.0.1:\(port)") == false)

        let flow = FakeFlow(sending: [[(payload, endpoint)], nil])
        let dialer = CellularDialer(queue: queue, requiredInterface: nil)

        let tasks = await runPump(
            flow: flow,
            policy: CapturePolicy(),
            dialer: dialer,
            replyWindow: .seconds(3)
        )
        defer { tasks.forEach { $0.cancel() } }

        await flow.waitForWrite(timeout: .seconds(5))
        let received = await flow.receivedPayloads
        let endpoints = await flow.receivedEndpoints
        #expect(received.first == payload)
        // Re-addressed to the destination the client asked, not to whatever the
        // relay's socket happened to be bound to.
        #expect(endpoints.first.map { String(describing: $0) } == String(describing: endpoint))
    }
}

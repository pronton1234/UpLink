import Testing
import Foundation
@testable import UpLinkKit

// End-to-end proof that the protocol actually proxies traffic: a Mac-side
// initiator and a phone-side responder, wired together in one process, moving
// real bytes to a stand-in destination. Everything below the transport is the
// production code path — same multiplexer, same codec, same session actors.

/// Stands in for "the internet". Records what it was asked for and replies with
/// a canned response, so the test asserts on data that genuinely made a round
/// trip rather than on a mock's call log.
private actor FakeDestination: DestinationConnection {

    private var pendingResponse: [Data]
    private(set) var received = Data()
    private let egress: EgressInterface
    private var closed = false

    init(response: [Data], egress: EgressInterface) {
        self.pendingResponse = response
        self.egress = egress
    }

    func egressInterface() async -> EgressInterface { egress }

    func send(_ data: Data) async throws { received.append(data) }

    func receive() async throws -> Data? {
        guard !pendingResponse.isEmpty else {
            closed = true
            return nil
        }
        return pendingResponse.removeFirst()
    }

    func close() async { closed = true }

    func bytesReceived() async -> Data { received }
}

private actor FakeDialer: DestinationDialer {

    private let response: [Data]
    private let egress: EgressInterface
    private(set) var dialled: [StreamOpen] = []
    private(set) var lastConnection: FakeDestination?

    init(response: [Data], egress: EgressInterface = .cellular) {
        self.response = response
        self.egress = egress
    }

    func connect(to destination: StreamOpen) async throws -> DestinationConnection {
        dialled.append(destination)
        let connection = FakeDestination(response: response, egress: egress)
        lastConnection = connection
        return connection
    }

    func destinations() async -> [StreamOpen] { dialled }
    func connection() async -> FakeDestination? { lastConnection }
}

private actor UnreachableDialer: DestinationDialer {
    func connect(to destination: StreamOpen) async throws -> DestinationConnection {
        throw ChannelError.notConnected
    }
}

@Suite("Loopback bridge")
struct LoopbackBridgeTests {

    private let httpResponse = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi".utf8)

    /// Stands both ends up on an in-memory channel pair and returns them.
    private func makeBridge(
        dialer: DestinationDialer
    ) async -> (initiator: BridgeInitiator, tasks: [Task<Void, Never>]) {
        let (macSide, phoneSide) = await InMemoryFrameChannel.makePair()

        let initiator = BridgeInitiator(channel: macSide)
        let responder = BridgeResponder(channel: phoneSide, dialer: dialer)

        let tasks: [Task<Void, Never>] = [
            Task { do { try await responder.run() } catch {} },
            Task { do { try await initiator.run() } catch {} },
        ]
        return (initiator, tasks)
    }

    @Test("A request crosses the bridge and its response comes back intact")
    func requestAndResponseRoundTrip() async throws {
        let dialer = FakeDialer(response: [httpResponse])
        let (initiator, tasks) = await makeBridge(dialer: dialer)
        defer { tasks.forEach { $0.cancel() } }

        let stream = try await initiator.openStream(
            to: StreamOpen(proto: .tcp, host: "example.com", port: 443))
        try await stream.send(Data("GET / HTTP/1.1\r\n\r\n".utf8))

        var body = Data()
        while body.count < httpResponse.count, let chunk = await stream.receive() {
            body.append(chunk)
        }

        #expect(body == httpResponse)
    }

    @Test("The destination receives exactly the bytes the Mac sent")
    func requestBytesArriveVerbatim() async throws {
        let dialer = FakeDialer(response: [httpResponse])
        let (initiator, tasks) = await makeBridge(dialer: dialer)
        defer { tasks.forEach { $0.cancel() } }

        let request = Data("GET /some/path HTTP/1.1\r\nHost: example.com\r\n\r\n".utf8)
        let stream = try await initiator.openStream(
            to: StreamOpen(proto: .tcp, host: "example.com", port: 443))
        try await stream.send(request)

        _ = await stream.receive()

        let connection = await dialer.connection()
        #expect(await connection?.bytesReceived() == request)
    }

    @Test("The hostname is resolved on the phone, not the Mac")
    func hostnameIsDialledOnThePhone() async throws {
        let dialer = FakeDialer(response: [httpResponse])
        let (initiator, tasks) = await makeBridge(dialer: dialer)
        defer { tasks.forEach { $0.cancel() } }

        let stream = try await initiator.openStream(
            to: StreamOpen(proto: .tcp, host: "private.example.com", port: 443))
        _ = await stream.receive()

        // The phone must receive the *name*. If the Mac had resolved it, the
        // user's DNS would leak to whatever network the Mac is attached to,
        // which is exactly what the bridge exists to avoid.
        #expect(await dialer.destinations().first?.host == "private.example.com")
    }

    @Test("A payload larger than one frame is reassembled in order")
    func largePayloadIsReassembledInOrder() async throws {
        // Three full frames plus a remainder, so chunking and ordering both matter.
        let large = Data((0 ..< (Frame.maxPayloadSize * 3 + 1_234)).map { UInt8($0 % 251) })
        let dialer = FakeDialer(response: [large])
        let (initiator, tasks) = await makeBridge(dialer: dialer)
        defer { tasks.forEach { $0.cancel() } }

        let stream = try await initiator.openStream(
            to: StreamOpen(proto: .tcp, host: "example.com", port: 80))

        var body = Data()
        while body.count < large.count, let chunk = await stream.receive() {
            body.append(chunk)
        }

        #expect(body.count == large.count)
        #expect(body == large)
    }

    @Test("The Mac learns which interface the phone actually used")
    func egressInterfaceIsReported() async throws {
        let dialer = FakeDialer(response: [httpResponse], egress: .cellular)
        let (initiator, tasks) = await makeBridge(dialer: dialer)
        defer { tasks.forEach { $0.cancel() } }

        let stream = try await initiator.openStream(
            to: StreamOpen(proto: .tcp, host: "example.com", port: 443))
        _ = await stream.receive()

        #expect(await initiator.observedEgress == .cellular)
    }

    // The status header must never say "Cellular ✓" when the phone fell back to
    // its own Wi-Fi — that is the silent failure the whole reporting path
    // exists to make visible.
    @Test("A Wi-Fi fallback on the phone is reported as Wi-Fi, not cellular")
    func wifiFallbackIsReportedHonestly() async throws {
        let dialer = FakeDialer(response: [httpResponse], egress: .wifi)
        let (initiator, tasks) = await makeBridge(dialer: dialer)
        defer { tasks.forEach { $0.cancel() } }

        let stream = try await initiator.openStream(
            to: StreamOpen(proto: .tcp, host: "example.com", port: 443))
        _ = await stream.receive()

        let egress = await initiator.observedEgress
        #expect(egress == .wifi)
        #expect(egress?.isUnmeteredCellularEgress == false)
    }

    @Test("Several concurrent streams do not interleave each other's bytes")
    func concurrentStreamsStaySeparate() async throws {
        let dialer = FakeDialer(response: [Data(repeating: 0xAA, count: 4_096)])
        let (initiator, tasks) = await makeBridge(dialer: dialer)
        defer { tasks.forEach { $0.cancel() } }

        let streams = try await withThrowingTaskGroup(of: Data.self) { group -> [Data] in
            for index in 0 ..< 8 {
                group.addTask {
                    let stream = try await initiator.openStream(
                        to: StreamOpen(proto: .tcp, host: "host\(index).example", port: 80))
                    var body = Data()
                    while body.count < 4_096, let chunk = await stream.receive() {
                        body.append(chunk)
                    }
                    return body
                }
            }
            var results: [Data] = []
            for try await body in group { results.append(body) }
            return results
        }

        #expect(streams.count == 8)
        #expect(streams.allSatisfy { $0 == Data(repeating: 0xAA, count: 4_096) })
    }

    // One unreachable host must close one stream, not the session — otherwise a
    // single dead site drops every other tab the user has open.
    @Test("An unreachable destination closes only its own stream")
    func unreachableDestinationDoesNotKillTheSession() async throws {
        let (initiator, tasks) = await makeBridge(dialer: UnreachableDialer())
        defer { tasks.forEach { $0.cancel() } }

        let dead = try await initiator.openStream(
            to: StreamOpen(proto: .tcp, host: "unreachable.example", port: 443))
        #expect(await dead.receive() == nil)

        // The session is still usable afterwards.
        let another = try await initiator.openStream(
            to: StreamOpen(proto: .tcp, host: "other.example", port: 443))
        #expect(another.id != dead.id)
    }
}

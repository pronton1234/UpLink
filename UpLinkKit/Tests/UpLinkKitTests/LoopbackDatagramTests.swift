import Testing
import Foundation
@testable import UpLinkKit

// The UDP counterpart of LoopbackBridgeTests: a real initiator and responder
// wired together, moving datagrams through the production session actors. This
// is what proves QUIC and DNS can actually cross the bridge rather than merely
// being representable in the protocol.

/// A UDP destination that echoes back a tagged reply, so a test can tell which
/// host answered.
private actor EchoDestination: DestinationConnection {

    private let tag: UInt8
    private var received: [Data] = []
    private var pending: [Data] = []
    private var waiters: [CheckedContinuation<Data?, Never>] = []

    init(tag: UInt8) { self.tag = tag }

    func egressInterface() async -> EgressInterface { .cellular }

    func send(_ data: Data) async throws {
        received.append(data)
        // Reply is the request with this destination's tag appended, so a
        // misrouted datagram is visible rather than plausible.
        let reply = data + Data([tag])
        if waiters.isEmpty { pending.append(reply) }
        else { waiters.removeFirst().resume(returning: reply) }
    }

    func receive() async throws -> Data? {
        if !pending.isEmpty { return pending.removeFirst() }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func close() async {
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting { waiter.resume(returning: nil) }
    }

    func datagramsReceived() async -> [Data] { received }
}

private actor FanOutDialer: DestinationDialer {

    private(set) var dialled: [StreamOpen] = []
    private var byHost: [String: EchoDestination] = [:]
    private var nextTag: UInt8 = 1

    func connect(to destination: StreamOpen) async throws -> DestinationConnection {
        dialled.append(destination)
        let key = "\(destination.host):\(destination.port)"
        if let existing = byHost[key] { return existing }
        let created = EchoDestination(tag: nextTag)
        nextTag += 1
        byHost[key] = created
        return created
    }

    func destinations() async -> [StreamOpen] { dialled }
    func connection(for key: String) async -> EchoDestination? { byHost[key] }
}

@Suite("Loopback datagrams")
struct LoopbackDatagramTests {

    private func makeBridge(
        dialer: DestinationDialer
    ) async -> (BridgeInitiator, [Task<Void, Never>]) {
        let (macSide, phoneSide) = await InMemoryFrameChannel.makePair()
        let initiator = BridgeInitiator(channel: macSide)
        let responder = BridgeResponder(channel: phoneSide, dialer: dialer)
        let tasks: [Task<Void, Never>] = [
            Task { do { try await responder.run() } catch {} },
            Task { do { try await initiator.run() } catch {} },
        ]
        return (initiator, tasks)
    }

    private let session = StreamOpen(proto: .udp, host: "*", port: 0)

    @Test("A datagram crosses the bridge and its reply comes back")
    func datagramRoundTrip() async throws {
        let dialer = FanOutDialer()
        let (initiator, tasks) = await makeBridge(dialer: dialer)
        defer { tasks.forEach { $0.cancel() } }

        let stream = try await initiator.openStream(to: session)
        try await stream.sendDatagram(Data("query".utf8), to: "1.1.1.1", port: 53)

        let reply = await stream.receiveDatagram()
        #expect(reply?.host == "1.1.1.1")
        #expect(reply?.payload.prefix(5) == Data("query".utf8))
    }

    // The whole reason the destination travels per datagram. One session, three
    // hosts: every reply must come back tagged by the host that actually
    // answered, or datagrams are crossing between destinations.
    @Test("One session fans out to several destinations without crossing them")
    func fanOutDoesNotCrossDestinations() async throws {
        let dialer = FanOutDialer()
        let (initiator, tasks) = await makeBridge(dialer: dialer)
        defer { tasks.forEach { $0.cancel() } }

        let stream = try await initiator.openStream(to: session)
        let hosts = ["1.1.1.1", "8.8.8.8", "9.9.9.9"]

        for host in hosts {
            try await stream.sendDatagram(Data(host.utf8), to: host, port: 53)
        }

        var seen: [String: Data] = [:]
        while seen.count < hosts.count {
            guard let reply = await stream.receiveDatagram() else { break }
            seen[reply.host] = reply.payload
        }

        #expect(Set(seen.keys) == Set(hosts))
        // Each reply must echo the request that was sent to THAT host.
        for host in hosts {
            #expect(seen[host]?.prefix(host.utf8.count) == Data(host.utf8))
        }
    }

    @Test("The phone dials each UDP destination itself, by name")
    func destinationsAreDialledOnThePhone() async throws {
        let dialer = FanOutDialer()
        let (initiator, tasks) = await makeBridge(dialer: dialer)
        defer { tasks.forEach { $0.cancel() } }

        let stream = try await initiator.openStream(to: session)
        try await stream.sendDatagram(Data([0x01]), to: "dns.google", port: 53)
        _ = await stream.receiveDatagram()

        let dialled = await dialer.destinations()
        // The name, unresolved, and marked UDP — so the phone resolves it over
        // cellular rather than the Mac leaking the lookup.
        #expect(dialled.contains { $0.host == "dns.google" && $0.proto == .udp })
    }

    @Test("Datagram payloads arrive at the destination byte-exact")
    func payloadsArriveExact() async throws {
        let dialer = FanOutDialer()
        let (initiator, tasks) = await makeBridge(dialer: dialer)
        defer { tasks.forEach { $0.cancel() } }

        let stream = try await initiator.openStream(to: session)
        // A realistic QUIC-sized packet, not a toy payload.
        let packet = Data((0 ..< 1_350).map { UInt8($0 % 251) })
        try await stream.sendDatagram(packet, to: "1.1.1.1", port: 443)
        _ = await stream.receiveDatagram()

        let connection = await dialer.connection(for: "1.1.1.1:443")
        #expect(await connection?.datagramsReceived() == [packet])
    }

    @Test("Datagram boundaries are preserved across many sends")
    func boundariesPreservedAcrossManySends() async throws {
        let dialer = FanOutDialer()
        let (initiator, tasks) = await makeBridge(dialer: dialer)
        defer { tasks.forEach { $0.cancel() } }

        let stream = try await initiator.openStream(to: session)
        let sizes = [1, 2, 7, 64, 512, 1_400]

        for size in sizes {
            try await stream.sendDatagram(Data(repeating: UInt8(size % 256), count: size),
                                          to: "1.1.1.1", port: 53)
        }

        var received = 0
        while received < sizes.count, await stream.receiveDatagram() != nil {
            received += 1
        }

        // Exactly as many datagrams out as in — never coalesced, never split.
        let delivered = await dialer.connection(for: "1.1.1.1:53")?.datagramsReceived() ?? []
        #expect(delivered.map(\.count) == sizes)
    }
}

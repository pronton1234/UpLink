import Foundation

/// A bidirectional byte pipe to the peer device.
///
/// The session layer is written against this rather than against `NWConnection`
/// directly, for two reasons. It lets the loopback integration test drive the
/// full protocol without a network, and it keeps the AWDL-versus-IP transport
/// decision (see Phase 0) from leaking into every layer above it: whichever
/// transport wins, it only has to supply one of these.
public protocol FrameChannel: Sendable {
    /// Sends raw bytes to the peer.
    func send(_ data: Data) async throws
    /// Next bytes from the peer, or `nil` once the peer has closed.
    func receive() async throws -> Data?
    func close() async
}

/// A destination the phone dials on the Mac's behalf.
public protocol DestinationConnection: Sendable {
    /// The interface this connection actually egressed on.
    ///
    /// Observed after the connection is ready, not assumed from what was
    /// requested — the difference between the two is exactly the silent
    /// Wi-Fi fallback the user needs to be told about.
    func egressInterface() async -> EgressInterface
    func send(_ data: Data) async throws
    func receive() async throws -> Data?
    func close() async
}

/// Opens connections to arbitrary destinations. Injected so the loopback test
/// can point "the internet" at a local server.
public protocol DestinationDialer: Sendable {
    func connect(to destination: StreamOpen) async throws -> DestinationConnection
}

/// An in-memory `FrameChannel` pair, used to run both ends of the protocol in
/// one process.
///
/// Ships in the library rather than the test target because both test targets
/// use it — `UpLinkKitTests` for the loopback bridge and `UpLinkRegressionTests`
/// for the datagram and concurrency suites — and a type shared across targets
/// has to live somewhere both can see.
public actor InMemoryFrameChannel: FrameChannel {

    private var inbox: [Data] = []
    private var waiters: [CheckedContinuation<Data?, Never>] = []
    private var closed = false
    private var peer: InMemoryFrameChannel?

    public init() {}

    /// Wires two channels together so a send on one is a receive on the other.
    ///
    /// Async because both sides must be attached before either can be used —
    /// doing it in a detached task would let a send race ahead of the wiring.
    public static func makePair() async -> (InMemoryFrameChannel, InMemoryFrameChannel) {
        let a = InMemoryFrameChannel()
        let b = InMemoryFrameChannel()
        await a.attach(peer: b)
        await b.attach(peer: a)
        return (a, b)
    }

    func attach(peer: InMemoryFrameChannel) { self.peer = peer }

    public func send(_ data: Data) async throws {
        guard let peer else { throw ChannelError.notConnected }
        await peer.deliver(data)
    }

    func deliver(_ data: Data) {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: data)
        } else {
            inbox.append(data)
        }
    }

    public func receive() async throws -> Data? {
        if !inbox.isEmpty { return inbox.removeFirst() }
        if closed { return nil }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    public func close() async {
        // Idempotent, and checked before touching the peer: closing propagates
        // to the other end, which would otherwise close us straight back and
        // recurse forever.
        guard !closed else { return }
        closed = true

        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: nil) }

        await peer?.close()
    }
}

public enum ChannelError: Error, Equatable, Sendable {
    case notConnected
    case peerClosed
    /// The peer answered and REJECTED us. Over the cable this means one thing
    /// in practice: it holds no key for the identity we offered, i.e. the
    /// pairing is gone from its side.
    ///
    /// Distinct from ``connectionRefused`` because the two need opposite
    /// responses, and conflating them is what made a broken pairing look like
    /// an ordinary retry: nothing on the phone → keep trying, it will come up;
    /// something on the phone that refuses us → stop, and tell the user to pair
    /// again, because no amount of retrying will fix it.
    case handshakeFailed(String)
    /// Nothing is listening on that port. The ordinary "UpLink is not running
    /// on the phone yet" case, and worth retrying indefinitely.
    case connectionRefused
    case versionMismatch(UInt16)
}

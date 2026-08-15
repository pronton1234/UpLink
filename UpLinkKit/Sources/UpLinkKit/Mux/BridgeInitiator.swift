import Foundation

/// One proxied flow, from the Mac's point of view.
///
/// The macOS transparent-proxy extension holds one of these per
/// `NEAppProxyTCPFlow` and shuttles bytes between the flow and this object.
public actor ProxiedStream {

    /// Immutable and safe to read from any isolation domain — the proxy
    /// extension needs the ID for logging without hopping onto the actor.
    public nonisolated let id: UInt32

    private var inbox: [Data] = []
    private var waiters: [CheckedContinuation<Data?, Never>] = []
    private var datagramInbox: [DatagramEnvelope] = []
    private var datagramWaiters: [CheckedContinuation<DatagramEnvelope?, Never>] = []
    private var finished = false
    private weak var owner: BridgeInitiator?

    init(id: UInt32, owner: BridgeInitiator) {
        self.id = id
        self.owner = owner
    }

    /// Bytes coming back from the destination, or `nil` once the stream ends.
    public func receive() async -> Data? {
        if !inbox.isEmpty { return inbox.removeFirst() }
        if finished { return nil }
        return await withCheckedContinuation { waiters.append($0) }
    }

    public func send(_ data: Data) async throws {
        guard let owner else { throw ChannelError.notConnected }
        try await owner.send(data, on: id)
    }

    /// Sends one UDP datagram. Returns false if it was dropped, which is a
    /// normal outcome rather than an error.
    @discardableResult
    public func sendDatagram(_ payload: Data, to host: String, port: UInt16) async throws -> Bool {
        guard let owner else { throw ChannelError.notConnected }
        return try await owner.sendDatagram(payload, to: host, port: port, on: id)
    }

    /// Datagrams coming back, each with the destination that produced it.
    public func receiveDatagram() async -> DatagramEnvelope? {
        if !datagramInbox.isEmpty { return datagramInbox.removeFirst() }
        if finished { return nil }
        return await withCheckedContinuation { datagramWaiters.append($0) }
    }

    func deliverDatagram(_ envelope: DatagramEnvelope) {
        if datagramWaiters.isEmpty { datagramInbox.append(envelope) }
        else { datagramWaiters.removeFirst().resume(returning: envelope) }
    }

    public func close() async {
        await owner?.closeStream(id)
        finish()
    }

    func deliver(_ data: Data) {
        if waiters.isEmpty {
            inbox.append(data)
        } else {
            waiters.removeFirst().resume(returning: data)
        }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: nil) }

        let pendingDatagrams = datagramWaiters
        datagramWaiters.removeAll()
        for waiter in pendingDatagrams { waiter.resume(returning: nil) }
    }
}

/// The Mac's side of the bridge.
///
/// Owns the multiplexer, hands out ``ProxiedStream`` objects for each captured
/// flow, and tracks what the phone reports about how traffic is actually
/// leaving — which is what the menu bar displays.
public actor BridgeInitiator {

    private let channel: FrameChannel
    private var mux = Multiplexer(role: .initiator)
    private var decoder = FrameDecoder()
    private var streams: [UInt32: ProxiedStream] = [:]

    /// How many stream slots are currently held.
    ///
    /// Exposed because a leak here is invisible until the session is already
    /// unusable: slots are never reclaimed, so the symptom appears minutes
    /// after the cause and looks like a network fault rather than a leak.
    public var openStreamCount: Int { streams.count }

    /// Last interface the phone reported using. `nil` until the first stream
    /// egresses, because claiming anything before then would be a guess.
    public private(set) var observedEgress: EgressInterface?

    /// Fingerprint the phone announced in its `HELLO`.
    public private(set) var peerFingerprint: String?

    private var egressObservers: [UUID: @Sendable (EgressInterface) -> Void] = [:]
    /// Told when the peer says it has forgotten this pairing, so the owner can
    /// drop its own half rather than keep a device the other end has removed.
    private var unpairObservers: [UUID: @Sendable () -> Void] = [:]

    /// Tasks blocked waiting for the phone to grant more window credit.
    ///
    /// Replaces a `Task.yield()` retry loop. Yielding reads like waiting but is
    /// a spin: every starved stream re-entered this actor immediately and
    /// repeatedly, competing with the frame loop that had to process the very
    /// WINDOW frame that would unblock them.
    private var creditWaiters: [UInt32: [CheckedContinuation<Void, Never>]] = [:]

    public init(channel: FrameChannel) {
        self.channel = channel
    }

    public func onEgressChange(_ handler: @escaping @Sendable (EgressInterface) -> Void) -> UUID {
        let token = UUID()
        egressObservers[token] = handler
        return token
    }

    public func onUnpairedByPeer(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let token = UUID()
        unpairObservers[token] = handler
        return token
    }

    public func removeEgressObserver(_ token: UUID) {
        egressObservers.removeValue(forKey: token)
    }

    /// Pumps frames until the peer disconnects.
    public func run() async throws {
        try await pump()
    }

    /// Resumes after the caller has already read the opening `HELLO` in order
    /// to tell a session connection from a pairing one.
    ///
    /// The partially-consumed decoder is handed over rather than recreated:
    /// the phone may well have pipelined its first `OPEN` into the same TCP
    /// segment as the `HELLO`, and a fresh decoder would drop it.
    public func run(resuming hello: Frame, decoder: FrameDecoder) async throws {
        self.decoder = decoder
        try await handle(hello)
        while let frame = try self.decoder.next() {
            try await handle(frame)
        }
        try await pump()
    }

    private func pump() async throws {
        while let bytes = try await channel.receive() {
            decoder.append(bytes)
            while let frame = try decoder.next() {
                try await handle(frame)
            }
        }

        // Every suspended sender is released before the streams go, so no task
        // is left waiting on credit that can never arrive.
        for (streamID, _) in creditWaiters { creditArrived(on: streamID) }
        creditWaiters.removeAll()
        for (_, stream) in streams { await stream.finish() }
        streams.removeAll()
    }

    public func openStream(to destination: StreamOpen) async throws -> ProxiedStream {
        // The mux allocates the ID here, before the OPEN has been written. Every
        // path out of this function after that point must therefore either
        // return the stream or give the slot back — there are only
        // `maxConcurrentStreams` of them, and a slot nobody owns is never
        // reclaimed for the lifetime of the session.
        //
        // SYMPTOM when it was not: one misbehaving app (`com.relay.mac`,
        // reconnect-storming after the Mac lost Wi-Fi) produced 55,536 claims
        // in a couple of minutes. 50,712 of them failed with
        // `streamLimitReached` — and the failures did not stop when the storm
        // did. Every other app on the machine was starved: 13 flows opened in
        // the window, so pages half-loaded rather than failing outright, which
        // is a far more confusing symptom than being offline.
        let opened = try mux.openStream(to: destination)
        let stream = ProxiedStream(id: opened.streamID, owner: self)
        streams[opened.streamID] = stream

        do {
            try await write(opened.frame)
        } catch {
            // The write is bounded (`NWConnectionChannel.sendTimeout`), so under
            // congestion this throws routinely rather than exceptionally.
            release(opened.streamID)
            throw error
        }

        // The caller's deadline may have expired while the OPEN was in flight.
        // `withFlowDeadline` abandons the operation rather than unwinding it, so
        // without this the stream is opened, credited, and owned by nobody —
        // the dominant leak under load, because congestion is exactly when the
        // write takes longer than the deadline.
        guard !Task.isCancelled else {
            release(opened.streamID)
            throw CancellationError()
        }

        return stream
    }

    /// Gives a stream slot back without requiring the peer to answer.
    ///
    /// Local bookkeeping first and unconditionally; telling the peer is
    /// best-effort. If the channel is the reason we are here, waiting on it to
    /// carry the CLOSE is how one failure becomes a permanent leak.
    private func release(_ streamID: UInt32) {
        creditArrived(on: streamID)
        streams.removeValue(forKey: streamID)
        guard let frame = try? mux.closeStream(streamID) else { return }
        Task { [weak self] in try? await self?.write(frame) }
    }

    func send(_ data: Data, on streamID: UInt32) async throws {
        var remaining = data
        while !remaining.isEmpty {
            let result = try mux.send(remaining, on: streamID)
            guard result.accepted > 0 else {
                // No credit: the destination is slower than the Mac is
                // writing. Suspend until a WINDOW frame actually arrives, so
                // backpressure reaches the app producing the data without this
                // task competing with the frame loop that has to deliver it.
                await waitForCredit(on: streamID)
                guard !Task.isCancelled else { return }
                continue
            }
            for frame in result.frames { try await write(frame) }
            remaining = remaining.dropFirst(result.accepted)
        }
    }

    func sendDatagram(_ payload: Data, to host: String, port: UInt16, on streamID: UInt32) async throws -> Bool {
        let result = try mux.sendDatagram(payload, to: host, port: port, on: streamID)
        if let frame = result.frame { try await write(frame) }
        return !result.dropped
    }

    func closeStream(_ streamID: UInt32) async {
        creditArrived(on: streamID)
        guard let frame = try? mux.closeStream(streamID) else { return }
        streams.removeValue(forKey: streamID)
        try? await write(frame)
    }

    private func waitForCredit(on streamID: UInt32) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            creditWaiters[streamID, default: []].append(continuation)
        }
    }

    private func creditArrived(on streamID: UInt32) {
        guard let waiters = creditWaiters.removeValue(forKey: streamID) else { return }
        for waiter in waiters { waiter.resume() }
    }

    /// Tells the peer this pairing is gone, best effort.
    ///
    /// Mac → phone: this Mac has forgotten the phone. Failure is ignored on purpose: this is
    /// called while tearing the session down, and a peer that cannot be told
    /// is a peer that is already gone. The point is to give the common case —
    /// both devices up, user taps Remove — an answer better than a silently
    /// refused handshake.
    public func announceUnpaired() async {
        try? await write(Multiplexer.unpairedFrame())
    }

    private func handle(_ frame: Frame) async throws {
        for event in try mux.receive(frame) {
            switch event {
            case let .dataReceived(streamID, payload):
                if let stream = streams[streamID] {
                    await stream.deliver(payload)
                    if let update = try? mux.consumedReceivedBytes(payload.count, on: streamID) {
                        try await write(update)
                    }
                }

            case let .datagramReceived(streamID, envelope):
                if let stream = streams[streamID] {
                    await stream.deliverDatagram(envelope)
                    if let update = try? mux.consumedReceivedBytes(envelope.encoded().count, on: streamID) {
                        try await write(update)
                    }
                }

            case let .streamClosed(streamID):
                // Waiters first: a send suspended on credit for a stream that
                // is going away would otherwise never resume.
                creditArrived(on: streamID)
                await streams.removeValue(forKey: streamID)?.finish()

            case let .egressReported(interface):
                observedEgress = interface
                for (_, observer) in egressObservers { observer(interface) }

            case .unpairedByPeer:
                // The phone has removed this Mac. Announce it and let the
                // session end: continuing would mean bridging for a device the
                // user just revoked, which is exactly what made the Mac keep
                // showing a phone that was trying to pair afresh.
                for (_, observer) in unpairObservers { observer() }

            case .pingReceived:
                try await write(Frame(kind: .pong, streamID: Multiplexer.controlStreamID))

            case let .helloReceived(version, identity):
                guard version == Multiplexer.protocolVersion else {
                    throw ChannelError.versionMismatch(version)
                }
                peerFingerprint = identity
                try await write(mux.makeHelloAck())

            case let .creditGranted(streamID):
                creditArrived(on: streamID)

            case .pongReceived, .openRequested, .helloAcknowledged:
                break
            }
        }
    }

    private func write(_ frame: Frame) async throws {
        try await channel.send(FrameEncoder.encode(frame))
    }
}

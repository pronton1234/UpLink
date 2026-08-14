import Foundation
import OSLog

/// The phone's side of the bridge.
///
/// Reads frames from the Mac, dials the requested destinations over cellular,
/// and pumps bytes in both directions. This is where the product's whole claim
/// is cashed: the destination connection is opened *here*, by an ordinary app
/// socket on the phone, which is why the carrier sees app traffic rather than
/// tethered traffic.
///
/// **Nothing slow may happen on the frame loop.** `run()` is a single
/// sequential task: until `handle(_:)` returns, the next frame is not decoded,
/// so *every* stream stalls. Dialling a destination costs a DNS lookup plus a
/// TCP handshake — 60–230 ms on cellular — and a write to a congested socket
/// can block for far longer. Both used to be awaited inline, which meant one
/// connection being established froze the whole link; a page opening thirty
/// connections serialised into seconds of dead air and made the bridge feel
/// exactly like the throttled hotspot it exists to replace. Both now go through
/// ``OutboundPipe``, so the frame loop only ever enqueues.
///
/// **Memory boundaries.** A payload arrives as a `Data` slice from the decoder,
/// is handed to a socket write, and is released. There is no spooling to disk,
/// no cache, and no copy retained after the write completes — a proxied byte
/// exists only in the buffer it arrived in. The queues in front of each
/// destination are bounded by flow control rather than by a size limit: credit
/// is only returned once bytes are genuinely on their way out, so the Mac can
/// never have more than one window (``Multiplexer/initialWindow``) in flight
/// per stream.
public actor BridgeResponder {

    /// How often the phone pings the Mac while a session is up.
    ///
    /// Two jobs. It proves the link is alive on a network where a dead peer
    /// otherwise looks identical to an idle one, and it gives the iOS Network
    /// Extension periodic socket activity so the system does not treat a quiet
    /// bridge as an abandoned one. It also re-samples the egress interface,
    /// which is the only way a mid-session change (cellular lost, or satisfied
    /// over Wi-Fi after a handover) is ever noticed on an idle link.
    public static let heartbeatInterval: Duration = .seconds(15)

    /// One destination being written to, with a queue in front of it.
    ///
    /// The queue is what keeps the dial and the socket write off the frame
    /// loop. `AsyncStream` is FIFO, so bytes reach the destination in the order
    /// the Mac sent them — a stream's ordering guarantee is preserved even
    /// though it is no longer written synchronously.
    private struct OutboundPipe {
        let feed: AsyncStream<OutboundPayload>.Continuation
        let task: Task<Void, Never>

        func shutDown() {
            feed.finish()
            task.cancel()
        }
    }

    /// A queued write plus what it costs against the peer's window.
    ///
    /// For TCP the two are the same; for UDP the credit covers the encoded
    /// envelope (header included) while only the payload goes to the socket.
    private struct OutboundPayload: Sendable {
        let bytes: Data
        let creditCost: Int
    }

    private let channel: FrameChannel
    private let dialer: DestinationDialer
    private var mux = Multiplexer(role: .responder)
    private var decoder = FrameDecoder()

    private var connections: [UInt32: DestinationConnection] = [:]
    /// UDP sessions: one connection per distinct destination on a stream.
    ///
    /// A single `NEAppProxyUDPFlow` fans out to many hosts, so a UDP stream is a
    /// *session* rather than a connection. Reusing a connection per destination
    /// keeps source-port behaviour stable, which some protocols (and most NATs)
    /// depend on.
    private var datagramConnections: [UInt32: [String: DestinationConnection]] = [:]
    private var pumps: [UInt32: Task<Void, Never>] = [:]

    private var tcpPipes: [UInt32: OutboundPipe] = [:]
    private var datagramPipes: [UInt32: [String: OutboundPipe]] = [:]

    /// Tasks blocked waiting for the Mac to grant more window credit.
    ///
    /// Replaces a `Task.yield()` retry loop. Yielding looked like waiting but
    /// was a spin: every starved stream re-entered this actor immediately and
    /// repeatedly, starving the frame loop that had to process the very WINDOW
    /// frame that would unblock them. Under an iOS extension's CPU budget that
    /// turned an instant credit refill into a stall.
    private var creditWaiters: [UInt32: [CheckedContinuation<Void, Never>]] = [:]

    /// Reported once per session, the first time we observe a real egress path.
    private var reportedEgress: EgressInterface?

    private let localFingerprint: String

    public init(channel: FrameChannel, dialer: DestinationDialer, localFingerprint: String = "") {
        self.channel = channel
        self.dialer = dialer
        self.localFingerprint = localFingerprint
    }

    /// What the phone last observed about how traffic is actually leaving.
    ///
    /// Exposed so the tunnel extension can answer the containing app's status
    /// request. The app cannot observe this itself — the sockets live in the
    /// extension — and without it the phone's UI has nothing to show but a
    /// placeholder.
    public var observedEgress: EgressInterface? { reportedEgress }

    /// Runs until the peer disconnects or the protocol is violated.
    ///
    /// The phone dials, so it speaks first: the opening `HELLO` both negotiates
    /// the version and tells the Mac which paired device this is.
    public func run() async throws {
        defer { Task { await self.teardown() } }

        try await write(mux.makeHello(identity: localFingerprint))

        let heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeatInterval)
                guard !Task.isCancelled, let self else { return }
                await self.beat()
            }
        }
        defer { heartbeat.cancel() }

        while let bytes = try await channel.receive() {
            decoder.append(bytes)
            while let frame = try decoder.next() {
                try await handle(frame)
            }
        }
    }

    /// One heartbeat: prove the link is alive, and re-check the egress.
    private func beat() async {
        try? await write(Frame(kind: .ping, streamID: Multiplexer.controlStreamID))

        // Re-sampling on a live connection is what catches a change on an idle
        // link. Without it the egress is only ever observed at dial time, so a
        // session that stops opening new connections keeps reporting whatever
        // was true when it started — and that value is the user's only signal
        // that they are still bypassing.
        guard let connection = connections.values.first ?? datagramConnections.values.first?.values.first
        else { return }
        await reportEgressIfChanged(for: connection)
    }

    private func handle(_ frame: Frame) async throws {
        for event in try mux.receive(frame) {
            switch event {
            case let .openRequested(streamID, destination):
                // A UDP OPEN registers a *session*, it does not name a
                // destination. `NEAppProxyUDPFlow` carries datagrams to many
                // hosts, so the OPEN carries the placeholder `*:0` and every
                // datagram addresses itself; destinations are dialled lazily in
                // `forwardDatagram`.
                //
                // Dialling the placeholder is not merely wasted work. It cannot
                // succeed, so `serviceDestination` calls `failStream`, which
                // writes a CLOSE and takes down the stream the flow was just
                // given. Every UDP flow then raced that CLOSE — win and the
                // datagrams got through, lose and the stream was gone before
                // the first reply came back.
                guard destination.proto == .tcp else { break }

                // Returns immediately: the dial happens in the pipe's task.
                openDestination(streamID: streamID, destination: destination)

            case let .dataReceived(streamID, payload):
                forwardToDestination(streamID: streamID, payload: payload)

            case let .datagramReceived(streamID, envelope):
                forwardDatagram(streamID: streamID, envelope: envelope)

            case let .streamClosed(streamID):
                await closeStream(streamID)

            case let .creditGranted(streamID):
                creditArrived(on: streamID)

            case .pingReceived:
                try await write(Frame(kind: .pong, streamID: Multiplexer.controlStreamID))

            case let .helloAcknowledged(version):
                guard version == Multiplexer.protocolVersion else {
                    throw ChannelError.versionMismatch(version)
                }

            case .pongReceived, .egressReported, .helloReceived:
                break
            }
        }
    }

    // MARK: - TCP

    /// Registers a stream and starts dialling it, without waiting.
    private func openDestination(streamID: UInt32, destination: StreamOpen) {
        let (inbox, feed) = AsyncStream<OutboundPayload>.makeStream(bufferingPolicy: .unbounded)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.serviceDestination(streamID: streamID, destination: destination, inbox: inbox)
        }
        tcpPipes[streamID] = OutboundPipe(feed: feed, task: task)
    }

    /// Dials, then drains that stream's queue for as long as it lives.
    private func serviceDestination(
        streamID: UInt32,
        destination: StreamOpen,
        inbox: AsyncStream<OutboundPayload>
    ) async {
        let connection: DestinationConnection
        do {
            connection = try await dialer.connect(to: destination)
        } catch {
            // A destination we cannot reach closes that one stream. It must not
            // take down the session — one unreachable host would otherwise drop
            // every other tab the user has open.
            await failStream(streamID)
            return
        }

        guard !Task.isCancelled else {
            await connection.close()
            return
        }

        connections[streamID] = connection
        await reportEgressIfChanged(for: connection)

        pumps[streamID] = Task { [weak self] in
            guard let self else { return }
            await self.pumpFromDestination(streamID: streamID, connection: connection)
        }

        for await payload in inbox {
            do {
                try await connection.send(payload.bytes)
            } catch {
                await failStream(streamID)
                return
            }
            // Only now, once the bytes are genuinely on their way out, do we
            // return window credit. Crediting on receipt instead would let the
            // Mac outrun a slow destination and queue unbounded data here.
            await returnCredit(payload.creditCost, on: streamID)
        }
    }

    private func forwardToDestination(streamID: UInt32, payload: Data) {
        guard let pipe = tcpPipes[streamID] else { return }
        pipe.feed.yield(OutboundPayload(bytes: payload, creditCost: payload.count))
    }

    // MARK: - UDP

    /// Queues one datagram, opening a connection for that destination the first
    /// time it is seen on this session.
    private func forwardDatagram(streamID: UInt32, envelope: DatagramEnvelope) {
        let key = "\(envelope.host):\(envelope.port)"
        let cost = envelope.encoded().count

        if let pipe = datagramPipes[streamID]?[key] {
            pipe.feed.yield(OutboundPayload(bytes: envelope.payload, creditCost: cost))
            return
        }

        let (inbox, feed) = AsyncStream<OutboundPayload>.makeStream(bufferingPolicy: .unbounded)
        let host = envelope.host
        let port = envelope.port
        let task = Task { [weak self] in
            guard let self else { return }
            await self.serviceDatagramDestination(
                streamID: streamID, host: host, port: port, key: key, inbox: inbox
            )
        }
        datagramPipes[streamID, default: [:]][key] = OutboundPipe(feed: feed, task: task)
        feed.yield(OutboundPayload(bytes: envelope.payload, creditCost: cost))
    }

    private func serviceDatagramDestination(
        streamID: UInt32,
        host: String,
        port: UInt16,
        key: String,
        inbox: AsyncStream<OutboundPayload>
    ) async {
        let destination = StreamOpen(proto: .udp, host: host, port: port)
        let log = Logger(subsystem: UpLinkIdentifiers.logSubsystem, category: "datagram")
        guard let connection = try? await dialer.connect(to: destination) else {
            // A destination we cannot reach drops its datagrams and nothing
            // else. UDP has no delivery promise, and one bad host must not
            // disturb the rest of the session.
            //
            // Logged at error level because a *silent* dial failure here is
            // indistinguishable from a working bridge that simply resolves
            // nothing: DNS is UDP, so losing this path takes down every
            // hostname while raw-IP traffic keeps flowing at full speed.
            log.error("udp dial FAILED \(key, privacy: .public)")
            datagramPipes[streamID]?.removeValue(forKey: key)
            return
        }
        log.error("udp dial ok \(key, privacy: .public)")

        guard !Task.isCancelled else {
            await connection.close()
            return
        }

        datagramConnections[streamID, default: [:]][key] = connection
        await reportEgressIfChanged(for: connection)

        let replies = Task { [weak self] in
            guard let self else { return }
            await self.pumpDatagrams(streamID: streamID, from: connection, host: host, port: port)
        }
        defer { replies.cancel() }

        var sent = 0
        for await payload in inbox {
            do {
                try await connection.send(payload.bytes)
            } catch {
                // Breaking here tears down the reply pump via the `defer`
                // above, so a failed send does not merely lose one datagram —
                // it kills the destination before any answer can arrive.
                log.error("udp send FAILED \(key, privacy: .public) after \(sent) sent: \(String(describing: error), privacy: .public)")
                break
            }
            sent += 1
            await returnCredit(payload.creditCost, on: streamID)
        }
        log.error("udp inbox ended \(key, privacy: .public) after \(sent) sent")
    }

    /// Replies from one UDP destination, framed back as datagrams.
    private func pumpDatagrams(
        streamID: UInt32,
        from connection: DestinationConnection,
        host: String,
        port: UInt16
    ) async {
        let log = Logger(subsystem: UpLinkIdentifiers.logSubsystem, category: "datagram")
        var replies = 0
        while true {
            guard let bytes = try? await connection.receive(), !bytes.isEmpty else {
                log.error("udp \(host, privacy: .public):\(port) ended after \(replies) replies")
                break
            }
            replies += 1
            // Only the FIRST reply at error level. That one line is the whole
            // difference between a working UDP path and a dead one — it is what
            // "udp dial ok" was missing on 2026-08-13 — and it costs one entry
            // per destination. Every reply after it is per-packet on the
            // phone's hot path, and a burst of those evicts the session
            // diagnostics from the log ring buffer, which is precisely when
            // they are needed. The running total is still reported once, by
            // "ended after N replies".
            if replies == 1 {
                log.error("udp reply 1 from \(host, privacy: .public):\(port) \(bytes.count) bytes")
            } else {
                log.debug("udp reply \(replies) from \(host, privacy: .public):\(port) \(bytes.count) bytes")
            }
            guard let result = try? mux.sendDatagram(bytes, to: host, port: port, on: streamID) else {
                log.error("udp reply NOT FRAMED for \(host, privacy: .public):\(port)")
                break
            }
            if let frame = result.frame {
                guard (try? await write(frame)) != nil else { break }
            }
            // result.dropped is deliberately not an error: an oversized or
            // uncredited datagram is dropped exactly as the network would.
        }
    }

    // MARK: - Return path and credit

    private func pumpFromDestination(streamID: UInt32, connection: DestinationConnection) async {
        while true {
            guard let bytes = try? await connection.receive(), !bytes.isEmpty else { break }

            var remaining = bytes
            while !remaining.isEmpty {
                guard let result = try? mux.send(remaining, on: streamID) else { return }
                guard result.accepted > 0 else {
                    // Out of credit: the Mac is draining slower than the
                    // destination is delivering. Suspend until a WINDOW frame
                    // actually arrives rather than retrying in a loop.
                    await waitForCredit(on: streamID)
                    guard !Task.isCancelled else { return }
                    continue
                }
                for frame in result.frames {
                    guard (try? await write(frame)) != nil else { return }
                }
                remaining = remaining.dropFirst(result.accepted)
            }
        }

        try? await write(Frame(kind: .close, streamID: streamID))
        await closeStream(streamID)
    }

    private func returnCredit(_ count: Int, on streamID: UInt32) async {
        guard let update = try? mux.consumedReceivedBytes(count, on: streamID) else { return }
        try? await write(update)
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

    // MARK: - Egress

    private func reportEgressIfChanged(for connection: DestinationConnection) async {
        let egress = await connection.egressInterface()
        guard reportedEgress != egress else { return }
        reportedEgress = egress
        try? await write(mux.makeEgressReport(egress))
    }

    // MARK: - Teardown

    /// Closes a stream that failed after it was already registered.
    private func failStream(_ streamID: UInt32) async {
        try? await write(Frame(kind: .close, streamID: streamID))
        _ = try? mux.receive(Frame(kind: .close, streamID: streamID))
        await closeStream(streamID)
    }

    private func closeStream(_ streamID: UInt32) async {
        // Waiters go first and unconditionally: a pump suspended on credit for
        // a stream that is being torn down would otherwise never resume, and
        // the task would leak for the lifetime of the session.
        creditArrived(on: streamID)

        tcpPipes.removeValue(forKey: streamID)?.shutDown()
        for (_, pipe) in datagramPipes.removeValue(forKey: streamID) ?? [:] { pipe.shutDown() }

        pumps.removeValue(forKey: streamID)?.cancel()
        if let connection = connections.removeValue(forKey: streamID) {
            await connection.close()
        }
        // A UDP session may hold many connections; all of them go.
        for (_, connection) in datagramConnections.removeValue(forKey: streamID) ?? [:] {
            await connection.close()
        }
    }

    private func write(_ frame: Frame) async throws {
        try await channel.send(FrameEncoder.encode(frame))
    }

    private func teardown() async {
        for (streamID, _) in creditWaiters { creditArrived(on: streamID) }
        creditWaiters.removeAll()

        for (_, pipe) in tcpPipes { pipe.shutDown() }
        tcpPipes.removeAll()
        for (_, perDestination) in datagramPipes {
            for (_, pipe) in perDestination { pipe.shutDown() }
        }
        datagramPipes.removeAll()

        for (_, pump) in pumps { pump.cancel() }
        pumps.removeAll()
        for (_, connection) in connections { await connection.close() }
        connections.removeAll()
        for (_, perDestination) in datagramConnections {
            for (_, connection) in perDestination { await connection.close() }
        }
        datagramConnections.removeAll()
        await channel.close()
    }
}

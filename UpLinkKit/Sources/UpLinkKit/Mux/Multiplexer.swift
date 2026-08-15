import Foundation

/// Which end of the link this multiplexer is.
///
/// Traffic only ever originates on the Mac, so stream creation is deliberately
/// single-sided: the Mac allocates every stream ID and the phone only ever
/// responds. That removes the whole class of ID-collision problems that
/// two-sided allocation schemes need odd/even partitioning to avoid.
public enum MuxRole: Sendable, Equatable {
    /// The Mac. Owns the proxied flows and allocates stream IDs.
    case initiator
    /// The phone. Dials destinations on the initiator's behalf.
    case responder
}

public enum MuxError: Error, Equatable, Sendable {
    case unknownStream(UInt32)
    case duplicateStream(UInt32)
    case flowControlViolation(UInt32)
    case responderCannotOpenStreams
    case controlFrameOnDataStream(Frame.Kind, UInt32)
    case dataFrameOnControlStream(Frame.Kind)
    case malformedControlPayload(Frame.Kind)
    case malformedDatagram(UInt32)
    case streamLimitReached
}

public enum MuxEvent: Equatable, Sendable {
    case openRequested(streamID: UInt32, destination: StreamOpen)
    case dataReceived(streamID: UInt32, Data)
    case datagramReceived(streamID: UInt32, DatagramEnvelope)
    case streamClosed(streamID: UInt32)
    case creditGranted(streamID: UInt32)
    case pingReceived
    case pongReceived
    case egressReported(EgressInterface)
    case helloReceived(version: UInt16, identity: String)
    case helloAcknowledged(version: UInt16)
    /// The peer has forgotten this pairing. Not a failure — an instruction.
    case unpairedByPeer
}

/// Carries many logical streams over one connection.
///
/// This type owns no socket and performs no I/O. It is a synchronous state
/// machine: frames go in, frames and events come out. That keeps every
/// flow-control decision deterministically testable without a network, which
/// matters because flow control is the part most likely to be subtly wrong and
/// least likely to show up in a manual test.
///
/// **Memory boundaries.** Payload bytes are moved, never duplicated into any
/// persistent store — a `Data` slice travels from the decoder, through this
/// type's in-memory bookkeeping, straight to a socket write. Nothing here
/// opens a file, allocates a cache, or retains payload after the frame that
/// carried it has been emitted.
public struct Multiplexer: Sendable {

    /// Bytes a peer may send on one stream before it must wait for a `WINDOW`
    /// frame. This is the knob that stops a large download from monopolising
    /// the shared connection: 256 KiB is large enough to keep a fast link busy
    /// across a round trip on the local Wi-Fi hop, small enough that a stalled
    /// stream cannot hold much of the link hostage.
    public static let initialWindow = 256 * 1024

    /// Send a window update once at least this fraction of a window has been
    /// drained, rather than on every read — otherwise a stream doing 1-byte
    /// reads would emit a WINDOW frame per byte and drown the link in
    /// bookkeeping.
    private static let windowUpdateFraction = 2

    /// Guards against a peer opening unbounded streams and exhausting memory.
    public static let maxConcurrentStreams = 4_096

    public static let controlStreamID: UInt32 = 0
    public static let protocolVersion: UInt16 = 1

    private struct StreamState {
        /// Bytes we may still send before the peer must grant more.
        var sendCredit: Int
        /// Bytes the peer may still send us.
        var receiveWindow: Int
        /// Received-but-not-yet-drained bytes, used to decide when to top the
        /// peer's window back up.
        var pendingConsumption: Int = 0
    }

    private let role: MuxRole
    private var streams: [UInt32: StreamState] = [:]
    /// Monotonic. Never rewound, so a stream ID is never reused within a
    /// connection's lifetime and a late frame for a closed stream can always be
    /// recognised as stale rather than mis-delivered into a new flow.
    private var nextStreamID: UInt32 = 1
    /// Highest stream ID ever seen on this connection.
    ///
    /// Because IDs are allocated monotonically by a single side, this one
    /// number distinguishes the two cases that matter without remembering
    /// anything per stream: an ID at or below the mark that is not currently
    /// open was opened and closed (a stale frame — ignore it), and an ID above
    /// the mark was never opened at all (a protocol error). Keeping a set of
    /// closed IDs instead would grow without bound across a long session.
    private var highWaterStreamID: UInt32 = 0

    public init(role: MuxRole) {
        self.role = role
    }

    public var openStreamIDs: [UInt32] { streams.keys.sorted() }

    /// Total per-stream bookkeeping entries this multiplexer is holding.
    ///
    /// The memory regression suite asserts this returns to zero after every
    /// stream has been closed, which is what makes the high-water-mark design
    /// observable rather than merely asserted. **If you add another per-stream
    /// collection, include its count here** — otherwise that collection can
    /// leak without the regression suite noticing.
    var retainedStreamStateCount: Int { streams.count }

    // MARK: - Outbound

    public mutating func openStream(to destination: StreamOpen) throws -> (streamID: UInt32, frame: Frame) {
        guard role == .initiator else { throw MuxError.responderCannotOpenStreams }
        guard streams.count < Self.maxConcurrentStreams else { throw MuxError.streamLimitReached }

        let id = nextStreamID
        nextStreamID += 1
        highWaterStreamID = max(highWaterStreamID, id)

        streams[id] = StreamState(sendCredit: Self.initialWindow, receiveWindow: Self.initialWindow)

        return (id, Frame(kind: .open, streamID: id, payload: destination.encoded()))
    }

    public func sendCredit(for streamID: UInt32) throws -> Int {
        guard let stream = streams[streamID] else { throw MuxError.unknownStream(streamID) }
        return stream.sendCredit
    }

    /// Frames as much of `data` as current credit allows.
    ///
    /// Returns how many bytes were actually taken. A short accept is normal
    /// backpressure, not an error — the caller keeps the remainder and retries
    /// when a ``MuxEvent/creditGranted(streamID:)`` arrives. Refusing to buffer
    /// the remainder here is deliberate: the socket layer already has a buffer,
    /// and a second one inside the mux would just hide the backpressure signal.
    public mutating func send(_ data: Data, on streamID: UInt32) throws -> (frames: [Frame], accepted: Int) {
        guard var stream = streams[streamID] else { throw MuxError.unknownStream(streamID) }

        let acceptable = min(data.count, stream.sendCredit)
        guard acceptable > 0 else { return ([], 0) }

        var frames: [Frame] = []
        var offset = data.startIndex
        let end = data.startIndex + acceptable

        while offset < end {
            let chunkEnd = min(offset + Frame.maxPayloadSize, end)
            frames.append(Frame(kind: .data, streamID: streamID, payload: Data(data[offset ..< chunkEnd])))
            offset = chunkEnd
        }

        stream.sendCredit -= acceptable
        streams[streamID] = stream

        return (frames, acceptable)
    }

    /// Frames one UDP datagram, or reports that it was dropped.
    ///
    /// Returns `dropped: true` rather than throwing, because both reasons a
    /// datagram cannot be sent — too large for a frame, or no credit left — are
    /// normal UDP outcomes. UDP does not promise delivery, and a caller that
    /// had to handle an error for every dropped packet would end up ignoring
    /// it anyway. The one thing never done here is splitting: two half
    /// datagrams are two corrupt packets the receiver cannot detect.
    public mutating func sendDatagram(
        _ payload: Data,
        to host: String,
        port: UInt16,
        on streamID: UInt32
    ) throws -> (frame: Frame?, dropped: Bool) {
        guard var stream = streams[streamID] else { throw MuxError.unknownStream(streamID) }

        guard payload.count <= DatagramEnvelope.maxPayloadSize(forHost: host) else {
            return (nil, true)
        }

        let envelope = DatagramEnvelope(host: host, port: port, payload: payload)
        let encoded = envelope.encoded()

        // Credit covers the encoded size, header included: that is what the
        // peer's receive window actually has to absorb.
        guard encoded.count <= stream.sendCredit else { return (nil, true) }

        stream.sendCredit -= encoded.count
        streams[streamID] = stream

        return (Frame(kind: .datagram, streamID: streamID, payload: encoded), false)
    }

    public mutating func closeStream(_ streamID: UInt32) throws -> Frame {
        guard streams.removeValue(forKey: streamID) != nil else {
            throw MuxError.unknownStream(streamID)
        }
        return Frame(kind: .close, streamID: streamID)
    }

    /// Reports that `count` bytes received on `streamID` have been handed
    /// onward (written to the real socket), freeing that much of the peer's
    /// window. Returns a `WINDOW` frame when enough has drained to be worth
    /// telling the peer about.
    public mutating func consumedReceivedBytes(_ count: Int, on streamID: UInt32) throws -> Frame? {
        guard var stream = streams[streamID] else { throw MuxError.unknownStream(streamID) }

        stream.pendingConsumption += count

        let threshold = Self.initialWindow / Self.windowUpdateFraction
        guard stream.pendingConsumption >= threshold else {
            streams[streamID] = stream
            return nil
        }

        let granted = stream.pendingConsumption
        stream.receiveWindow += granted
        stream.pendingConsumption = 0
        streams[streamID] = stream

        var payload = Data()
        payload.append(bigEndian: UInt32(granted))
        return Frame(kind: .window, streamID: streamID, payload: payload)
    }

    /// The dialling side's opening frame.
    ///
    /// Carries the sender's long-term fingerprint as well as the version, so
    /// the listener knows *which* paired device this is without having to
    /// infer it from the TLS layer.
    public func makeHello(identity: String) -> Frame {
        var payload = Data()
        payload.append(bigEndian16: Self.protocolVersion)
        let identityBytes = Data(identity.utf8.prefix(255))
        payload.append(UInt8(identityBytes.count))
        payload.append(identityBytes)
        return Frame(kind: .hello, streamID: Self.controlStreamID, payload: payload)
    }

    public func makeHelloAck() -> Frame {
        var payload = Data()
        payload.append(bigEndian16: Self.protocolVersion)
        return Frame(kind: .helloAck, streamID: Self.controlStreamID, payload: payload)
    }

    public func makeEgressReport(_ interface: EgressInterface) -> Frame {
        Frame(kind: .egressReport, streamID: Self.controlStreamID, payload: Data([interface.rawValue]))
    }

    /// "I have forgotten you; stop trying."
    ///
    /// Sent before tearing down, so the peer learns why instead of inferring it
    /// from a TLS-PSK handshake that now refuses an identity which no longer
    /// exists — indistinguishable, from the other end, from any other failure.
    /// Tells the dialling side why its pairing attempt was refused.
    public static func pairFailureFrame(_ error: PairingError) -> Frame {
        Frame(kind: .pairFailure, streamID: controlStreamID, payload: Data([error.wireCode]))
    }

    public static func unpairedFrame() -> Frame {
        Frame(kind: .unpaired, streamID: controlStreamID, payload: Data())
    }

    // MARK: - Inbound

    public mutating func receive(_ frame: Frame) throws -> [MuxEvent] {
        switch frame.kind {
        case .pairRequest, .pairResponse, .pairFailure:
            // Pairing happens before a multiplexer exists. Seeing one here
            // means the peer is confused or replaying, so refuse rather than
            // silently ignore.
            throw MuxError.malformedControlPayload(frame.kind)

        case .hello, .helloAck, .ping, .pong, .egressReport, .unpaired:
            guard frame.streamID == Self.controlStreamID else {
                throw MuxError.controlFrameOnDataStream(frame.kind, frame.streamID)
            }
            return try receiveControl(frame)

        case .open, .data, .window, .close, .datagram:
            guard frame.streamID != Self.controlStreamID else {
                throw MuxError.dataFrameOnControlStream(frame.kind)
            }
            return try receiveStream(frame)
        }
    }

    private mutating func receiveControl(_ frame: Frame) throws -> [MuxEvent] {
        switch frame.kind {
        case .ping:
            return [.pingReceived]
        case .pong:
            return [.pongReceived]
        case .helloAck:
            guard frame.payload.count >= 2 else {
                throw MuxError.malformedControlPayload(frame.kind)
            }
            let base = frame.payload.startIndex
            let version = (UInt16(frame.payload[base]) << 8) | UInt16(frame.payload[base + 1])
            return [.helloAcknowledged(version: version)]

        case .hello:
            guard frame.payload.count >= 3 else {
                throw MuxError.malformedControlPayload(frame.kind)
            }
            let base = frame.payload.startIndex
            let version = (UInt16(frame.payload[base]) << 8) | UInt16(frame.payload[base + 1])
            let identityLength = Int(frame.payload[base + 2])
            guard frame.payload.count >= 3 + identityLength,
                  let identity = String(
                      bytes: frame.payload[(base + 3) ..< (base + 3 + identityLength)],
                      encoding: .utf8
                  )
            else {
                throw MuxError.malformedControlPayload(frame.kind)
            }
            return [.helloReceived(version: version, identity: identity)]
        case .egressReport:
            guard let raw = frame.payload.first,
                  let interface = EgressInterface(rawValue: raw) else {
                throw MuxError.malformedControlPayload(frame.kind)
            }
            return [.egressReported(interface)]
        case .unpaired:
            // Deliberately carries no payload to validate. It is the last thing
            // a peer says before going away, and a strict parse here would turn
            // "you have been unpaired" into "malformed frame" — leaving the
            // user with a device that keeps retrying and no explanation.
            return [.unpairedByPeer]
        default:
            return []
        }
    }

    private mutating func receiveStream(_ frame: Frame) throws -> [MuxEvent] {
        let id = frame.streamID

        if frame.kind == .open {
            // At-or-below the high-water mark means this ID has already been
            // used on this connection, whether it is still open or long closed.
            guard streams[id] == nil, id > highWaterStreamID else {
                throw MuxError.duplicateStream(id)
            }
            guard streams.count < Self.maxConcurrentStreams else {
                throw MuxError.streamLimitReached
            }
            highWaterStreamID = id
            streams[id] = StreamState(sendCredit: Self.initialWindow, receiveWindow: Self.initialWindow)
            return [.openRequested(streamID: id, destination: try StreamOpen(payload: frame.payload))]
        }

        // A frame for a stream we already closed is a race with the peer, not
        // an error: our CLOSE and their DATA crossed on the wire. An ID above
        // the high-water mark was never opened, which is a real violation.
        if streams[id] == nil, id <= highWaterStreamID {
            return []
        }

        guard var stream = streams[id] else { throw MuxError.unknownStream(id) }

        switch frame.kind {
        case .data:
            guard frame.payload.count <= stream.receiveWindow else {
                throw MuxError.flowControlViolation(id)
            }
            stream.receiveWindow -= frame.payload.count
            streams[id] = stream
            return [.dataReceived(streamID: id, frame.payload)]

        case .datagram:
            guard frame.payload.count <= stream.receiveWindow else {
                throw MuxError.flowControlViolation(id)
            }
            guard let envelope = try? DatagramEnvelope(decoding: frame.payload) else {
                // Unlike a dropped outbound datagram, a malformed inbound one
                // means the peer is confused or hostile — the framing itself is
                // wrong, not merely the packet.
                throw MuxError.malformedDatagram(id)
            }
            stream.receiveWindow -= frame.payload.count
            streams[id] = stream
            return [.datagramReceived(streamID: id, envelope)]

        case .window:
            guard frame.payload.count >= 4 else {
                throw MuxError.malformedControlPayload(.window)
            }
            let base = frame.payload.startIndex
            let granted = (UInt32(frame.payload[base]) << 24)
                | (UInt32(frame.payload[base + 1]) << 16)
                | (UInt32(frame.payload[base + 2]) << 8)
                | UInt32(frame.payload[base + 3])
            stream.sendCredit += Int(granted)
            streams[id] = stream
            return [.creditGranted(streamID: id)]

        case .close:
            streams.removeValue(forKey: id)
            return [.streamClosed(streamID: id)]

        default:
            return []
        }
    }
}

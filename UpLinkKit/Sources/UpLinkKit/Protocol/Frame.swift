import Foundation

/// One unit on the wire.
///
/// Every byte crossing the Mac↔phone link is wrapped in a `Frame`. The layout is
/// fixed-width and deliberately boring:
///
///     +--------+-------------------+-------------------+-----------------+
///     | kind   | streamID          | payload length    | payload         |
///     | 1 byte | 4 bytes (BE)      | 4 bytes (BE)      | 0…maxPayload    |
///     +--------+-------------------+-------------------+-----------------+
///
/// `streamID` 0 is reserved for the control channel (handshake, keepalive,
/// egress reporting); every other ID belongs to one proxied TCP or UDP flow.
public struct Frame: Sendable, Equatable {

    public enum Kind: UInt8, Sendable, CaseIterable {
        /// Version negotiation, sent by the dialling side (the phone).
        case hello = 0x01
        /// Version acceptance, sent by the listening side (the Mac).
        case helloAck = 0x02
        /// Requests a new proxied flow to a destination host/port.
        case open = 0x03
        /// Payload bytes for an established stream.
        case data = 0x04
        /// Grants the peer additional send credit for one stream.
        case window = 0x05
        /// Ends one stream. Does not affect the connection.
        case close = 0x06
        case ping = 0x07
        case pong = 0x08
        /// Phone → Mac: which interface a stream actually egressed on. This is
        /// what lets the Mac claim "Cellular ✓" honestly instead of assuming.
        case egressReport = 0x09
        /// Phone → Mac, first frame of a pairing connection. Framing pairing
        /// the same way as everything else is what lets one listener serve both
        /// pairing and session traffic: the server dispatches on this byte
        /// rather than needing to know which TLS-PSK identity was negotiated.
        case pairRequest = 0x0A
        /// Mac → phone, the answering half of a pairing exchange.
        case pairResponse = 0x0B
        /// One UDP datagram plus the destination it is addressed to.
        ///
        /// Distinct from ``data`` because `data` is a byte stream the mux may
        /// chunk at any boundary, which is correct for TCP and destroys UDP.
        /// A `datagram` frame is always exactly one datagram.
        case datagram = 0x0C
    }

    /// 1 byte kind + 4 bytes streamID + 4 bytes payload length.
    public static let headerSize = 9

    /// Caps a single frame's payload. Two jobs: it bounds the decoder's buffer
    /// growth against a peer that claims a 4 GiB payload, and it keeps one
    /// stream's write from monopolising the shared connection for too long.
    public static let maxPayloadSize = 1 << 20  // 1 MiB

    public var kind: Kind
    public var streamID: UInt32
    public var payload: Data

    public init(kind: Kind, streamID: UInt32, payload: Data = Data()) {
        self.kind = kind
        self.streamID = streamID
        self.payload = payload
    }
}

public enum FrameDecodingError: Error, Equatable, Sendable {
    case unknownKind(UInt8)
    case payloadTooLarge(UInt32)
}

public enum FrameEncoder {
    public static func encode(_ frame: Frame) -> Data {
        var out = Data(capacity: Frame.headerSize + frame.payload.count)
        out.append(frame.kind.rawValue)
        out.append(bigEndian: frame.streamID)
        out.append(bigEndian: UInt32(frame.payload.count))
        out.append(frame.payload)
        return out
    }
}

extension Data {
    mutating func append(bigEndian value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
}

/// Incremental frame parser.
///
/// Feed it whatever the socket handed you with ``append(_:)`` and drain whole
/// frames with ``next()`` until it returns `nil`. Bytes are held in a single
/// buffer that is consumed via a read offset and compacted in place, so a long
/// download does not turn frame parsing into repeated O(n) memmoves.
///
/// Nothing here ever touches disk: payload bytes live in this buffer only long
/// enough to be handed to the multiplexer, which passes them straight to a
/// socket. There is no spooling, no cache file, and no temporary directory
/// anywhere on the data path.
public struct FrameDecoder: Sendable {

    private var buffer = Data()
    private var offset = 0

    /// Compact once the consumed prefix exceeds this, rather than after every
    /// frame — small frames would otherwise cause a copy per frame.
    private static let compactionThreshold = 64 * 1024

    public init() {}

    public mutating func append(_ bytes: Data) {
        buffer.append(bytes)
    }

    /// Returns the next complete frame, or `nil` when more bytes are needed.
    ///
    /// - Throws: ``FrameDecodingError`` if the peer sent something structurally
    ///   invalid. Both cases are unrecoverable for the connection — the caller
    ///   is expected to tear down rather than resynchronise, because once the
    ///   framing is in doubt there is no trustworthy place to resume from.
    public mutating func next() throws -> Frame? {
        guard buffer.count - offset >= Frame.headerSize else {
            compact()
            return nil
        }

        let base = buffer.startIndex + offset
        let rawKind = buffer[base]
        guard let kind = Frame.Kind(rawValue: rawKind) else {
            throw FrameDecodingError.unknownKind(rawKind)
        }

        let streamID = buffer.readUInt32(at: base + 1)
        let length = buffer.readUInt32(at: base + 5)

        // Checked before we size any allocation. A peer claiming a 4 GiB
        // payload must not be able to make us reserve 4 GiB waiting for it.
        guard length <= UInt32(Frame.maxPayloadSize) else {
            throw FrameDecodingError.payloadTooLarge(length)
        }

        let total = Frame.headerSize + Int(length)
        guard buffer.count - offset >= total else {
            compact()
            return nil
        }

        let payloadStart = base + Frame.headerSize
        let payload = Data(buffer[payloadStart ..< payloadStart + Int(length)])
        offset += total
        compact()

        return Frame(kind: kind, streamID: streamID, payload: payload)
    }

    private mutating func compact() {
        guard offset > 0 else { return }
        if offset == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            offset = 0
        } else if offset >= Self.compactionThreshold {
            buffer = Data(buffer[(buffer.startIndex + offset)...])
            offset = 0
        }
    }
}

extension Data {
    fileprivate func readUInt32(at index: Index) -> UInt32 {
        (UInt32(self[index]) << 24)
            | (UInt32(self[index + 1]) << 16)
            | (UInt32(self[index + 2]) << 8)
            | UInt32(self[index + 3])
    }
}

import Foundation

/// The destination carried by an ``Frame/Kind/open`` frame.
///
/// Layout:
///
///     +-------+------------+---------------+------------------+
///     | proto | port (BE)  | host len (BE) | host (UTF-8)     |
///     | 1     | 2          | 2             | 1…65535          |
///     +-------+------------+---------------+------------------+
///
/// The host is sent as a *name*, not a resolved address, on purpose: resolution
/// happens on the phone so DNS queries also egress over cellular. Resolving on
/// the Mac would leak every hostname the user visits to whatever network the
/// Mac is attached to, which would defeat the point of the bridge.
public struct StreamOpen: Sendable, Equatable {

    public enum Proto: UInt8, Sendable {
        case tcp = 0x01
        case udp = 0x02
    }

    public var proto: Proto
    public var host: String
    public var port: UInt16

    public init(proto: Proto, host: String, port: UInt16) {
        self.proto = proto
        self.host = host
        self.port = port
    }

    public func encoded() -> Data {
        let hostBytes = Data(host.utf8)
        var out = Data(capacity: 5 + hostBytes.count)
        out.append(proto.rawValue)
        out.append(bigEndian16: port)
        out.append(bigEndian16: UInt16(hostBytes.count))
        out.append(hostBytes)
        return out
    }

    public init(payload: Data) throws {
        // Fixed portion: proto (1) + port (2) + host length (2).
        guard payload.count >= 5 else { throw StreamOpenError.malformed }

        let base = payload.startIndex

        let rawProto = payload[base]
        guard let proto = Proto(rawValue: rawProto) else {
            throw StreamOpenError.unknownProtocol(rawProto)
        }

        let port = (UInt16(payload[base + 1]) << 8) | UInt16(payload[base + 2])
        let hostLength = Int(payload[base + 3]) << 8 | Int(payload[base + 4])

        // An empty host is meaningless and would produce a stream that can
        // never be dialled, so it is rejected here rather than failing later
        // on the phone where the error has no useful context.
        guard hostLength > 0 else { throw StreamOpenError.malformed }
        guard payload.count == 5 + hostLength else { throw StreamOpenError.malformed }

        let hostBytes = payload[(base + 5) ..< (base + 5 + hostLength)]
        // Deliberately not lossy: a hostname we cannot decode exactly is a
        // hostname we must not silently substitute with U+FFFD and then dial.
        guard let host = String(bytes: hostBytes, encoding: .utf8) else {
            throw StreamOpenError.malformed
        }

        self.init(proto: proto, host: host, port: port)
    }
}

public enum StreamOpenError: Error, Equatable, Sendable {
    case malformed
    case unknownProtocol(UInt8)
}

extension Data {
    mutating func append(bigEndian16 value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
}

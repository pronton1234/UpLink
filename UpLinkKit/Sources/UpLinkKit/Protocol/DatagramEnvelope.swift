import Foundation

public enum DatagramError: Error, Equatable, Sendable {
    case malformed
    /// The datagram cannot fit in one frame. Reported rather than thrown on the
    /// send path, because dropping is the correct response.
}

/// One UDP datagram, with the destination it is going to.
///
///     +----------+---------------+------------+------------------+
///     | host len | host (UTF-8)  | port (BE)  | datagram bytes   |
///     | 1 byte   | 1…255         | 2 bytes    | 0…budget         |
///     +----------+---------------+------------+------------------+
///
/// **Why the destination travels with every datagram.** TCP puts the
/// destination in the `OPEN` frame once, because a TCP stream has exactly one.
/// A UDP session does not: a single `NEAppProxyUDPFlow` carries datagrams to
/// many destinations — a browser doing QUIC to several hosts, a resolver
/// talking to several nameservers — all on one flow. Addressing per stream
/// simply cannot express that, so it is addressed per datagram instead.
///
/// The host is carried as a **name** wherever the client gave us one, for the
/// same reason as ``StreamOpen``: resolution happens on the phone so DNS
/// egresses over cellular too. Resolving on the Mac would leak every lookup to
/// whatever network the Mac is attached to — which, for DNS, is most of what
/// the bridge is meant to hide.
public struct DatagramEnvelope: Sendable, Equatable {

    /// Fixed overhead: 1 byte host length + 2 bytes port.
    private static let fixedOverhead = 3

    public var host: String
    public var port: UInt16
    public var payload: Data

    public init(host: String, port: UInt16, payload: Data) {
        self.host = host
        self.port = port
        self.payload = payload
    }

    /// The largest a real UDP datagram can be: 65535 minus the IP and UDP
    /// headers. Nothing on the wire can exceed this, so nothing here needs to.
    public static let maxDatagramSize = 65_507

    /// Largest datagram this envelope can carry to `host`.
    ///
    /// Bounded by the real UDP limit rather than ``Frame/maxPayloadSize``.
    /// Deriving it from the frame cap (1 MiB) produced a budget larger than a
    /// stream's 256 KiB credit window, so a maximum-size datagram was always
    /// dropped for lack of credit and could never be sent at all.
    ///
    /// In practice the UDP limit always binds — a hostname is at most 255
    /// bytes, so the frame budget never becomes the smaller of the two. The
    /// `min` is kept so the two constraints cannot silently diverge if
    /// ``Frame/maxPayloadSize`` is ever reduced.
    public static func maxPayloadSize(forHost host: String) -> Int {
        min(
            Self.maxDatagramSize,
            Frame.maxPayloadSize - fixedOverhead - Data(host.utf8).count
        )
    }

    public func encoded() -> Data {
        let hostBytes = Data(host.utf8.prefix(255))
        var out = Data(capacity: Self.fixedOverhead + hostBytes.count + payload.count)
        out.append(UInt8(hostBytes.count))
        out.append(hostBytes)
        out.append(bigEndian16: port)
        out.append(payload)
        return out
    }

    public init(decoding data: Data) throws {
        guard data.count >= Self.fixedOverhead else { throw DatagramError.malformed }
        let base = data.startIndex

        let hostLength = Int(data[base])
        // A zero-length host would produce a datagram that can never be sent.
        guard hostLength > 0, data.count >= Self.fixedOverhead + hostLength else {
            throw DatagramError.malformed
        }

        // Deliberately not lossy: a name we cannot decode exactly must not be
        // silently replaced with U+FFFD and then dialled.
        guard let host = String(bytes: data[(base + 1) ..< (base + 1 + hostLength)], encoding: .utf8) else {
            throw DatagramError.malformed
        }

        let portIndex = base + 1 + hostLength
        let port = (UInt16(data[portIndex]) << 8) | UInt16(data[portIndex + 1])

        self.host = host
        self.port = port
        self.payload = Data(data[(portIndex + 2)...])
    }
}

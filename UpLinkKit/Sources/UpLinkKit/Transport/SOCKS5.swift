import Foundation

/// Reply codes from RFC 1928 §6.
public enum SOCKS5Reply: UInt8, Sendable, Equatable {
    case succeeded = 0x00
    case generalFailure = 0x01
    case notAllowed = 0x02
    case networkUnreachable = 0x03
    case hostUnreachable = 0x04
    case connectionRefused = 0x05
    case ttlExpired = 0x06
    case commandNotSupported = 0x07
    case addressTypeNotSupported = 0x08
}

public enum SOCKS5Error: Error, Equatable, Sendable {
    case unsupportedVersion(UInt8)
    case unsupportedCommand(UInt8)
    case unsupportedAddressType(UInt8)
    case malformedRequest
}

/// The Mac's front door.
///
/// Browsers and command-line tools speak SOCKS5 to this; each `CONNECT` becomes
/// one multiplexed stream to the phone. Chosen over a `NETransparentProxyProvider`
/// for one overriding reason: a SOCKS proxy is an **ordinary app**. It installs
/// by dragging to /Applications, runs straight from Xcode, and needs no
/// notarization, no disabled SIP, and no system-extension approval. A system
/// extension cannot be loaded at all without one of those, which makes it
/// nearly untestable during development.
///
/// The trade-off, stated honestly: this captures apps that honour the system
/// proxy — Safari, Chrome, most GUI apps, curl — and misses apps that use raw
/// sockets or ignore proxy settings.
///
/// Incremental by design: a client's greeting and request can each arrive split
/// across any number of reads.
public struct SOCKS5Handshake: Sendable {

    public enum State: Sendable, Equatable {
        case awaitingGreeting
        case awaitingRequest
        case ready
        case failed
    }

    public static let version: UInt8 = 0x05
    private static let noAuth: UInt8 = 0x00
    private static let noAcceptableMethods: UInt8 = 0xFF
    private static let commandConnect: UInt8 = 0x01

    public private(set) var state: State = .awaitingGreeting
    /// Set once a valid CONNECT has been parsed.
    public private(set) var destination: StreamOpen?

    private var buffer = Data()

    public init() {}

    /// Feeds bytes in and returns a reply to write back, if one is due now.
    ///
    /// Returns `nil` when more bytes are needed — a partial greeting or request
    /// is normal, not an error.
    public mutating func consume(_ bytes: Data) throws -> Data? {
        buffer.append(bytes)

        switch state {
        case .awaitingGreeting:
            return try parseGreeting()
        case .awaitingRequest:
            try parseRequest()
            return nil
        case .ready, .failed:
            return nil
        }
    }

    private mutating func parseGreeting() throws -> Data? {
        guard buffer.count >= 2 else { return nil }
        let base = buffer.startIndex

        guard buffer[base] == Self.version else {
            throw SOCKS5Error.unsupportedVersion(buffer[base])
        }

        let count = Int(buffer[base + 1])
        guard buffer.count >= 2 + count else { return nil }

        let methods = buffer[(base + 2) ..< (base + 2 + count)]
        buffer.removeFirst(2 + count)

        // No authentication: the listener binds to loopback, so anything that
        // reaches it is already a local process. Demanding credentials would
        // break every client for no security gain.
        guard methods.contains(Self.noAuth) else {
            state = .failed
            return Data([Self.version, Self.noAcceptableMethods])
        }

        state = .awaitingRequest
        return Data([Self.version, Self.noAuth])
    }

    private mutating func parseRequest() throws {
        // VER CMD RSV ATYP + address + 2-byte port
        guard buffer.count >= 4 else { return }
        let base = buffer.startIndex

        guard buffer[base] == Self.version else {
            throw SOCKS5Error.unsupportedVersion(buffer[base])
        }

        let command = buffer[base + 1]
        guard command == Self.commandConnect else {
            state = .failed
            throw SOCKS5Error.unsupportedCommand(command)
        }

        let addressType = buffer[base + 3]
        let host: String
        var consumed: Int

        switch addressType {
        case 0x01:  // IPv4
            guard buffer.count >= 4 + 4 + 2 else { return }
            let octets = (0 ..< 4).map { String(buffer[base + 4 + $0]) }
            host = octets.joined(separator: ".")
            consumed = 4 + 4

        case 0x03:  // Domain name
            guard buffer.count >= 5 else { return }
            let length = Int(buffer[base + 4])
            // A zero-length domain would produce a stream that can never be
            // dialled; reject rather than hand it onward.
            guard length > 0 else {
                state = .failed
                throw SOCKS5Error.malformedRequest
            }
            guard buffer.count >= 5 + length + 2 else { return }
            // Deliberately not lossy: a name we cannot decode exactly must not
            // be silently replaced with U+FFFD and then dialled.
            guard let name = String(bytes: buffer[(base + 5) ..< (base + 5 + length)], encoding: .utf8) else {
                state = .failed
                throw SOCKS5Error.malformedRequest
            }
            host = name
            consumed = 5 + length

        case 0x04:  // IPv6
            guard buffer.count >= 4 + 16 + 2 else { return }
            var groups: [String] = []
            for index in stride(from: 0, to: 16, by: 2) {
                let value = (UInt16(buffer[base + 4 + index]) << 8) | UInt16(buffer[base + 5 + index])
                groups.append(String(value, radix: 16))
            }
            host = groups.joined(separator: ":")
            consumed = 4 + 16

        default:
            state = .failed
            throw SOCKS5Error.unsupportedAddressType(addressType)
        }

        let port = (UInt16(buffer[base + consumed]) << 8) | UInt16(buffer[base + consumed + 1])
        consumed += 2
        buffer.removeFirst(consumed)

        // The hostname is passed through unresolved on purpose: resolution
        // happens on the phone so DNS also egresses over cellular. Resolving
        // here would leak every hostname the user visits to whatever network
        // the Mac is attached to.
        destination = StreamOpen(proto: .tcp, host: host, port: port)
        state = .ready
    }

    /// Bytes the client has already sent past the handshake.
    ///
    /// A client may pipeline its first payload into the same packet as the
    /// CONNECT; dropping it would silently truncate the request.
    public mutating func takeBufferedPayload() -> Data {
        defer { buffer.removeAll() }
        return buffer
    }

    /// Builds a reply frame. The bound address is reported as 0.0.0.0:0 —
    /// clients do not use it for CONNECT, and the real bound address is on the
    /// phone anyway.
    public static func reply(_ reply: SOCKS5Reply) -> Data {
        Data([version, reply.rawValue, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
    }
}

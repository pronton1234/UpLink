import Foundation

/// The `usbmuxd` wire protocol, as a pure codec.
///
/// `usbmuxd` is the daemon that carries every Mac↔iPhone conversation over the
/// cable: Xcode, `devicectl`, and `iproxy` all reach a device through it. It is
/// the right transport for this product for one reason above all others — it
/// needs **no network interface at all**. No Wi-Fi association, no Bonjour, no
/// multicast, no link-local address, no Personal Hotspot. A Mac whose Wi-Fi
/// radio is associated to nothing can still reach the phone, which is precisely
/// the configuration UpLink exists to serve and the one AWDL could not hold.
///
/// Split out from ``USBMuxClient`` deliberately: everything here is a pure
/// function over `Data`, so the framing, the plist bodies, and the byte-order
/// quirk below are all testable with no socket, no daemon, and no device.
///
/// **Framing.** Every message is a 16-byte little-endian header followed by an
/// XML property list:
///
///     +--------+---------+---------+--------+--------------------+
///     | length | version | message | tag    | XML plist          |
///     | 4 (LE) | 4 (LE)  | 4 (LE)  | 4 (LE) | length - 16 bytes  |
///     +--------+---------+---------+--------+--------------------+
///
/// `length` counts the header itself. `version` is 1 and `message` is 8
/// ("plist") for every message in the modern protocol; the older binary opcodes
/// exist but are not used here.
public enum USBMuxCodec {

    public static let headerSize = 16
    public static let version: UInt32 = 1
    /// Message type 8 — "the body is an XML plist". The only one we send.
    public static let plistMessage: UInt32 = 8

    /// Identifies us to `usbmuxd`. Both keys are required: the daemon rejects
    /// a plist request that omits them.
    static let clientVersion = "UpLink"
    static let programName = "UpLink"

    // MARK: - Port byte order

    /// Converts a host-order TCP port to the byte-swapped form `Connect` wants.
    ///
    /// **This is the single easiest thing to get wrong in the whole protocol.**
    /// `PortNumber` is an integer in a plist, so it looks like an ordinary
    /// number, but `usbmuxd` reads it as a big-endian `uint16` regardless of the
    /// host's byte order. Passing the port unswapped on a little-endian Mac
    /// asks for a completely different port: 50505 (`0xC549`) becomes 18885
    /// (`0x49C5`). The daemon then answers `ConnectionRefused` for a port
    /// nothing was ever listening on, which reads as "the phone isn't running
    /// UpLink" — an error message pointing at entirely the wrong thing.
    ///
    /// Covered by `USBMuxProtocolTests.portNumberIsByteSwapped`.
    public static func wirePort(_ port: UInt16) -> Int {
        Int(port.bigEndian)
    }

    /// Inverse of ``wirePort(_:)``, for tests and for reading back a request.
    public static func hostPort(_ wire: Int) -> UInt16 {
        UInt16(truncatingIfNeeded: wire).bigEndian
    }

    // MARK: - Header

    public struct Header: Sendable, Equatable {
        public var length: UInt32
        public var version: UInt32
        public var message: UInt32
        public var tag: UInt32

        /// Bytes of plist body this header promises, or `nil` if `length` is
        /// too small to be a real header — a malformed or desynchronised
        /// stream, which must not underflow into a huge unsigned body size.
        public var bodyLength: Int? {
            guard length >= UInt32(USBMuxCodec.headerSize) else { return nil }
            return Int(length) - USBMuxCodec.headerSize
        }
    }

    static func encodeHeader(_ header: Header) -> Data {
        var data = Data(capacity: headerSize)
        for value in [header.length, header.version, header.message, header.tag] {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Reads a header from the front of `data`, or `nil` if fewer than 16 bytes
    /// are available yet.
    public static func decodeHeader(_ data: Data) -> Header? {
        guard data.count >= headerSize else { return nil }
        func word(_ index: Int) -> UInt32 {
            let start = data.startIndex + index * 4
            var value: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &value) { raw in
                data.copyBytes(to: raw, from: start ..< start + 4)
            }
            return UInt32(littleEndian: value)
        }
        return Header(length: word(0), version: word(1), message: word(2), tag: word(3))
    }

    // MARK: - Requests

    public enum Request: Sendable, Equatable {
        /// One-shot enumeration of everything attached right now.
        case listDevices
        /// Subscribe to attach/detach events. The socket that sends this
        /// becomes an event stream and cannot be used for anything else.
        case listen
        /// Open a TCP connection to `port` on the device. On success the socket
        /// stops speaking this protocol and becomes a raw byte pipe.
        case connect(deviceID: UInt32, port: UInt16)

        var body: [String: Any] {
            var plist: [String: Any] = [
                "ClientVersionString": USBMuxCodec.clientVersion,
                "ProgName": USBMuxCodec.programName,
                "kLibUSBMuxVersion": 3,
            ]
            switch self {
            case .listDevices:
                plist["MessageType"] = "ListDevices"
            case .listen:
                plist["MessageType"] = "Listen"
            case let .connect(deviceID, port):
                plist["MessageType"] = "Connect"
                plist["DeviceID"] = Int(deviceID)
                plist["PortNumber"] = USBMuxCodec.wirePort(port)
            }
            return plist
        }
    }

    public static func encode(_ request: Request, tag: UInt32) throws -> Data {
        let body = try PropertyListSerialization.data(
            fromPropertyList: request.body, format: .xml, options: 0
        )
        let header = Header(
            length: UInt32(headerSize + body.count),
            version: version,
            message: plistMessage,
            tag: tag
        )
        return encodeHeader(header) + body
    }

    // MARK: - Replies

    /// `Result.Number`. Only `.ok` continues; everything else is terminal for
    /// the request that provoked it.
    /// `Result.Number`. Only `.ok` continues; everything else is terminal for
    /// the request that provoked it.
    ///
    /// **`badVersion` is 6, and this was wrong until the real daemon said so.**
    /// It was written as 5 from memory, and the unit tests could not catch it:
    /// they run against a fake built on the same assumption, so both sides
    /// agreed on a value Apple does not use. Sending a bad header version to
    /// the real `usbmuxd` returns 6, which the client then rejected as
    /// "unknown Result number 6" — turning a precise, actionable daemon error
    /// into a parse failure.
    ///
    /// Found by `spike/usb-probe --selftest`, which exists to break exactly
    /// that circularity and needs no device to do it.
    public enum ResultCode: Int, Sendable, Equatable {
        case ok = 0
        case badCommand = 1
        case badDevice = 2
        case connectionRefused = 3
        case badVersion = 6

        /// What this means in terms a person can act on. `connectionRefused` is
        /// by far the most common in normal use and does **not** mean the cable
        /// or the pairing is broken: it means nothing on the phone is listening
        /// on that port, i.e. UpLink is not running over there.
        public var explanation: String {
            switch self {
            case .ok: "ok"
            case .badCommand: "usbmuxd rejected the request"
            case .badDevice: "no such device — it was unplugged mid-request"
            case .connectionRefused: "nothing is listening on that port on the iPhone"
            case .badVersion: "usbmuxd protocol version mismatch"
            }
        }
    }

    public enum Reply: Sendable, Equatable {
        case result(ResultCode)
        /// A `Result` whose number this build does not recognise. Terminal,
        /// like any non-zero result, but the number is preserved for the log.
        case unknownResult(Int)
        case deviceList([USBDevice])
        case attached(USBDevice)
        case detached(deviceID: UInt32)
        /// A message type we do not handle. Carried rather than thrown so an
        /// unknown event cannot tear down a working event stream.
        case unrecognised(messageType: String)
    }

    /// Decodes one complete message, or `nil` if `data` does not yet hold one.
    ///
    /// Returns the number of bytes consumed alongside the reply so a caller
    /// draining a stream can advance without re-parsing.
    public static func decode(_ data: Data) throws -> (reply: Reply, consumed: Int)? {
        guard let header = decodeHeader(data) else { return nil }
        guard let bodyLength = header.bodyLength else {
            throw USBMuxError.malformed("header claims \(header.length) bytes, less than a header")
        }
        let total = headerSize + bodyLength
        guard data.count >= total else { return nil }

        let body = data.subdata(in: data.startIndex + headerSize ..< data.startIndex + total)
        guard let plist = try PropertyListSerialization.propertyList(
            from: body, options: [], format: nil
        ) as? [String: Any] else {
            throw USBMuxError.malformed("body is not a plist dictionary")
        }
        return (try reply(from: plist), total)
    }

    static func reply(from plist: [String: Any]) throws -> Reply {
        switch plist["MessageType"] as? String {
        case "Result":
            guard let number = plist["Number"] as? Int else {
                throw USBMuxError.malformed("Result without a Number")
            }
            // An unrecognised code is CARRIED, not thrown.
            //
            // Throwing turned a daemon that was telling us something specific
            // into an opaque parse failure — and it would do the same for any
            // code a future macOS adds. Anything non-zero is terminal for the
            // request either way; what matters is that the number survives to
            // be logged.
            guard let code = ResultCode(rawValue: number) else {
                return .unknownResult(number)
            }
            return .result(code)

        case "Attached":
            guard let device = USBDevice(plist: plist) else {
                throw USBMuxError.malformed("Attached without usable device properties")
            }
            return .attached(device)

        case "Detached":
            guard let deviceID = plist["DeviceID"] as? Int else {
                throw USBMuxError.malformed("Detached without a DeviceID")
            }
            return .detached(deviceID: UInt32(deviceID))

        case nil where plist["DeviceList"] != nil:
            let entries = plist["DeviceList"] as? [[String: Any]] ?? []
            return .deviceList(entries.compactMap(USBDevice.init(plist:)))

        case let other:
            return .unrecognised(messageType: other ?? "<none>")
        }
    }
}

/// One device `usbmuxd` can see.
public struct USBDevice: Sendable, Equatable, Identifiable {

    /// How `usbmuxd` is reaching this device.
    ///
    /// **`network` must never be used by this product.** `usbmuxd` also
    /// surfaces devices paired over Wi-Fi ("Connect via network" in Xcode), and
    /// they are indistinguishable from cabled ones apart from this field. Using
    /// one would silently route the bridge's control link over the very Wi-Fi
    /// network the user is trying not to depend on — the bridge would appear to
    /// work and would collapse the moment the Wi-Fi did, which is the exact
    /// class of false pass this codebase keeps having to design against.
    public enum ConnectionType: Sendable, Equatable {
        case usb
        case network
        case other(String)

        init(_ raw: String) {
            switch raw {
            case "USB": self = .usb
            case "Network": self = .network
            default: self = .other(raw)
            }
        }

        public var isCable: Bool { self == .usb }
    }

    /// `usbmuxd`'s handle for this attachment. Changes on every replug, so it
    /// is never persisted — ``udid`` is the durable identity.
    public let deviceID: UInt32
    /// The device's UDID (`SerialNumber` on the wire). Stable across replugs
    /// and reboots, which is what makes it usable as a pairing identity.
    public let udid: String
    public let connectionType: ConnectionType

    public var id: UInt32 { deviceID }

    public init(deviceID: UInt32, udid: String, connectionType: ConnectionType) {
        self.deviceID = deviceID
        self.udid = udid
        self.connectionType = connectionType
    }

    init?(plist: [String: Any]) {
        guard let deviceID = plist["DeviceID"] as? Int else { return nil }
        let properties = plist["Properties"] as? [String: Any] ?? [:]
        guard let udid = properties["SerialNumber"] as? String, !udid.isEmpty else { return nil }
        self.deviceID = UInt32(deviceID)
        self.udid = udid
        self.connectionType = ConnectionType(properties["ConnectionType"] as? String ?? "")
    }
}

public enum USBMuxError: Error, Equatable, Sendable {
    /// The daemon socket could not be opened. On a Mac this essentially only
    /// happens if `usbmuxd` is not running, which is not a normal state.
    case unavailable(String)
    case malformed(String)
    /// A request got a non-zero `Result`.
    case refused(USBMuxCodec.ResultCode)
    case disconnected
}

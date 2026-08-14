import Foundation
import Network
import CryptoKit

/// The single message each side sends during pairing.
///
///     +---------+------------------+----------+------------------+
///     | version | X25519 pub key   | name len | device name      |
///     | 1 byte  | 32 bytes         | 1 byte   | 1…255 (UTF-8)    |
///     +---------+------------------+----------+------------------+
///
/// The exchange runs inside a TLS session whose PSK is derived from the
/// six-digit code, so a wrong code fails the TLS handshake and never reaches
/// this layer. That is what authenticates the exchange — there is no signature
/// here, because the code already proved the peer is the device the user is
/// standing in front of.
struct PairingHello: Sendable, Equatable {

    static let version: UInt8 = 1

    var publicKey: Data
    var deviceName: String

    func encoded() -> Data {
        let nameBytes = Data(deviceName.utf8.prefix(255))
        var out = Data()
        out.append(Self.version)
        out.append(publicKey)
        out.append(UInt8(nameBytes.count))
        out.append(nameBytes)
        return out
    }

    init(publicKey: Data, deviceName: String) {
        self.publicKey = publicKey
        self.deviceName = deviceName
    }

    init(decoding data: Data) throws {
        guard data.count >= 34 else { throw PairingError.handshakeFailed }
        let base = data.startIndex

        guard data[base] == Self.version else { throw PairingError.handshakeFailed }

        publicKey = Data(data[(base + 1) ..< (base + 33)])

        let nameLength = Int(data[base + 33])
        guard nameLength > 0, data.count >= 34 + nameLength else {
            throw PairingError.handshakeFailed
        }
        guard let name = String(bytes: data[(base + 34) ..< (base + 34 + nameLength)], encoding: .utf8) else {
            throw PairingError.handshakeFailed
        }
        deviceName = name
    }
}

/// The phone's side of pairing: dials the Mac using the typed code.
public struct PairingClient: Sendable {

    private let queue: DispatchQueue
    private let deviceName: String

    public init(queue: DispatchQueue, deviceName: String = PairingClient.defaultDeviceName) {
        self.queue = queue
        self.deviceName = deviceName
    }

    public static var defaultDeviceName: String {
        #if canImport(UIKit)
        return "iPhone"
        #else
        return Host.current().localizedName ?? "Mac"
        #endif
    }

    /// Runs the exchange and returns the peer to remember.
    public func pair(
        with peer: DiscoveredPeer,
        code: PairingCode,
        localIdentity: Curve25519.KeyAgreement.PrivateKey
    ) async throws -> PairedDevice {

        // Salted with the Mac's fingerprint from its TXT record — the same
        // input the Mac uses. The service NAME cannot be used: it travels
        // through DNS-SD, may be renamed for uniqueness, and typically contains
        // a typographic apostrophe that can round-trip differently, which
        // yields a different salt, a different PSK, and a TLS failure with no
        // usable diagnostic.
        guard let fingerprint = peer.fingerprint else {
            throw PairingError.handshakeFailed
        }
        let salt = Data(SHA256.hash(data: Data(fingerprint.utf8)))
        let parameters = TransportParameters.pairing(code: code, salt: salt, profile: peer.profile)

        let connection = NWConnection(to: peer.endpoint, using: parameters)
        let channel = NWConnectionChannel(connection: connection)

        // A wrong code fails here, in the TLS handshake, before any key
        // material is exchanged.
        try await channel.start(on: queue)
        defer { Task { await channel.close() } }

        let hello = PairingHello(
            publicKey: localIdentity.publicKey.rawRepresentation,
            deviceName: deviceName
        )
        try await channel.send(
            FrameEncoder.encode(
                Frame(kind: .pairRequest, streamID: Multiplexer.controlStreamID, payload: hello.encoded())
            )
        )

        // Read until a whole frame lands: the reply is small, but a short read
        // is still possible and silently truncating it would look like a
        // corrupt public key rather than a partial read.
        var decoder = FrameDecoder()
        var reply: Frame?
        while reply == nil {
            guard let bytes = try await channel.receive() else {
                throw PairingError.handshakeFailed
            }
            decoder.append(bytes)
            reply = try? decoder.next()
        }
        guard let reply, reply.kind == .pairResponse else {
            throw PairingError.handshakeFailed
        }
        let theirs = try PairingHello(decoding: reply.payload)

        return PairedDevice(
            fingerprint: PairedDevice.fingerprint(of: theirs.publicKey),
            name: theirs.deviceName,
            publicKey: theirs.publicKey,
            pairedAt: Date()
        )
    }
}

/// The Mac's side of pairing: answers one incoming attempt.
public struct PairingResponder: Sendable {

    private let deviceName: String

    public init(deviceName: String) {
        self.deviceName = deviceName
    }

    /// Answers one pairing attempt whose request frame has already been read.
    ///
    /// The caller reads the first frame in order to tell a pairing connection
    /// from a session connection, so the request arrives here already decoded
    /// rather than being read a second time.
    public func respond(
        to request: Frame,
        on channel: FrameChannel,
        localIdentity: Curve25519.KeyAgreement.PrivateKey
    ) async throws -> PairedDevice {

        guard request.kind == .pairRequest else { throw PairingError.handshakeFailed }
        let theirs = try PairingHello(decoding: request.payload)

        let ours = PairingHello(
            publicKey: localIdentity.publicKey.rawRepresentation,
            deviceName: deviceName
        )
        try await channel.send(
            FrameEncoder.encode(
                Frame(kind: .pairResponse, streamID: Multiplexer.controlStreamID, payload: ours.encoded())
            )
        )

        return PairedDevice(
            fingerprint: PairedDevice.fingerprint(of: theirs.publicKey),
            name: theirs.deviceName,
            publicKey: theirs.publicKey,
            pairedAt: Date()
        )
    }
}

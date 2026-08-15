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

/// The dialling side of pairing.
///
/// **This is the Mac now.** Over `usbmuxd` only the Mac can open a connection,
/// so the Mac dials with the code and the phone's listener answers. The user
/// still reads the code off the Mac and types it into the phone — who displays
/// and who types is independent of who dials; typing it is what arms the
/// phone's listener with the pairing PSK.
///
/// Transport-agnostic: the caller supplies an already-connected channel. That
/// keeps the TLS-PSK dial in one place (``MacSessionClient``) and lets the
/// whole exchange be tested over an in-memory pipe.
public struct PairingClient: Sendable {

    private let deviceName: String

    public init(deviceName: String = PairingClient.defaultDeviceName) {
        self.deviceName = deviceName
    }

    public static var defaultDeviceName: String {
        #if canImport(UIKit)
        return "iPhone"
        #else
        return Host.current().localizedName ?? "Mac"
        #endif
    }

    /// Runs the exchange on an open channel and returns the peer to remember.
    ///
    /// A wrong code fails earlier, in the TLS-PSK handshake the caller performs
    /// when opening the channel, and never reaches here — see
    /// ``MacSessionClient/pair(relayPort:code:)``, which maps that failure to
    /// `.codeMismatch`.
    public func pair(
        on channel: FrameChannel,
        localIdentity: Curve25519.KeyAgreement.PrivateKey
    ) async throws -> PairedDevice {

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
        // The Mac's account of a refusal, when it is the only side that knows.
        if let reply, reply.kind == .pairFailure, let code = reply.payload.first {
            throw PairingError(wireCode: code)
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

/// The listening side of pairing: answers one incoming attempt.
///
/// **This is the phone now.** The Mac dials, so the pairing connection arrives
/// here — the mirror image of the AWDL era, and the reason the user types the
/// code into the phone even though the Mac is what generates it.
public struct PairingResponder: Sendable {

    private let deviceName: String

    public init(deviceName: String) {
        self.deviceName = deviceName
    }

    /// Reads the request and works out who the peer is, WITHOUT answering.
    ///
    /// The caller reads the first frame in order to tell a pairing connection
    /// from a session connection, so the request arrives here already decoded
    /// rather than being read a second time.
    ///
    /// Split from ``confirm(on:localIdentity:)`` so the caller can commit its
    /// own side of the pairing before telling the peer it is paired. Answering
    /// first — which is what this used to do — means a failure in the caller's
    /// own storage leaves the phone believing it is paired with a Mac that has
    /// no record of it. That one-sided state then has to be cleaned up by hand
    /// on both devices, and is a large part of why re-pairing was painful.
    public func identify(_ request: Frame) throws -> PairedDevice {
        guard request.kind == .pairRequest else { throw PairingError.handshakeFailed }
        let theirs = try PairingHello(decoding: request.payload)
        return PairedDevice(
            fingerprint: PairedDevice.fingerprint(of: theirs.publicKey),
            name: theirs.deviceName,
            publicKey: theirs.publicKey,
            pairedAt: Date()
        )
    }

    /// Tells the peer it is paired. Call only once our own side is committed.
    public func confirm(
        on channel: FrameChannel,
        localIdentity: Curve25519.KeyAgreement.PrivateKey
    ) async throws {
        let ours = PairingHello(
            publicKey: localIdentity.publicKey.rawRepresentation,
            deviceName: deviceName
        )
        try await channel.send(
            FrameEncoder.encode(
                Frame(kind: .pairResponse, streamID: Multiplexer.controlStreamID, payload: ours.encoded())
            )
        )
    }

}

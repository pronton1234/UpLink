import Foundation
import CryptoKit

public enum PairingError: Error, Equatable, Sendable {
    case invalidCodeFormat
    case expired
    case tooManyAttempts
    case codeMismatch
    case alreadyConsumed
    /// The pairing exchange itself failed — malformed message, or the peer
    /// hung up. A wrong code normally fails earlier, in the TLS handshake.
    case handshakeFailed
}

extension PairingError {

    /// A stable byte for the wire, deliberately not the enum's declaration
    /// order: reordering the cases must not silently change what a peer is
    /// told, and an older build must not misread a newer one's refusal.
    public var wireCode: UInt8 {
        switch self {
        case .invalidCodeFormat: 1
        case .expired: 2
        case .tooManyAttempts: 3
        case .codeMismatch: 4
        case .alreadyConsumed: 5
        case .handshakeFailed: 6
        }
    }

    /// Unknown codes become `handshakeFailed` rather than nil: a peer that
    /// refuses for a reason this build has never heard of has still refused,
    /// and saying so beats reporting nothing.
    public init(wireCode: UInt8) {
        switch wireCode {
        case 1: self = .invalidCodeFormat
        case 2: self = .expired
        case 3: self = .tooManyAttempts
        case 4: self = .codeMismatch
        case 5: self = .alreadyConsumed
        default: self = .handshakeFailed
        }
    }
}

/// The six-digit number the Mac shows and the user types on the phone.
///
/// Six digits is ~20 bits — far too weak to be a long-term secret, and it is
/// never used as one. It authenticates exactly one short-lived pairing session,
/// inside which the two devices exchange 256-bit Curve25519 identities that do
/// all subsequent work. See ``KeySchedule`` for the security note on this
/// trade-off.
public struct PairingCode: Sendable, Equatable {

    public static let length = 6

    public let digits: String

    public init(digits: String) throws {
        guard digits.count == Self.length else { throw PairingError.invalidCodeFormat }
        // `isNumber` would accept "１２３４５６" (fullwidth) and other Unicode
        // numerics, which would then not match what the Mac displayed. Restrict
        // to ASCII 0-9 so both devices agree on what a digit is.
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw PairingError.invalidCodeFormat
        }
        self.digits = digits
    }

    public static func random() -> PairingCode {
        // SystemRandomNumberGenerator is a CSPRNG. `arc4random_uniform`-style
        // range selection avoids the modulo bias that `% 1_000_000` would
        // introduce — bias here would shrink the effective search space.
        let value = UInt32.random(in: 0 ..< 1_000_000)
        let padded = String(format: "%06u", value)
        // Construction cannot fail: the format guarantees six ASCII digits.
        return try! PairingCode(digits: padded)
    }

    /// Constant-time comparison.
    ///
    /// Codes are short and an attacker gets only three tries, so a timing side
    /// channel is not the likeliest attack — but comparing secrets in variable
    /// time is the kind of thing that is free to get right and awkward to
    /// retrofit once something else starts using this type.
    public static func == (lhs: PairingCode, rhs: PairingCode) -> Bool {
        let a = Array(lhs.digits.utf8), b = Array(rhs.digits.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for i in 0 ..< a.count { difference |= a[i] ^ b[i] }
        return difference == 0
    }
}

/// One pairing attempt window on the Mac.
///
/// Tracks the three controls that make a six-digit secret defensible: it stops
/// being valid after ``validity`` seconds, it tolerates only ``maxAttempts``
/// guesses, and it can only ever succeed once.
public struct PairingSession: Sendable {

    /// Long enough for a user to walk to their Mac and read the screen, short
    /// enough that an unattended code is not a standing invitation.
    public static let validity: TimeInterval = 60

    /// Three guesses out of 10^6 is a 3-in-a-million chance per pairing window.
    public static let maxAttempts = 3

    private let code: PairingCode
    private let issuedAt: Date
    private var attemptsUsed = 0
    private var consumed = false

    public init(code: PairingCode, issuedAt: Date) {
        self.code = code
        self.issuedAt = issuedAt
    }

    public var attemptsRemaining: Int { Self.maxAttempts - attemptsUsed }

    /// Checks a candidate code.
    ///
    /// Order matters. Consumption and lockout are checked before expiry, and
    /// expiry before the comparison, so that a caller can never learn anything
    /// about the code itself from a session that is already finished.
    public mutating func verify(_ candidate: PairingCode, at now: Date) throws {
        guard !consumed else { throw PairingError.alreadyConsumed }
        guard attemptsUsed < Self.maxAttempts else { throw PairingError.tooManyAttempts }
        guard now.timeIntervalSince(issuedAt) <= Self.validity else { throw PairingError.expired }

        attemptsUsed += 1

        guard candidate == code else { throw PairingError.codeMismatch }

        consumed = true
    }
}

/// Derives every symmetric key the bridge uses.
///
/// **Security note, stated plainly.** The pairing key is derived from a
/// six-digit code, so an attacker who captures the pairing handshake can mount
/// an offline dictionary attack over 10^6 candidates and recover it. CryptoKit
/// ships no PAKE (SPAKE2/OPAQUE), which is what would close this properly.
/// What limits the damage:
///
/// - The window is 60 seconds and the code is single-use, so the attacker must
///   already be capturing at the moment the user pairs.
/// - Recovering the pairing key yields only that session. The long-term key is
///   a Curve25519 ECDH shared secret exchanged inside it, and knowing the
///   pairing key does not yield the private scalars.
/// - Every later session authenticates with the 256-bit key, not the code.
///
/// If this ever needs to withstand a determined attacker on a hostile network,
/// the fix is a real PAKE, not a longer code.
public enum KeySchedule {

    private static let pairingInfo = Data("uplink.pairing.v1".utf8)
    private static let sessionInfo = Data("uplink.session.v1".utf8)

    /// Stretches the human-typed code into a symmetric key for the pairing
    /// session's TLS-PSK.
    public static func pairingKey(code: PairingCode, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(code.digits.utf8)),
            salt: salt,
            info: pairingInfo,
            outputByteCount: 32
        )
    }

    /// The long-term key for a paired Mac/phone, from an X25519 agreement.
    ///
    /// `context` binds the key to a purpose, so the same device pair cannot be
    /// tricked into reusing one key across two different roles.
    public static func sessionKey(
        localPrivate: Curve25519.KeyAgreement.PrivateKey,
        remotePublic: Curve25519.KeyAgreement.PublicKey,
        context: Data
    ) throws -> SymmetricKey {
        let shared = try localPrivate.sharedSecretFromKeyAgreement(with: remotePublic)
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: sessionInfo,
            sharedInfo: context,
            outputByteCount: 32
        )
    }
}

/// Proves that the device announcing a fingerprint in `HELLO` is the device
/// that fingerprint belongs to.
///
/// **The gap this closes.** The listener holds one TLS-PSK per paired peer and
/// TLS selects among them by the identity the client offers. A peer that is
/// paired can therefore complete the handshake honestly with *its own* key and
/// then announce *someone else's* fingerprint in `HELLO` — nothing cross-checked
/// the application-layer claim against the key actually used. On the phone that
/// claim decides which Mac is shown as connected and, worse, which pairing an
/// `unpair` over that session applies to.
///
/// **Why not the TLS layer.** The obvious fix, and the one this codebase
/// previously recorded as the plan, was
/// `sec_protocol_options_set_pre_shared_key_selection_block` on the listener.
/// Reading the SDK header shows that block is invoked *"when the client must
/// choose a PSK identity given a hint from its peer"* — it is a client-side
/// selection hook receiving the server's identity **hint**, not a server-side
/// observer of the client's identity. It cannot answer the question.
///
/// So the binding is done here instead, where it is one HMAC and can be proven
/// without a device. Only the holder of the private key behind `fingerprint`
/// can derive the session key, so only that device can produce this tag.
///
/// **Honest limit.** The tag is deterministic rather than nonce-bound, so it
/// costs no extra round trip on a link where the Mac must speak first. That
/// makes it replayable *in principle* — but only by someone who has seen it,
/// and it travels inside a TLS session whose key is the very secret being
/// proven. A different paired peer never observes it. A nonce would close even
/// that, at the price of a round trip and a fourth handshake frame.
public enum HelloProof {

    private static let context = Data("uplink.hello.bind.v2".utf8)

    /// The tag `dialer` sends, bound to both identities so it cannot be
    /// replayed at a different listener.
    public static func tag(
        sessionKey: SymmetricKey,
        dialerFingerprint: String,
        listenerFingerprint: String
    ) -> Data {
        var message = context
        message.append(Data(dialerFingerprint.utf8))
        message.append(0x00)
        message.append(Data(listenerFingerprint.utf8))
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: sessionKey))
    }

    /// Constant-time check. `HMAC.isValidAuthenticationCode` does the
    /// comparison without leaking where two tags first differ.
    public static func verify(
        _ candidate: Data,
        sessionKey: SymmetricKey,
        dialerFingerprint: String,
        listenerFingerprint: String
    ) -> Bool {
        var message = context
        message.append(Data(dialerFingerprint.utf8))
        message.append(0x00)
        message.append(Data(listenerFingerprint.utf8))
        return HMAC<SHA256>.isValidAuthenticationCode(
            candidate, authenticating: message, using: sessionKey
        )
    }
}

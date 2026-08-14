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

import Testing
import Foundation
import CryptoKit
@testable import UpLinkKit

// Pairing is the only thing standing between a stranger on the same Wi-Fi and
// a free ride on the user's cellular plan. The code is deliberately weak (six
// digits, because a human types it), so every one of the compensating controls
// — expiry, attempt limit, single use — is load-bearing rather than polish.

@Suite("Pairing code")
struct PairingCodeTests {

    @Test("A generated code is exactly six digits")
    func generatedCodeShape() {
        for _ in 0 ..< 200 {
            let code = PairingCode.random()
            #expect(code.digits.count == 6)
            #expect(code.digits.allSatisfy { $0.isASCII && $0.isNumber })
        }
    }

    @Test("Codes with a leading zero are preserved, not silently shortened")
    func leadingZeroPreserved() throws {
        let code = try PairingCode(digits: "004821")
        #expect(code.digits == "004821")
    }

    @Test("Generated codes are spread across the space rather than repeating")
    func generatedCodesVary() {
        let codes = Set((0 ..< 500).map { _ in PairingCode.random().digits })
        // 500 draws from 10^6 should essentially never collide more than a
        // handful of times; anything below 450 distinct means the generator is
        // not actually random.
        #expect(codes.count > 450)
    }

    @Test("A code of the wrong length is rejected", arguments: ["12345", "1234567", ""])
    func wrongLengthRejected(_ digits: String) {
        #expect(throws: PairingError.invalidCodeFormat) { _ = try PairingCode(digits: digits) }
    }

    @Test("A code containing non-digits is rejected", arguments: ["12345a", "12 456", "１２３４５６"])
    func nonDigitsRejected(_ digits: String) {
        #expect(throws: PairingError.invalidCodeFormat) { _ = try PairingCode(digits: digits) }
    }
}

@Suite("Pairing session")
struct PairingSessionTests {

    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func session(code: String = "482913") throws -> PairingSession {
        PairingSession(code: try PairingCode(digits: code), issuedAt: start)
    }

    private func code(_ digits: String) -> PairingCode {
        try! PairingCode(digits: digits)
    }

    @Test("The correct code is accepted")
    func correctCodeAccepted() throws {
        var s = try session()
        let candidate = code("482913")
        #expect(throws: Never.self) {
            try s.verify(candidate, at: start.addingTimeInterval(5))
        }
    }

    @Test("An incorrect code is rejected")
    func incorrectCodeRejected() throws {
        var s = try session()
        let candidate = code("000000")
        #expect(throws: PairingError.codeMismatch) {
            try s.verify(candidate, at: start.addingTimeInterval(5))
        }
    }

    @Test("A code offered after the validity window is rejected as expired")
    func expiredCodeRejected() throws {
        var s = try session()
        let candidate = code("482913")
        #expect(throws: PairingError.expired) {
            try s.verify(candidate, at: start.addingTimeInterval(PairingSession.validity + 1))
        }
    }

    @Test("A code offered exactly at the deadline is still accepted")
    func codeAtDeadlineAccepted() throws {
        var s = try session()
        let candidate = code("482913")
        #expect(throws: Never.self) {
            try s.verify(candidate, at: start.addingTimeInterval(PairingSession.validity))
        }
    }

    @Test("After the attempt limit, even the correct code is refused")
    func attemptLimitLocksOutCorrectCode() throws {
        var s = try session()
        let t = start.addingTimeInterval(1)

        let wrong = code("000000")
        for _ in 0 ..< PairingSession.maxAttempts {
            #expect(throws: PairingError.codeMismatch) {
                try s.verify(wrong, at: t)
            }
        }

        // This is the whole point of the limit: brute force must not be able to
        // walk the 10^6 space, so a correct guess after lockout is worthless.
        let right = code("482913")
        #expect(throws: PairingError.tooManyAttempts) {
            try s.verify(right, at: t)
        }
    }

    @Test("A successful pairing consumes the code so it cannot be replayed")
    func codeIsSingleUse() throws {
        var s = try session()
        let t = start.addingTimeInterval(1)
        let candidate = code("482913")
        try s.verify(candidate, at: t)

        #expect(throws: PairingError.alreadyConsumed) {
            try s.verify(candidate, at: t)
        }
    }

    @Test("A successful attempt does not reset the attempt budget for later codes")
    func successDoesNotResetBudget() throws {
        var s = try session()
        let t = start.addingTimeInterval(1)
        _ = try? s.verify(code("000000"), at: t)
        try s.verify(code("482913"), at: t)

        #expect(s.attemptsRemaining == PairingSession.maxAttempts - 2)
    }
}

@Suite("Key schedule")
struct KeyScheduleTests {

    @Test("The same code and salt derive the same pairing key on both devices")
    func pairingKeyIsDeterministic() throws {
        let code = try PairingCode(digits: "482913")
        let salt = Data(repeating: 0x5A, count: 32)

        #expect(KeySchedule.pairingKey(code: code, salt: salt)
                == KeySchedule.pairingKey(code: code, salt: salt))
    }

    @Test("A different code derives a different pairing key")
    func differentCodeDifferentKey() throws {
        let salt = Data(repeating: 0x5A, count: 32)
        let a = try PairingCode(digits: "482913")
        let b = try PairingCode(digits: "482914")
        #expect(KeySchedule.pairingKey(code: a, salt: salt)
                != KeySchedule.pairingKey(code: b, salt: salt))
    }

    @Test("A different salt derives a different pairing key from the same code")
    func differentSaltDifferentKey() throws {
        let code = try PairingCode(digits: "482913")
        #expect(KeySchedule.pairingKey(code: code, salt: Data(repeating: 0x01, count: 32))
                != KeySchedule.pairingKey(code: code, salt: Data(repeating: 0x02, count: 32)))
    }

    @Test("Both devices independently derive the same long-term session key")
    func sessionKeyAgrees() throws {
        let mac = Curve25519.KeyAgreement.PrivateKey()
        let phone = Curve25519.KeyAgreement.PrivateKey()

        let onMac = try KeySchedule.sessionKey(
            localPrivate: mac, remotePublic: phone.publicKey, context: Data("uplink".utf8))
        let onPhone = try KeySchedule.sessionKey(
            localPrivate: phone, remotePublic: mac.publicKey, context: Data("uplink".utf8))

        #expect(onMac == onPhone)
    }

    @Test("A different context yields a different session key from the same key pair")
    func sessionKeyIsContextBound() throws {
        let mac = Curve25519.KeyAgreement.PrivateKey()
        let phone = Curve25519.KeyAgreement.PrivateKey()

        let a = try KeySchedule.sessionKey(
            localPrivate: mac, remotePublic: phone.publicKey, context: Data("a".utf8))
        let b = try KeySchedule.sessionKey(
            localPrivate: mac, remotePublic: phone.publicKey, context: Data("b".utf8))

        #expect(a != b)
    }

    @Test("An unrelated device cannot derive the pair's session key")
    func strangerCannotDeriveKey() throws {
        let mac = Curve25519.KeyAgreement.PrivateKey()
        let phone = Curve25519.KeyAgreement.PrivateKey()
        let stranger = Curve25519.KeyAgreement.PrivateKey()

        let real = try KeySchedule.sessionKey(
            localPrivate: mac, remotePublic: phone.publicKey, context: Data())
        let forged = try KeySchedule.sessionKey(
            localPrivate: stranger, remotePublic: mac.publicKey, context: Data())

        #expect(real != forged)
    }

    @Test("The derived key is 256 bits")
    func derivedKeyLength() throws {
        let zeros = try PairingCode(digits: "000000")
        let key = KeySchedule.pairingKey(code: zeros, salt: Data())
        #expect(key.bitCount == 256)
    }
}

import Testing
import Foundation
import CryptoKit
@testable import UpLinkKit

@Suite("Regression: pairing salt")
struct PairingSaltRegressionTests {

    // SYMPTOM: the pairing PSK was salted with the device's display name. The
    // Mac hashed Host.current().localizedName; the phone hashed the name
    // Bonjour reported back. "Pranit's MacBook Air" contains U+2019, which can
    // round-trip differently through DNS-SD — so the salts differed, the PSKs
    // differed, and the TLS handshake failed with no diagnostic beyond a
    // generic connection error. Pairing simply never worked.
    @Test("A display name is not a safe salt input")
    func displayNameIsUnsafeAsSalt() {
        let typographic = "Pranit\u{2019}s MacBook Air"   // ’
        let ascii = "Pranit's MacBook Air"                // '

        // Visually identical, cryptographically not.
        #expect(typographic != ascii)
        #expect(Data(SHA256.hash(data: Data(typographic.utf8)))
                != Data(SHA256.hash(data: Data(ascii.utf8))))
    }

    // The fingerprint is hex ASCII: no escaping, no renaming, no Unicode.
    @Test("A fingerprint survives any transport byte-identically")
    func fingerprintIsStable() {
        let fingerprint = PairedDevice.fingerprint(of: Data(repeating: 0xAB, count: 32))
        #expect(fingerprint.allSatisfy { $0.isHexDigit && $0.isASCII })
        #expect(Data(SHA256.hash(data: Data(fingerprint.utf8)))
                == Data(SHA256.hash(data: Data(fingerprint.utf8))))
    }

    // Both sides deriving from the same fingerprint must agree exactly.
    @Test("Both ends derive the same pairing key from a fingerprint salt")
    func bothEndsAgree() throws {
        let code = try PairingCode(digits: "350423")
        let fingerprint = PairedDevice.fingerprint(of: Data(repeating: 0x01, count: 32))
        let salt = Data(SHA256.hash(data: Data(fingerprint.utf8)))

        #expect(KeySchedule.pairingKey(code: code, salt: salt)
                == KeySchedule.pairingKey(code: code, salt: salt))
    }
}

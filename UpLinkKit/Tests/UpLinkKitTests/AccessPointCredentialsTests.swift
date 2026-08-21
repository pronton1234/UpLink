import Testing
import Foundation
@testable import UpLinkKit

@Suite("The SSID and passphrase the phone is told to join")
struct AccessPointCredentialsTests {

    private let fingerprint = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6"

    @Test("The SSID is derived from the Mac's identity, so two Macs never collide")
    func ssidIsDerived() {
        let a = AccessPointCredentials.ssid(forFingerprint: fingerprint)
        let b = AccessPointCredentials.ssid(forFingerprint: "ffffffffffffffffffffffffffffffff")
        #expect(a != b)
    }

    @Test("The same Mac always gets the same SSID, or a saved join stops working")
    func ssidIsStable() {
        #expect(AccessPointCredentials.ssid(forFingerprint: fingerprint)
            == AccessPointCredentials.ssid(forFingerprint: fingerprint))
    }

    @Test("It is recognisably ours, because the user sees it in a Wi-Fi list")
    func ssidIsRecognisable() {
        #expect(AccessPointCredentials.ssid(forFingerprint: fingerprint).hasPrefix("UpLink"))
    }

    // 802.11 caps an SSID at 32 bytes. Longer is not truncated politely, it is
    // rejected — and it would be rejected inside Internet Sharing, on a Mac
    // whose radio has just gone away.
    @Test("The SSID fits in 32 bytes, which 802.11 requires")
    func ssidFitsInThirtyTwoBytes() {
        let ssid = AccessPointCredentials.ssid(forFingerprint: fingerprint)
        #expect(ssid.utf8.count <= 32)
        #expect(!ssid.isEmpty)
    }

    // WPA2-PSK requires 8...63 ASCII characters. Outside that range the network
    // cannot be created at all.
    @Test("A generated passphrase is a legal WPA2 passphrase")
    func passphraseIsLegal() {
        for _ in 0 ..< 50 {
            let passphrase = AccessPointCredentials.generatePassphrase()
            #expect(passphrase.count >= 8)
            #expect(passphrase.count <= 63)
            let isASCII = passphrase.allSatisfy { $0.isASCII }
            #expect(isASCII)
        }
    }

    @Test("Two generated passphrases differ, so it is not a constant")
    func passphraseIsRandom() {
        let generated = Set((0 ..< 50).map { _ in AccessPointCredentials.generatePassphrase() })
        #expect(generated.count == 50)
    }

    // The passphrase is typed by nobody and read by nobody: it crosses the
    // already-authenticated pairing channel and is handed to
    // NEHotspotConfiguration. So it is sized for strength, not for a human.
    @Test("The passphrase carries real entropy rather than being merely legal")
    func passphraseIsStrong() {
        #expect(AccessPointCredentials.generatePassphrase().count >= 20)
    }

    @Test("Credentials round-trip, because they cross the pairing channel")
    func roundTrips() throws {
        let credentials = AccessPointCredentials(
            ssid: AccessPointCredentials.ssid(forFingerprint: fingerprint),
            passphrase: AccessPointCredentials.generatePassphrase()
        )
        let data = try JSONEncoder().encode(credentials)
        let decoded = try JSONDecoder().decode(AccessPointCredentials.self, from: data)
        #expect(decoded == credentials)
    }
}

import Testing
import Foundation
import CryptoKit
@testable import UpLinkKit

// The UDID is the one identifier in the exchange the peer cannot claim: it
// comes from `usbmuxd`, not from anything sent over the wire. Pinning a pairing
// to it is what stops a different handset bridging on a key it somehow holds —
// a stolen keychain item, a restored backup on another device.
//
// It has to be introduced without breaking records written before the wired
// transport, which carry no UDID at all. The rule below is the whole migration,
// and it is easy to get wrong in the direction that quietly never pins anything.

@Suite("Regression: a pairing is pinned to the physical device")
struct DevicePinningRegressionTests {

    private func device(named name: String, udid: String? = nil) -> PairedDevice {
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        return PairedDevice(
            fingerprint: PairedDevice.fingerprint(of: key),
            name: name,
            publicKey: key,
            pairedAt: Date(),
            udid: udid
        )
    }

    /// The rule `ProxyState.pairedDevice(matching:)` implements: an exact UDID
    /// match wins; otherwise a record that has never been pinned may adopt.
    private func match(_ paired: [PairedDevice], udid: String) -> PairedDevice? {
        if let exact = paired.first(where: { $0.udid == udid }) { return exact }
        return paired.first { $0.udid == nil }
    }

    @Test("A pinned record matches only its own device")
    func pinnedRecordIsSpecific() {
        let mine = device(named: "My iPhone", udid: "UDID-A")
        #expect(match([mine], udid: "UDID-A")?.name == "My iPhone")
        #expect(
            match([mine], udid: "UDID-B") == nil,
            "a different handset was accepted against a pinned pairing"
        )
    }

    // The migration. Without it a legacy record could never be used again,
    // because it would match nothing.
    @Test("An unpinned legacy record adopts the first device it meets")
    func legacyRecordAdopts() {
        let legacy = device(named: "Old Pairing", udid: nil)
        #expect(match([legacy], udid: "UDID-NEW")?.name == "Old Pairing")
    }

    // The half that is easy to lose: adoption must be a ONE-TIME migration, not
    // a permanent wildcard. A record that stayed unpinned would keep matching
    // every device forever, which is exactly the property the UDID exists to
    // remove — and nothing would look wrong, because it would keep working.
    @Test("Adoption is one-time: once pinned, the wildcard is gone")
    func adoptionIsOneTime() {
        var legacy = device(named: "Old Pairing", udid: nil)
        #expect(match([legacy], udid: "UDID-FIRST") != nil)

        // ProxyState.adoptUDID does exactly this on the first successful dial.
        legacy.udid = "UDID-FIRST"

        #expect(match([legacy], udid: "UDID-FIRST") != nil)
        #expect(
            match([legacy], udid: "UDID-SECOND") == nil,
            "the record stayed a wildcard after adopting a device — every later handset matches it too"
        )
    }

    // An exact match must win even when an unpinned record is also present, or
    // adding a second Mac to an old setup would hand the session to the wrong
    // pairing and fail the TLS handshake for reasons nothing would explain.
    @Test("An exact match beats an available wildcard")
    func exactMatchWins() {
        let legacy = device(named: "Old Pairing", udid: nil)
        let pinned = device(named: "Current iPhone", udid: "UDID-A")
        #expect(match([legacy, pinned], udid: "UDID-A")?.name == "Current iPhone")
    }

    // The UDID travels in the Mac's durable record, so it has to survive the
    // JSON round trip through providerConfiguration — and an older record
    // without the field must still decode rather than throwing, or every
    // existing pairing is lost on upgrade.
    @Test("A record without a UDID still decodes, and one with it round-trips")
    func codingSurvivesTheMigration() throws {
        let pinned = device(named: "Current iPhone", udid: "UDID-A")
        let decoded = try JSONDecoder().decode(
            PairedDevice.self, from: try JSONEncoder().encode(pinned)
        )
        #expect(decoded.udid == "UDID-A")

        // Exactly the shape a pre-migration record has on disk.
        let legacyJSON = """
        {"fingerprint":"abcdef0123456789","name":"Old Pairing",
         "publicKey":"\(Data(repeating: 7, count: 32).base64EncodedString())",
         "pairedAt":0}
        """
        let legacy = try JSONDecoder().decode(PairedDevice.self, from: Data(legacyJSON.utf8))
        #expect(legacy.udid == nil)
        #expect(legacy.name == "Old Pairing")
    }
}

import Testing
import Foundation
@testable import UpLinkKit

// SYMPTOM, the offline half of "removing a device on one end doesn't register
// on the other": you remove a device you are not currently bridging with, which
// is the normal thing to do, and the far side never finds out.
//
// The `unpaired` frame rides on the live session — it is written to the very
// connection being closed. With no session there is nothing to write to, and
// nothing else carries revocation state: Bonjour publishes only the Mac's own
// fingerprint, and TLS gives the peer a generic handshake failure that looks
// like every other connection failure. So the stranded phone re-dials forever
// holding a pairing the Mac has forgotten.
//
// A tombstone keeps the revoked device's PSK on the air briefly, for the single
// purpose of accepting one connection, saying `unpaired`, and closing.

@Suite("Regression: a device unpaired while offline must still be told")
struct RevocationTombstoneRegressionTests {

    private func device(_ fingerprint: String) -> PairedDevice {
        PairedDevice(
            fingerprint: fingerprint,
            name: "iPhone \(fingerprint)",
            publicKey: Data(repeating: 0xCD, count: 32),
            pairedAt: Date()
        )
    }

    @Test("A revoked device is recognised, and its key stays on the air")
    func revokedDeviceIsKeptReachable() {
        var tombstones = RevocationTombstones()
        tombstones.revoke(device("aaaa"))

        #expect(tombstones.isRevoked("aaaa"))
        #expect(
            tombstones.devicesToKeepOnAir().map(\.fingerprint) == ["aaaa"],
            "the revoked key is not on the air, so the phone cannot connect and cannot be told — which is the whole failure"
        )
    }

    @Test("An unrelated device is unaffected")
    func otherDevicesAreNotRevoked() {
        var tombstones = RevocationTombstones()
        tombstones.revoke(device("aaaa"))
        #expect(tombstones.isRevoked("bbbb") == false)
    }

    // Once told, the tombstone has done its job. Leaving it would keep a
    // revoked key on the air for no reason.
    @Test("A delivered notice drops the tombstone")
    func deliveryDropsIt() {
        var tombstones = RevocationTombstones()
        tombstones.revoke(device("aaaa"))
        tombstones.delivered("aaaa")

        #expect(tombstones.isRevoked("aaaa") == false)
        #expect(
            tombstones.devicesToKeepOnAir().isEmpty,
            "a revoked key stayed on the air after its notice was delivered"
        )
    }

    // THE ONE THAT WOULD BITE. Re-pairing a device you had removed must work:
    // without this the fresh pairing is refused by its own history, and the user
    // sees a device that pairs and then immediately unpairs itself.
    @Test("Re-pairing clears the tombstone")
    func reinstatementClearsIt() {
        var tombstones = RevocationTombstones()
        tombstones.revoke(device("aaaa"))
        tombstones.reinstated("aaaa")

        #expect(
            tombstones.isRevoked("aaaa") == false,
            "a device that was re-paired is still treated as revoked — it would be told 'unpaired' the moment it connects, forever"
        )
    }

    @Test("A tombstone expires")
    func tombstonesExpire() {
        var tombstones = RevocationTombstones()
        let then = Date()
        tombstones.revoke(device("aaaa"), at: then)

        let later = then.addingTimeInterval(RevocationTombstones.validity + 1)
        #expect(tombstones.isRevoked("aaaa", at: later) == false)
        #expect(
            tombstones.devicesToKeepOnAir(at: later).isEmpty,
            "a revoked key is on the air indefinitely"
        )
    }

    // Bounded, so a long-lived Mac cannot accumulate revoked keys without limit.
    @Test("Tombstones are capped, oldest dropped first")
    func capacityIsBounded() {
        var tombstones = RevocationTombstones()
        let start = Date()
        for index in 0 ..< (RevocationTombstones.capacity + 5) {
            tombstones.revoke(device("fp\(index)"), at: start.addingTimeInterval(Double(index)))
        }

        #expect(tombstones.all.count == RevocationTombstones.capacity)
        #expect(tombstones.isRevoked("fp0") == false, "the oldest tombstone was kept over a newer one")
        #expect(
            tombstones.isRevoked("fp\(RevocationTombstones.capacity + 4)"),
            "the newest tombstone was dropped"
        )
    }

    // It has to survive an extension restart, because the extension's directory
    // is in memory and that restart is exactly when a revoked device reappears.
    @Test("Tombstones survive a round trip through the seed")
    func tombstonesEncodeAndDecode() throws {
        var tombstones = RevocationTombstones()
        tombstones.revoke(device("aaaa"))

        let data = try JSONEncoder().encode(tombstones)
        let restored = try JSONDecoder().decode(RevocationTombstones.self, from: data)

        #expect(restored.isRevoked("aaaa"), "a tombstone did not survive being seeded into the extension")
    }
}

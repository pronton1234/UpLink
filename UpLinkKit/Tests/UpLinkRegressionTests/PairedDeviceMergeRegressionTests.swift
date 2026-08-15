import Testing
import Foundation
@testable import UpLinkKit

// SYMPTOM: "I am removing devices from one end, it is not auto-updating on the
// other" — and on the Mac specifically, a removed device coming back.
//
// The Mac app's keychain is durable; the extension's directory is in memory and
// re-seeded from a snapshot written once per app launch. The app polls the
// extension and treats anything the extension knows that it does not as a new
// pairing, writing it to the keychain.
//
// That additive rule undoes removals two different ways:
//
//   1. It races the Remove button. The poll sends its request, the user removes
//      a device, the reply arrives still listing it — so it is "unknown" and
//      gets written straight back, and the row reappears.
//   2. It re-adds resurrections. The extension restarts, re-seeds from a stale
//      snapshot containing the removed device, and the next poll copies it back
//      into the keychain. Neither the user nor the log shows anything.

@Suite("Regression: a removed device must not be re-learned")
struct PairedDeviceMergeRegressionTests {

    private func device(_ fingerprint: String) -> PairedDevice {
        PairedDevice(
            fingerprint: fingerprint,
            name: "iPhone \(fingerprint)",
            publicKey: Data(repeating: 0xAB, count: 32),
            pairedAt: Date()
        )
    }

    @Test("A genuinely new pairing is persisted")
    func newPairingIsLearned() {
        let merge = PairedDeviceMerge()
        let fresh = merge.devicesToPersist(
            reportedByExtension: [device("aaaa")],
            alreadyKnown: []
        )
        #expect(fresh.map(\.fingerprint) == ["aaaa"], "a new pairing was not persisted")
    }

    @Test("A device already known is not written again")
    func knownDeviceIsSkipped() {
        let merge = PairedDeviceMerge()
        let fresh = merge.devicesToPersist(
            reportedByExtension: [device("aaaa")],
            alreadyKnown: ["aaaa"]
        )
        #expect(fresh.isEmpty)
    }

    // The race. The extension's reply was composed BEFORE the removal, so the
    // device is both absent from `alreadyKnown` and present in the reply —
    // indistinguishable from a new pairing without this.
    @Test("A device removed while the poll was in flight is not re-learned")
    func removalDuringPollIsRespected() {
        var merge = PairedDeviceMerge()
        merge.noteRemoved("aaaa")

        let fresh = merge.devicesToPersist(
            reportedByExtension: [device("aaaa")],
            alreadyKnown: []
        )
        #expect(
            fresh.isEmpty,
            "a device removed during the poll's own round trip was written back to the keychain — the row reappears and the removal looks ignored"
        )
    }

    // The resurrection. Same shape, different cause: the extension restarted and
    // re-seeded from a snapshot still containing the device.
    @Test("A resurrected device is not re-learned")
    func resurrectionIsRespected() {
        var merge = PairedDeviceMerge()
        merge.noteRemoved("aaaa")

        let fresh = merge.devicesToPersist(
            reportedByExtension: [device("aaaa"), device("bbbb")],
            alreadyKnown: []
        )
        #expect(
            fresh.map(\.fingerprint) == ["bbbb"],
            "the removed device came back, or a genuinely new one was blocked"
        )
    }

    // Deliberately re-pairing the same device must work at once. The user has
    // just said they want it, which outranks having said the opposite earlier.
    @Test("Re-pairing the same device immediately is allowed")
    func rePairingClearsTheBlock() {
        var merge = PairedDeviceMerge()
        merge.noteRemoved("aaaa")
        merge.notePaired("aaaa")

        let fresh = merge.devicesToPersist(
            reportedByExtension: [device("aaaa")],
            alreadyKnown: []
        )
        #expect(
            fresh.map(\.fingerprint) == ["aaaa"],
            "re-pairing a device you had removed does not take effect — which is the very flow being fixed"
        )
    }

    // The block must not be permanent, or a device removed once could never be
    // learned again through the normal path.
    @Test("The block expires")
    func blockExpires() {
        var merge = PairedDeviceMerge()
        let removedAt = Date()
        merge.noteRemoved("aaaa", at: removedAt)

        let later = removedAt.addingTimeInterval(PairedDeviceMerge.forgetWindow + 1)
        let fresh = merge.devicesToPersist(
            reportedByExtension: [device("aaaa")],
            alreadyKnown: [],
            at: later
        )
        #expect(fresh.map(\.fingerprint) == ["aaaa"], "the removal block never expires")
    }
}

import Testing
import Foundation
import Network
@testable import UpLinkKit

// SYMPTOM: the phone shows a green "Paired" seal against a Mac it has never
// paired with — and, worse, against one whose pairing is stale and failing.
//
// `isKnown` was `fingerprint != nil`, which asks "does this Mac publish an
// identity in its TXT record?" Every UpLink Mac does; that is how discovery
// works at all. Nothing in the iOS list cross-referenced the paired store, so
// the label was decorative and actively misleading in the one situation where
// the user most needs to know: a pairing the Mac has forgotten.

@Suite("Regression: 'Paired' must mean paired")
struct PeerPairedLabelRegressionTests {

    private func peer(fingerprint: String?) -> DiscoveredPeer {
        DiscoveredPeer(
            id: "mac",
            name: "Some Mac",
            endpoint: .hostPort(host: "169.254.1.1", port: 1234),
            fingerprint: fingerprint,
            profile: .peerToPeer
        )
    }

    private func paired(_ fingerprint: String) -> PairedDevice {
        PairedDevice(
            fingerprint: fingerprint,
            name: "Mac",
            publicKey: Data(repeating: 0x11, count: 32),
            pairedAt: Date()
        )
    }

    @Test("A Mac this phone has paired with is paired")
    func pairedMacIsPaired() {
        #expect(peer(fingerprint: "aaaa").isPaired(with: [paired("aaaa")]))
    }

    @Test("A Mac this phone has never paired with is not")
    func strangeMacIsNotPaired() {
        #expect(
            peer(fingerprint: "bbbb").isPaired(with: [paired("aaaa")]) == false,
            "a Mac this phone has never paired with is labelled Paired — which is exactly what happens while a stale pairing is failing, so the label misleads precisely when it matters"
        )
    }

    @Test("A Mac whose pairing was removed is no longer paired")
    func removedMacIsNotPaired() {
        #expect(peer(fingerprint: "aaaa").isPaired(with: []) == false)
    }

    @Test("A Mac publishing no identity is neither paired nor pairable")
    func anonymousMacIsNotPaired() {
        let anonymous = peer(fingerprint: nil)
        #expect(anonymous.isPaired(with: [paired("aaaa")]) == false)
        #expect(anonymous.publishesIdentity == false)
    }
}

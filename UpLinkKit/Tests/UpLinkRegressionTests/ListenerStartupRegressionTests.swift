import Testing
import Foundation
import CryptoKit
@testable import UpLinkKit

@Suite("Regression: listener startup")
struct ListenerStartupRegressionTests {

    private func key(_ identity: String) -> (identity: String, key: SymmetricKey) {
        (identity, SymmetricKey(size: .bits256))
    }

    // SYMPTOM: on a fresh install the Mac has no paired phones and no pairing
    // code, so the listener was built with zero pre-shared keys. A TLS listener
    // with no key material cannot start, so the Mac never advertised over
    // Bonjour — and the phone could therefore never see it in order to BEGIN
    // pairing. A deadlock that only ever showed up on first run, which is
    // exactly the run that has to work.
    @Test("An unpaired Mac with no pairing code still has key material to start with")
    func unpairedMacStillStarts() {
        let keys = TransportParameters.listenerKeySet(sessionKeys: [], pairingKey: nil)
        #expect(keys.count == 1)
        #expect(keys[0].identity == TransportParameters.placeholderIdentity)
    }

    // The placeholder must be unguessable, not a constant — otherwise it is not
    // a placeholder, it is a backdoor that lets anyone bridge through an
    // unpaired Mac.
    @Test("The placeholder key is random per call, not a fixed value")
    func placeholderKeyIsRandom() {
        let first = TransportParameters.listenerKeySet(sessionKeys: [], pairingKey: nil)[0].key
        let second = TransportParameters.listenerKeySet(sessionKeys: [], pairingKey: nil)[0].key
        #expect(first != second)
    }

    @Test("The placeholder disappears as soon as there is a real key")
    func placeholderIsNotOfferedAlongsideRealKeys() {
        let paired = TransportParameters.listenerKeySet(
            sessionKeys: [key("aabbccdd")], pairingKey: nil
        )
        #expect(paired.map(\.identity) == ["aabbccdd"])

        let pairing = TransportParameters.listenerKeySet(
            sessionKeys: [], pairingKey: key(TransportParameters.pairingIdentity)
        )
        #expect(pairing.map(\.identity) == [TransportParameters.pairingIdentity])
    }

    // While a code is on screen, an already-paired phone must still be able to
    // reconnect — pairing a second device cannot knock the first one offline.
    @Test("Paired devices and an active pairing code are offered together")
    func pairedDevicesAndPairingCodeCoexist() {
        let keys = TransportParameters.listenerKeySet(
            sessionKeys: [key("aabbccdd"), key("11223344")],
            pairingKey: key(TransportParameters.pairingIdentity)
        )
        #expect(keys.count == 3)
        #expect(keys.contains { $0.identity == "aabbccdd" })
        #expect(keys.contains { $0.identity == TransportParameters.pairingIdentity })
    }
}

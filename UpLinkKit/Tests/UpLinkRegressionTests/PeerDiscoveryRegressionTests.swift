import Testing
import Foundation
import Network
@testable import UpLinkKit

// SYMPTOM, 2026-08-14, and the reason this is a regression suite rather than a
// unit suite: a result cached from before the radio was reconfigured was
// returned unconditionally and treated as current. `peers()` yielded `latest`
// with no expiry, so every retry spent the full connect timeout dialling an
// endpoint that no longer existed — at exactly the moment the device was trying
// to recover.
//
// The method note from that round applies here too. The first version of the
// staleness test used a never-started discovery, whose latest is empty
// regardless, so it went green with the fix deleted. It only became a test once
// the window was injectable and an endpoint was actually observed through a
// seam. Every test below records an endpoint first, deliberately.

@Suite("Regression: a stale peer is not a peer")
struct PeerDiscoveryRegressionTests {

    private let endpoint = NWEndpoint.hostPort(host: "192.168.2.2", port: 51820)
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test("A fresh observation is returned")
    func freshIsReturned() {
        let discovery = PeerDiscovery(stalenessWindow: 10)
        discovery.record(endpoint, at: start)
        #expect(discovery.current(now: start.addingTimeInterval(1)) != nil)
    }

    @Test("An observation older than the window is withheld")
    func staleIsWithheld() {
        let discovery = PeerDiscovery(stalenessWindow: 10)
        discovery.record(endpoint, at: start)
        #expect(discovery.current(now: start.addingTimeInterval(11)) == nil)
    }

    @Test("Re-observing the same endpoint refreshes it rather than ageing out")
    func reobservationRefreshes() {
        let discovery = PeerDiscovery(stalenessWindow: 10)
        discovery.record(endpoint, at: start)
        discovery.record(endpoint, at: start.addingTimeInterval(9))
        #expect(discovery.current(now: start.addingTimeInterval(11)) != nil)
    }

    @Test("With nothing ever observed there is no peer, not a crash")
    func nothingObserved() {
        #expect(PeerDiscovery(stalenessWindow: 10).current(now: start) == nil)
    }

    // A radio change makes every cached endpoint wrong at once, and the browser
    // may take seconds to say so. Forgetting is how the Mac stops dialling a
    // corpse in the meantime.
    @Test("Forgetting drops a peer that is otherwise still fresh")
    func forgettingDropsAFreshPeer() {
        let discovery = PeerDiscovery(stalenessWindow: 10)
        discovery.record(endpoint, at: start)
        discovery.forget()
        #expect(discovery.current(now: start) == nil)
    }

    @Test("The service type is the one both sides agree on")
    func serviceType() {
        #expect(UpLinkIdentifiers.bonjourServiceType == "_uplink._tcp")
    }
}

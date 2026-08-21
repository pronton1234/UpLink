import Testing
import Foundation
import Network
import CryptoKit
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

// SYMPTOM, on hardware 2026-08-20: the phone's listener came up healthy and the
// Mac dialled it for minutes, getting "no connection within 12s" every twelve
// seconds. Both sides were working. They disagreed about the port.
//
// Over the cable the port arrived inside `requiredLocalEndpoint`, which carried
// two facts at once — bind to loopback, and bind to THIS port. Dropping that
// endpoint for the wireless bearer was correct (loopback is unreachable from
// the network the Mac hosts) and silently dropped the port too, so
// `NWListener(using:)` chose an ephemeral one.
//
// The port is one constant both sides read. Anything that lets the listener
// choose its own is this defect again.

@Suite("Regression: both sides agree on one port")
struct ListenerPortRegressionTests {

    @Test("The port the Mac announces is the constant, not a choice")
    func macAnnouncesTheConstant() {
        #expect(UpLinkUSB.extensionPort == 50505)
    }

    // The wireless bearer must NOT carry a requiredLocalEndpoint — that is what
    // pinned it to loopback — so the port cannot come from there and has to be
    // passed to NWListener directly. This asserts the half that is visible from
    // outside: that the parameters do not silently re-pin.
    @Test("The wireless listener carries no endpoint to take the port from")
    func wirelessHasNoEndpointToInferFrom() {
        let parameters = TransportParameters.listener(
            sessionKeys: [("abc", SymmetricKey(size: .bits256))],
            pairingKey: nil,
            port: UpLinkUSB.extensionPort,
            bearer: .hostedAP
        )
        #expect(parameters.requiredLocalEndpoint == nil)
    }

    @Test("The cable listener still carries one, and it names the same port")
    func cableStillPinsTheSamePort() {
        let parameters = TransportParameters.listener(
            sessionKeys: [("abc", SymmetricKey(size: .bits256))],
            pairingKey: nil,
            port: UpLinkUSB.extensionPort,
            bearer: .usbmux
        )
        guard case let .hostPort(_, port)? = parameters.requiredLocalEndpoint else {
            Issue.record("the cable listener lost its endpoint")
            return
        }
        #expect(port.rawValue == UpLinkUSB.extensionPort)
    }
}

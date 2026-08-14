import Testing
import Foundation
import Network
@testable import UpLinkKit

// SYMPTOM: with the Mac's Wi-Fi disconnected from its network — the
// configuration this product exists for — a working AWDL session died and the
// phone could not get back in for a hundred seconds. On the Mac there was
// **zero `accept:`** in that entire window: the phone was not being refused, it
// never dialled at all.
//
// The kernel disables AWDL's timers as the infrastructure link drops:
//
//     15:05:28.688  awdl0: interfaceStateChange: Infra link down, disable dynamic SDB
//     15:05:28.755  disableWorkQueueSources: Disable all AWDL timers
//     15:05:29.088  session ENDED
//
// A session dying across that transition is expected. Never recovering is not,
// and two things in this file guaranteed it:
//
//   1. `NWBrowser` had NO `stateUpdateHandler`. A browser that goes `.failed`
//      when the interface it is scoped to is reconfigured was completely
//      invisible, and `start(on:)` guarded on `browser == nil` so it could not
//      be rebuilt even deliberately. It stayed wedged for the life of the
//      tunnel and `firstMatch` kept returning nil.
//
//   2. `peers()` yielded `latest` unconditionally. After a radio change that is
//      a dead endpoint, returned instantly, and the caller then spends the full
//      twelve-second `connectTimeout` dialling it — every retry, at exactly the
//      moment the device is trying to recover.

@Suite("Regression: discovery must recover from a radio change")
struct DiscoveryRecoveryRegressionTests {

    private let queue = DispatchQueue(label: "regression.discovery")

    // A browser cannot be restarted once it has failed — only replaced. Before
    // the fix `start` short-circuited on `browser == nil`, so nothing could
    // replace it and a single failure was permanent.
    @Test("A browser that fails is replaced, not left wedged")
    func failedBrowserIsRebuilt() async {
        let discovery = PeerDiscovery(profile: .peerToPeer)
        await discovery.start(on: queue)
        let before = await discovery.generation
        #expect(before == 1, "start should have built exactly one browser")

        // The event that actually happens: the interface the browser is scoped
        // to gets reconfigured by a Wi-Fi disconnect, and NWBrowser goes
        // .failed. A failed browser cannot be restarted, only replaced.
        await discovery.simulateBrowserFailureForTesting("posix(ENETDOWN)")

        let after = await discovery.generation
        #expect(
            after > before,
            "a failed browser was not replaced — it is wedged for the life of the tunnel and firstMatch will return nil forever"
        )

        // And it must still serve subscribers afterwards.
        var received = false
        for await _ in await discovery.peers() { received = true; break }
        #expect(received, "discovery stopped serving after the rebuild")

        await discovery.stop()
    }

    @Test("A discovery restart actually rebuilds the browser")
    func restartRebuildsTheBrowser() async {
        let discovery = PeerDiscovery(profile: .peerToPeer)
        await discovery.start(on: queue)

        await discovery.restart()
        await discovery.restart()

        // Three distinct browsers: the original plus one per restart. Before
        // the fix `start` short-circuited on `browser == nil`, so a second
        // build was impossible even when asked for explicitly.
        let generation = await discovery.generation
        #expect(generation == 3, "restart did not build a new browser (generation \(generation), expected 3)")

        await discovery.stop()
    }

    // The staleness rule. A result from before the radio changed is not
    // evidence about the present, and treating it as such costs a 12s connect
    // timeout per attempt against an endpoint that no longer exists.
    @Test("Peers older than the staleness window are not offered")
    func stalePeersAreNotReturned() async throws {
        // A 200ms window so the rule is tested rather than slept through.
        let discovery = PeerDiscovery(profile: .peerToPeer, staleAfter: .milliseconds(200))
        let ghost = DiscoveredPeer(
            id: "ghost",
            name: "Mac that has since gone",
            endpoint: .hostPort(host: "169.254.1.1", port: 1234),
            fingerprint: "deadbeef",
            profile: .peerToPeer
        )
        await discovery.observeForTesting([ghost])

        // Immediately, it is real evidence and must be offered.
        var immediate: [DiscoveredPeer]?
        for await peers in await discovery.peers() { immediate = peers; break }
        #expect(immediate?.count == 1, "a just-seen peer should be offered")

        // After the window it is a ghost, and offering it costs the caller a
        // full 12s connectTimeout dialling something that is not there.
        try await Task.sleep(for: .milliseconds(350))
        var afterwards: [DiscoveredPeer]?
        for await peers in await discovery.peers() { afterwards = peers; break }
        #expect(
            afterwards?.isEmpty == true,
            "discovery offered a stale peer — the caller will dial a ghost and burn its whole timeout"
        )
    }

    // Restarting clears what was seen before. Keeping it would defeat the
    // point: the whole reason to rebuild is that the old view is untrustworthy.
    @Test("A restart forgets what the old browser had seen")
    func restartClearsPreviousResults() async {
        let discovery = PeerDiscovery(profile: .peerToPeer)
        await discovery.start(on: queue)
        await discovery.observeForTesting([
            DiscoveredPeer(
                id: "stale",
                name: "Mac as it was before the radio changed",
                endpoint: .hostPort(host: "169.254.1.1", port: 1234),
                fingerprint: "deadbeef",
                profile: .peerToPeer
            )
        ])
        await discovery.restart()

        let stream = await discovery.peers()
        var seen: [DiscoveredPeer]?
        for await peers in stream { seen = peers; break }

        #expect(seen?.isEmpty == true, "a rebuilt browser is still serving the old browser's results")
        await discovery.stop()
    }
}

import Testing
import Foundation
import Network
@testable import UpLinkKit

// SYMPTOM: the bridge came up over AWDL, carried real traffic, and then died a
// few seconds later — and never came back. The Mac's log shows the session
// ending and then nothing at all, for as long as you care to wait:
//
//     22:33:48 [host]  accept: inbound connection from fe80::…%awdl0.51049
//     22:33:48 [host]  accept: TLS ok, first frame = hello
//     22:33:48 [proxy] session started with 336ee249d249baa4
//     22:33:52 [proxy] session ENDED with 336ee249d249baa4
//     … eight minutes of silence, phone sitting next to the Mac …
//
// No reconnect was ever attempted, so with Wi-Fi off the Mac stayed offline
// until the tunnel was restarted by hand. The drop itself is one bug; this test
// covers the far worse one — that a drop was *unrecoverable*.
//
// CAUSE: `PacketTunnelProvider.firstMatchingPeer` enforced its 15s deadline
// inside `for await peers in discovery.peers()`. That body only runs when the
// browser publishes a new result. `PeerDiscovery.peers()` yields the current
// set once at subscription and then only on change — so when there was nothing
// new to report, the deadline check never ran a second time and the loop
// awaited forever. The reconnect loop in `runSession` sits directly outside it
// and can only retry once it returns, so the whole extension wedged.

@Suite("Regression: a lost peer must not wedge the reconnect loop")
struct PeerWaitRegressionTests {

    private func peer(fingerprint: String) -> DiscoveredPeer {
        DiscoveredPeer(
            id: "mac",
            name: "Mac",
            endpoint: .hostPort(host: "127.0.0.1", port: 1),
            fingerprint: fingerprint,
            profile: .peerToPeer
        )
    }

    /// The exact field failure: the browser reports an empty set once and then
    /// goes quiet forever. This must give up, not hang.
    @Test("A browser that goes silent still times out")
    func silentBrowserTimesOut() async {
        let (stream, continuation) = AsyncStream<[DiscoveredPeer]>.makeStream()
        continuation.yield([])  // one publication at subscription, then silence

        let result = await PeerResolver.firstMatch(
            in: stream,
            fingerprint: "wanted",
            timeout: 0.05,
            sleep: { try await Task.sleep(for: .seconds($0)) }
        )
        #expect(result == nil)
        continuation.finish()
    }

    /// A browser that never publishes at all — not even an empty set.
    @Test("A browser that never publishes still times out")
    func neverPublishingBrowserTimesOut() async {
        let (stream, continuation) = AsyncStream<[DiscoveredPeer]>.makeStream()

        let result = await PeerResolver.firstMatch(
            in: stream, fingerprint: "wanted", timeout: 0.05
        )
        #expect(result == nil)
        continuation.finish()
    }

    /// The timeout must not cost us the success path.
    @Test("A peer already present is returned immediately")
    func presentPeerIsReturned() async {
        let (stream, continuation) = AsyncStream<[DiscoveredPeer]>.makeStream()
        continuation.yield([peer(fingerprint: "wanted")])

        let result = await PeerResolver.firstMatch(
            in: stream, fingerprint: "wanted", timeout: 5
        )
        #expect(result?.fingerprint == "wanted")
        continuation.finish()
    }

    /// A peer that shows up late — the Mac waking, AWDL settling — must still
    /// be picked up rather than lost to an over-eager deadline.
    @Test("A peer that appears after a delay is still found")
    func latePeerIsFound() async {
        let (stream, continuation) = AsyncStream<[DiscoveredPeer]>.makeStream()
        continuation.yield([])

        Task {
            try? await Task.sleep(for: .milliseconds(30))
            continuation.yield([peer(fingerprint: "wanted")])
        }

        let result = await PeerResolver.firstMatch(
            in: stream, fingerprint: "wanted", timeout: 5
        )
        #expect(result?.fingerprint == "wanted")
        continuation.finish()
    }

    /// Someone else's Mac must not satisfy the wait.
    @Test("A non-matching peer does not end the wait early")
    func wrongFingerprintIgnored() async {
        let (stream, continuation) = AsyncStream<[DiscoveredPeer]>.makeStream()
        continuation.yield([peer(fingerprint: "someone-else")])

        let result = await PeerResolver.firstMatch(
            in: stream, fingerprint: "wanted", timeout: 0.05
        )
        #expect(result == nil)
        continuation.finish()
    }
}

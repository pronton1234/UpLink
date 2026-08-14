import Testing
import Foundation
import Network
@testable import UpLinkKit

@Suite("Regression: reconnect")
struct ReconnectRegressionTests {

    private func peer(
        name: String,
        fingerprint: String?,
        port: UInt16,
        profile: TransportProfile = .localLink
    ) -> DiscoveredPeer {
        DiscoveredPeer(
            id: name,
            name: name,
            endpoint: .hostPort(host: NWEndpoint.Host("10.0.0.\(port % 250)"), port: NWEndpoint.Port(rawValue: port)!),
            fingerprint: fingerprint,
            profile: profile
        )
    }

    // SYMPTOM: reconnection remembered the Mac by its endpoint. The phone's
    // hotspot hands out a fresh address on every reconnect and AWDL endpoints
    // are ephemeral, so after the first drop the bridge could never find its
    // own Mac again — the user had to re-pair to get back on.
    @Test("A peer is found again after its address changes")
    func matchesAcrossAddressChange() {
        let before = peer(name: "Studio", fingerprint: "aabbccdd", port: 5001)
        let after = peer(name: "Studio", fingerprint: "aabbccdd", port: 6127)

        #expect(PeerResolver.match([after], fingerprint: "aabbccdd")?.endpoint == after.endpoint)
        #expect(before.endpoint != after.endpoint)  // the addresses really did differ
    }

    // The dangerous inverse: a *different* Mac that happens to have picked up
    // the address ours used to have must never be treated as ours, or the
    // phone would hand a stranger's machine a cellular session.
    @Test("A different device at the same address is not mistaken for the peer")
    func doesNotMatchStrangerAtSameAddress() {
        let stranger = peer(name: "Someone Else", fingerprint: "99887766", port: 5001)
        #expect(PeerResolver.match([stranger], fingerprint: "aabbccdd") == nil)
    }

    @Test("An unpaired peer advertising no fingerprint is never matched")
    func doesNotMatchUnidentifiedPeer() {
        let anonymous = peer(name: "Unknown", fingerprint: nil, port: 5001)
        #expect(PeerResolver.match([anonymous], fingerprint: "aabbccdd") == nil)
    }

    @Test("The preferred transport wins when a peer is visible over both")
    func prefersPreferredTransport() {
        let viaLocal = peer(name: "Studio", fingerprint: "aabbccdd", port: 5001, profile: .localLink)
        let viaAWDL = peer(name: "Studio", fingerprint: "aabbccdd", port: 5002, profile: .peerToPeer)

        let match = PeerResolver.match([viaLocal, viaAWDL], fingerprint: "aabbccdd")
        #expect(match?.profile == TransportProfile.preferenceOrder.first)
    }

    // SYMPTOM: backoff grew without bound, so a phone that had been out of
    // range overnight sat for hours before trying again — the user reopened the
    // lid and nothing happened.
    @Test("Backoff is capped so a long outage still recovers promptly")
    func backoffIsCapped() {
        var policy = ReconnectPolicy(baseDelay: 1, maxDelay: 30)
        var last: TimeInterval = 0
        for _ in 0 ..< 50 { last = policy.recordFailure() }
        #expect(last == 30)
    }

    @Test("Backoff grows between successive failures")
    func backoffGrows() {
        var policy = ReconnectPolicy(baseDelay: 1, maxDelay: 30)
        let first = policy.recordFailure()
        let second = policy.recordFailure()
        let third = policy.recordFailure()

        #expect(first < second)
        #expect(second < third)
    }

    // SYMPTOM: a successful reconnect left the failure count intact, so the
    // next unrelated drop started at the top of the backoff schedule and took
    // 30 seconds to recover from a momentary blip.
    @Test("A successful connection resets the backoff schedule")
    func successResetsBackoff() {
        var policy = ReconnectPolicy(baseDelay: 1, maxDelay: 30)
        for _ in 0 ..< 10 { _ = policy.recordFailure() }
        policy.recordSuccess()

        #expect(policy.attempt == 0)
        #expect(policy.recordFailure() == 1)
    }
}

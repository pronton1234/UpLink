import Testing
import Foundation
@testable import UpLinkKit

@Suite("Regression: capture policy")
struct CapturePolicyRegressionTests {

    // SYMPTOM: the proxy extension captured its own connection to the phone.
    // Every byte the extension sent to the phone was itself an outbound flow,
    // so it got captured and sent to the phone, which captured it again. The
    // Mac's CPU pegged and all networking died within seconds of connecting —
    // the single worst failure this codebase can produce, because recovering
    // requires killing the extension.
    //
    // This suite was deleted once, when capture moved to SOCKS and the hazard
    // was structurally gone. It is back because the transparent proxy is back.
    @Test("The bridge's own connection to the phone is never captured")
    func ownPeerTrafficIsNotCaptured() {
        let policy = CapturePolicy(peerEndpoints: ["172.20.10.1:51820"])
        #expect(policy.shouldCapture(remoteEndpoint: "172.20.10.1:51820") == false)
    }

    // The phone's port changes on every reconnect, so matching the full
    // endpoint alone would let the loop reappear after the first drop.
    @Test("Any port on the phone's address is excluded, not just the current one")
    func peerHostIsExcludedRegardlessOfPort() {
        let policy = CapturePolicy(peerEndpoints: ["172.20.10.1:51820"])
        #expect(policy.shouldCapture(remoteEndpoint: "172.20.10.1:443") == false)
        #expect(policy.shouldCapture(remoteEndpoint: "172.20.10.1:9999") == false)
    }

    // SYMPTOM: capturing loopback broke every local dev server on the machine —
    // localhost:3000 was routed out through the phone and never came back.
    @Test("Loopback is never captured", arguments: [
        "127.0.0.1:3000", "127.1.2.3:8080", "localhost:5432", "[::1]:8000",
    ])
    func loopbackIsNotCaptured(_ endpoint: String) {
        #expect(CapturePolicy().shouldCapture(remoteEndpoint: endpoint) == false)
    }

    // SYMPTOM: capturing mDNS meant Bonjour discovery went through the bridge.
    // Discovery is how the phone is found, so once the session dropped the Mac
    // could never find it again — unrecoverable without a restart.
    @Test("Link-local and multicast are never captured", arguments: [
        "169.254.1.1:5353", "224.0.0.251:5353", "[fe80::1cad:beef]:5353", "[ff02::fb]:5353",
    ])
    func discoveryTrafficIsNotCaptured(_ endpoint: String) {
        #expect(CapturePolicy().shouldCapture(remoteEndpoint: endpoint) == false)
    }

    // The policy must not be so eager that nothing gets bridged — that would be
    // a silently useless product rather than a loud failure.
    @Test("Ordinary internet traffic is still captured", arguments: [
        "93.184.216.34:443", "example.com:80", "[2606:2800:220:1:248:1893:25c8:1946]:443",
    ])
    func ordinaryTrafficIsCaptured(_ endpoint: String) {
        let policy = CapturePolicy(peerEndpoints: ["172.20.10.1:51820"])
        #expect(policy.shouldCapture(remoteEndpoint: endpoint))
    }

    // The defect this guards is prefix over-matching: treating 172.20.10.10 as
    // the peer because its address begins with 172.20.10.1. The original case
    // is now excluded for a *different* and correct reason — it is on a private
    // network, which the phone cannot reach — so the over-matching property is
    // asserted on public space, where only the peer rule can apply.
    @Test("An address that merely starts like the peer's is still captured")
    func similarAddressIsNotConfusedForPeer() {
        let policy = CapturePolicy(peerEndpoints: ["93.184.216.3:51820"])
        // 93.184.216.30 is a different host from 93.184.216.3.
        #expect(policy.shouldCapture(remoteEndpoint: "93.184.216.30:443"))
    }

    @Test("The peer's own subnet is excluded as a private network, not as the peer")
    func peerSubnetIsPrivate() {
        let policy = CapturePolicy(peerEndpoints: ["172.20.10.1:51820"])
        // A second host on the phone's hotspot subnet is still unreachable from
        // the cellular side, so it must not be bridged either.
        #expect(policy.shouldCapture(remoteEndpoint: "172.20.10.10:443") == false)
    }

    @Test("An empty endpoint is not captured rather than crashing")
    func emptyEndpointIsNotCaptured() {
        #expect(CapturePolicy().shouldCapture(remoteEndpoint: "") == false)
    }

    // UDP flows go through the same gate, and DNS to a resolver on the local
    // link must not be captured or discovery breaks in a subtler way.
    @Test("UDP endpoints are judged by the same rules")
    func udpUsesTheSameRules() {
        let policy = CapturePolicy(peerEndpoints: ["172.20.10.1:51820"])
        #expect(policy.shouldCapture(remoteEndpoint: "1.1.1.1:53"))
        #expect(policy.shouldCapture(remoteEndpoint: "224.0.0.251:5353") == false)
        #expect(policy.shouldCapture(remoteEndpoint: "172.20.10.1:53") == false)
    }
}

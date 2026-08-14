import Testing
import Foundation
@testable import UpLinkKit

// SYMPTOM: with the bridge live, pages half-loaded — some requests worked, most
// did not, which is a far more confusing symptom than being offline.
//
// One app did it. `com.relay.mac`, whose embedded Tailscale reconnect-stormed
// when the Mac's default route changed under it, claimed 31,337 flows in six
// minutes — about 87 a second. That saturated the single channel to the phone
// in thirteen seconds, and from then on EVERY app on the machine failed:
//
//     tcp claim 31,453   of which com.relay.mac: 31,337
//     tcp open      30
//
// Chrome's 268 claims were among the casualties.
//
// The mux already caps total streams at `Multiplexer.maxConcurrentStreams`
// (4,096). That cap protects memory, and this incident is exactly why it is not
// enough: a global cap is first-come-first-served, which is the mechanism by
// which one process took the bridge away from everything else. Fairness has to
// be per-app, because "who is asking" is the only thing that distinguishes a
// storm from a busy machine.

@Suite("Regression: one app cannot take the bridge from every other")
struct PerAppFlowLimitRegressionTests {

    private let storming = "com.example.storm"
    private let browser = "com.example.browser"
    private let endpoint = "93.184.216.34:443"

    private func admission(_ flows: [String: Int]) -> FlowAdmission {
        FlowAdmission(hasSession: true, policy: CapturePolicy(), flowsPerApp: flows)
    }

    @Test("An app at its limit is declined")
    func stormingAppIsDeclined() {
        let atLimit = admission([storming: FlowAdmission.perAppFlowLimit])
        #expect(atLimit.shouldClaim(
            remoteEndpoint: endpoint, sourceSigningIdentifier: storming
        ) == false)
        // UDP too — a datagram session has no destination to judge, so the
        // count is the only thing standing between one app and the whole budget.
        #expect(atLimit.shouldClaimDatagramSession(sourceSigningIdentifier: storming) == false)
    }

    // The property that actually matters. Declining the storm is worthless if
    // everyone else has already been starved.
    @Test("Every other app keeps working while one is capped")
    func otherAppsAreUnaffected() {
        let mixed = admission([
            storming: FlowAdmission.perAppFlowLimit + 5_000,
            browser: 12,
        ])
        #expect(mixed.shouldClaim(
            remoteEndpoint: endpoint, sourceSigningIdentifier: browser
        ))
        #expect(mixed.shouldClaimDatagramSession(sourceSigningIdentifier: browser))
        #expect(mixed.shouldClaim(
            remoteEndpoint: endpoint, sourceSigningIdentifier: storming
        ) == false)
    }

    @Test("Ordinary use is nowhere near the limit")
    func normalUseIsUnaffected() {
        // A busy browser across all its helpers sits in the low hundreds. The
        // cap exists to stop one process consuming the 4,096-stream budget, not
        // to police browsing, and a cap that fires in normal use would be its
        // own outage.
        let busy = admission([browser: 200])
        #expect(busy.shouldClaim(remoteEndpoint: endpoint, sourceSigningIdentifier: browser))
        #expect(FlowAdmission.perAppFlowLimit < Multiplexer.maxConcurrentStreams,
                "a per-app cap at or above the global one cannot provide fairness")
    }

    // An unattributed flow must not be counted against a shared bucket — that
    // would let one anonymous source lock out every other.
    @Test("Flows with no identifier are not capped")
    func unattributedFlowsAreAdmitted() {
        let saturated = admission([storming: FlowAdmission.perAppFlowLimit])
        #expect(saturated.shouldClaim(remoteEndpoint: endpoint))
        #expect(saturated.withinFlowLimit(nil))
    }

    // The cap must not have displaced the guards that came before it.
    @Test("The original guards are intact")
    func originalGuardsIntact() {
        let policy = CapturePolicy(
            peerEndpoints: ["172.20.10.1:51820"],
            directApps: ["com.example.excluded"]
        )
        let gate = FlowAdmission(hasSession: true, policy: policy, flowsPerApp: [browser: 1])
        #expect(gate.shouldClaim(remoteEndpoint: "172.20.10.1:51820") == false)
        #expect(gate.shouldClaim(remoteEndpoint: "127.0.0.1:3000") == false)
        #expect(gate.shouldClaim(
            remoteEndpoint: endpoint, sourceSigningIdentifier: "com.example.excluded"
        ) == false)
        #expect(gate.shouldClaim(
            remoteEndpoint: endpoint, sourceSigningIdentifier: UpLinkIdentifiers.macProxyExtension
        ) == false)

        // And with no session, nothing is claimed regardless of counts.
        let dead = FlowAdmission(hasSession: false, policy: policy, flowsPerApp: [:])
        #expect(dead.shouldClaim(remoteEndpoint: endpoint, sourceSigningIdentifier: browser) == false)
    }
}

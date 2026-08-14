import Testing
import Foundation
@testable import UpLinkKit

// The rule these tests protect is one sentence: NEVER CLAIM A FLOW YOU CANNOT
// SERVICE. A transparent proxy sits in front of every TCP and UDP flow on the
// machine, and `handleNewFlow` returning true means "I own this connection".
// Owning a connection with nowhere to send it kills it. Doing that to every
// flow kills all networking on the Mac — and because the extension outlives the
// app, quitting does not fix it.

/// The gate `handleNewFlow` consults, extracted so it is testable without a
/// signed, notarized, user-approved system extension.
struct FlowAdmission {
    var hasSession: Bool
    var policy: CapturePolicy
    /// Signing identifier of the extension itself, so its own sockets can be
    /// recognised and declined. See `SelfCaptureRegressionTests`.
    var ownSigningIdentifier: String = UpLinkIdentifiers.macProxyExtension

    func shouldClaim(remoteEndpoint: String, sourceSigningIdentifier: String? = nil) -> Bool {
        guard hasSession else { return false }
        if sourceSigningIdentifier == ownSigningIdentifier { return false }
        return policy.shouldCapture(remoteEndpoint: remoteEndpoint)
    }
}

@Suite("Regression: flow admission")
struct FlowClaimRegressionTests {

    // SYMPTOM: with no phone connected, every outbound connection on the Mac
    // was claimed by the extension and then immediately closed, because the
    // session check happened AFTER the decision to claim. All networking died,
    // Wi-Fi appeared broken, and quitting the app did not help — the extension
    // keeps running, so only a reboot cleared it.
    @Test("With no session, nothing is claimed")
    func noSessionClaimsNothing() {
        let admission = FlowAdmission(hasSession: false, policy: CapturePolicy())
        for endpoint in ["93.184.216.34:443", "1.1.1.1:53", "example.com:80", "[2606:4700::1]:443"] {
            #expect(admission.shouldClaim(remoteEndpoint: endpoint) == false,
                    "claimed \(endpoint) with no session — this breaks all networking")
        }
    }

    // The session check must come FIRST. A capture policy that would otherwise
    // say yes must not be able to override the absence of somewhere to send it.
    @Test("The session check precedes the capture policy")
    func sessionCheckComesFirst() {
        // A policy that captures everything, which is the normal state.
        let permissive = CapturePolicy()
        #expect(permissive.shouldCapture(remoteEndpoint: "93.184.216.34:443"))

        let admission = FlowAdmission(hasSession: false, policy: permissive)
        #expect(admission.shouldClaim(remoteEndpoint: "93.184.216.34:443") == false)
    }

    @Test("With a session, ordinary traffic is claimed")
    func sessionClaimsOrdinaryTraffic() {
        let admission = FlowAdmission(
            hasSession: true,
            policy: CapturePolicy(peerEndpoints: ["172.20.10.1:51820"])
        )
        #expect(admission.shouldClaim(remoteEndpoint: "93.184.216.34:443"))
    }

    // Both guards still apply together: having a session does not license
    // claiming the link to the phone, loopback, or discovery traffic.
    @Test("A session does not license claiming the bridge's own traffic")
    func sessionStillExcludesPeerAndLoopback() {
        let admission = FlowAdmission(
            hasSession: true,
            policy: CapturePolicy(peerEndpoints: ["172.20.10.1:51820"])
        )
        #expect(admission.shouldClaim(remoteEndpoint: "172.20.10.1:51820") == false)
        #expect(admission.shouldClaim(remoteEndpoint: "127.0.0.1:3000") == false)
        #expect(admission.shouldClaim(remoteEndpoint: "224.0.0.251:5353") == false)
    }

    // SYMPTOM: the session flag was cleared only after teardown finished, so
    // flows arriving during teardown were still claimed and killed. Clearing it
    // first makes traffic normal again immediately.
    @Test("Losing the session stops claiming at once")
    func losingSessionStopsClaimingImmediately() {
        var admission = FlowAdmission(hasSession: true, policy: CapturePolicy())
        #expect(admission.shouldClaim(remoteEndpoint: "93.184.216.34:443"))

        admission.hasSession = false
        #expect(admission.shouldClaim(remoteEndpoint: "93.184.216.34:443") == false)
    }
}

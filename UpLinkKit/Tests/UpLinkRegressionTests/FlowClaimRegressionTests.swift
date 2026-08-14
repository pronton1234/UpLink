import Testing
import Foundation
@testable import UpLinkKit

// The rule these tests protect is one sentence: NEVER CLAIM A FLOW YOU CANNOT
// SERVICE. A transparent proxy sits in front of every TCP and UDP flow on the
// machine, and `handleNewFlow` returning true means "I own this connection".
// Owning a connection with nowhere to send it kills it. Doing that to every
// flow kills all networking on the Mac — and because the extension outlives the
// app, quitting does not fix it.

// `FlowAdmission` used to be re-implemented right here, in the test target,
// "extracted so it is testable". It was not extracted — it was copied, and
// `TransparentProxyProvider.handleNewFlow` went on inlining its own version of
// the same three gates. So the guard REGRESSIONS.md calls the worst failure
// this codebase can produce was checked against a replica, and changing the
// code that actually runs failed nothing here. It now lives in
// `UpLinkKit/Support/FlowAdmission.swift` and `handleNewFlow` calls it.

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

// SYMPTOM: a device test was being run from this Mac, over this Mac's
// connection. The bridge claimed the tester's own API traffic, that traffic
// stopped, and the only way back was killing the Mac app and disconnecting the
// phone — losing the session that was being measured. The tool needed to
// diagnose the bridge goes offline exactly when the bridge misbehaves, so
// every run is one fault away from ending itself.
//
// `directHosts` cannot fix this. It matches on the host part of an endpoint,
// and the traffic in question is TLS to an address behind a CDN that rotates
// them — and for UDP there is no endpoint at claim time at all. The only thing
// knowable before a flow is claimed is which app is asking.
@Suite("Regression: an app can be kept off the bridge entirely")
struct DirectAppRegressionTests {

    private let policy = CapturePolicy(
        peerEndpoints: ["172.20.10.1:51820"],
        directApps: ["com.example.tooling"]
    )

    private var admission: FlowAdmission {
        FlowAdmission(hasSession: true, policy: policy)
    }

    @Test("An excluded app's TCP flow is declined")
    func excludedAppTCPIsDeclined() {
        #expect(admission.shouldClaim(
            remoteEndpoint: "93.184.216.34:443",
            sourceSigningIdentifier: "com.example.tooling"
        ) == false)
    }

    // The one that matters. A UDP flow has no destination to judge, so it is
    // claimed unconditionally and the pump must service every datagram on it.
    // If that pump is the thing under test, the excluded app's UDP traffic goes
    // down with it — which is how DNS died on the tester's own machine.
    @Test("An excluded app's UDP session is declined")
    func excludedAppUDPIsDeclined() {
        #expect(admission.shouldClaimDatagramSession(
            sourceSigningIdentifier: "com.example.tooling"
        ) == false)
    }

    @Test("Every other app is unaffected")
    func otherAppsStillBridged() {
        #expect(admission.shouldClaim(
            remoteEndpoint: "93.184.216.34:443",
            sourceSigningIdentifier: "com.example.browser"
        ))
        #expect(admission.shouldClaimDatagramSession(
            sourceSigningIdentifier: "com.example.browser"
        ))
        // An unattributed flow is ordinary traffic, not an excluded one.
        #expect(admission.shouldClaim(remoteEndpoint: "93.184.216.34:443"))
    }

    @Test("An empty exclusion list changes nothing")
    func emptyListIsInert() {
        let open = FlowAdmission(hasSession: true, policy: CapturePolicy())
        #expect(open.shouldClaim(
            remoteEndpoint: "93.184.216.34:443",
            sourceSigningIdentifier: "com.example.tooling"
        ))
        #expect(open.shouldClaimDatagramSession(sourceSigningIdentifier: "com.example.tooling"))
    }

    // The new rule must not have displaced the old ones. Each of these is a
    // separate outage this codebase has already had.
    @Test("The original guards are intact")
    func originalGuardsIntact() {
        // No session: nothing is claimed, TCP or UDP.
        let dead = FlowAdmission(hasSession: false, policy: policy)
        #expect(dead.shouldClaim(remoteEndpoint: "93.184.216.34:443") == false)
        #expect(dead.shouldClaimDatagramSession() == false)

        // The extension's own sockets, including its UDP relay's.
        #expect(admission.shouldClaim(
            remoteEndpoint: "93.184.216.34:443",
            sourceSigningIdentifier: UpLinkIdentifiers.macProxyExtension
        ) == false)
        #expect(admission.shouldClaimDatagramSession(
            sourceSigningIdentifier: UpLinkIdentifiers.macProxyExtension
        ) == false)

        // The link to the phone, loopback, and mDNS.
        #expect(admission.shouldClaim(remoteEndpoint: "172.20.10.1:51820") == false)
        #expect(admission.shouldClaim(remoteEndpoint: "127.0.0.1:3000") == false)
        #expect(admission.shouldClaim(remoteEndpoint: "224.0.0.251:5353") == false)
    }
}

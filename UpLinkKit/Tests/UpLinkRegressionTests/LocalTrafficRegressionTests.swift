import Testing
import Foundation
import CryptoKit
@testable import UpLinkKit

// SYMPTOM: with the bridge connected and the phone correctly reporting
// "Cellular", browsing on the Mac still felt like the throttled hotspot. The
// device log carried 296 `udp flow failed: The peer closed the flow` entries in
// 25 minutes, and no TCP failures at all.
//
// CAUSE: the Mac's DNS resolvers were its home router — 192.168.1.254 and
// 2001:db8:1:2::1. Nothing in the capture policy excluded them, so every
// lookup was sent across the bridge to a phone that cannot reach a router on
// someone's home LAN. Each query timed out and retried. Since a connection
// cannot start until its name resolves, the entire machine felt throttled while
// the bridge was, accurately, reporting cellular egress.
//
// The second half of the defect is that refusing to bridge is not enough. A UDP
// flow has no remote endpoint, so it must be claimed before its destinations
// are known, and a claimed flow is ours to service — the system will not
// deliver a datagram we declined. Dropping them is what produced the flood.

@Suite("Regression: local traffic must not be bridged")
struct LocalTrafficRegressionTests {

    /// The exact resolvers from the failing session.
    private var policy: CapturePolicy {
        CapturePolicy(
            peerEndpoints: ["172.20.10.1:51820"],
            directHosts: ["192.168.1.254", "2001:db8:1:2::1"]
        )
    }

    @Test("The Mac's own DNS resolvers are never bridged")
    func resolversAreNeverBridged() {
        #expect(policy.shouldCapture(remoteEndpoint: "192.168.1.254:53") == false)
        #expect(policy.shouldCapture(remoteEndpoint: "[2001:db8:1:2::1]:53") == false)
    }

    /// A globally-scoped address can still be the local router. Prefix rules
    /// cannot catch that, which is the whole reason resolvers are named
    /// explicitly rather than inferred.
    @Test("A globally-scoped resolver is excluded by name, not by prefix")
    func globallyScopedResolverIsExcluded() {
        let unnamed = CapturePolicy(peerEndpoints: [])
        #expect(unnamed.shouldCapture(remoteEndpoint: "[2001:db8:1:2::1]:53"),
                "without naming it, this address is indistinguishable from a real internet host")

        #expect(policy.shouldCapture(remoteEndpoint: "[2001:db8:1:2::1]:53") == false)
    }

    @Test("Private networks stay on the local link", arguments: [
        "192.168.1.10:445",     // a NAS
        "10.0.0.5:631",         // a printer
        "172.16.4.4:80",        // a corporate host
        "172.31.255.1:22",      // top of the 172.16/12 range
        "[fd00::1]:53",         // IPv6 unique local
    ])
    func privateNetworksAreNotBridged(endpoint: String) {
        #expect(policy.shouldCapture(remoteEndpoint: endpoint) == false,
                "\(endpoint) is only reachable from this Mac; the phone cannot deliver it")
    }

    /// 172.16/12 is 172.16–172.31. Everything else in 172/8 is ordinary public
    /// space and must still be bridged.
    @Test("Addresses outside 172.16/12 are still bridged", arguments: [
        "172.15.0.1:443", "172.32.0.1:443", "172.217.16.14:443",
    ])
    func publicTwelveSevenTwoIsBridged(endpoint: String) {
        #expect(policy.shouldCapture(remoteEndpoint: endpoint))
    }

    /// The point of the product. Nothing above may start excluding real
    /// traffic.
    @Test("Ordinary internet destinations are still bridged", arguments: [
        "93.184.216.34:443", "1.1.1.1:53", "[2606:4700:4700::1111]:443", "example.com:443",
    ])
    func publicDestinationsAreBridged(endpoint: String) {
        #expect(policy.shouldCapture(remoteEndpoint: endpoint))
    }

    /// The original guards must survive the new rules.
    @Test("The self-capture and loopback guards still hold")
    func originalGuardsIntact() {
        #expect(policy.shouldCapture(remoteEndpoint: "172.20.10.1:51820") == false)
        #expect(policy.shouldCapture(remoteEndpoint: "127.0.0.1:3000") == false)
        #expect(policy.shouldCapture(remoteEndpoint: "224.0.0.251:5353") == false)
        #expect(policy.shouldCapture(remoteEndpoint: "[fe80::1]:5353") == false)
    }

    /// A resolver on the phone's own hotspot subnet must be reached directly
    /// too — that is the normal case when the Mac has no other network.
    @Test("A hotspot-provided resolver is reached directly")
    func hotspotResolverIsDirect() {
        let onHotspot = CapturePolicy(
            peerEndpoints: ["172.20.10.1:51820"],
            directHosts: ["172.20.10.1"]
        )
        #expect(onHotspot.shouldCapture(remoteEndpoint: "172.20.10.1:53") == false)
    }
}

// The self-capture loop is the worst failure this codebase can produce: the
// extension proxying its own sockets, recursing without bound, taking all
// networking down until it is torn down — which outlives the app and costs a
// reboot.
//
// `LocalDatagramRelay` made this newly reachable. It deliberately opens sockets
// to destinations the policy excludes, and the UDP branch of `handleNewFlow`
// must claim every flow because a UDP flow has no remote endpoint to judge. So
// the relay's own socket would be claimed, handed back to the relay, and opened
// again. The guard is by *process* — `sourceAppSigningIdentifier` — because
// address-based exclusion cannot cover a relay that exists to reach arbitrary
// local addresses.

// `FlowAdmission` is the shared gate declared in FlowClaimRegressionTests.

@Suite("Regression: the extension never captures itself")
struct SelfCaptureRegressionTests {

    private var admission: FlowAdmission {
        FlowAdmission(
            hasSession: true,
            policy: CapturePolicy(
                peerEndpoints: ["172.20.10.1:51820"],
                directHosts: ["192.168.1.254"]
            ),
            ownSigningIdentifier: UpLinkIdentifiers.macProxyExtension
        )
    }

    @Test("A flow from the extension itself is never claimed")
    func ownFlowsAreDeclined() {
        // A public destination the policy would otherwise happily bridge.
        #expect(admission.shouldClaim(
            remoteEndpoint: "93.184.216.34:443",
            sourceSigningIdentifier: UpLinkIdentifiers.macProxyExtension
        ) == false)
    }

    /// The exact loop the relay would create: a socket to an excluded resolver,
    /// opened by us, being handed straight back to us.
    @Test("The local relay's own socket is not fed back into the relay")
    func relaySocketIsNotRecaptured() {
        #expect(admission.shouldClaim(
            remoteEndpoint: "192.168.1.254:53",
            sourceSigningIdentifier: UpLinkIdentifiers.macProxyExtension
        ) == false)
    }

    @Test("Ordinary apps are still captured")
    func otherAppsAreStillClaimed() {
        #expect(admission.shouldClaim(
            remoteEndpoint: "93.184.216.34:443",
            sourceSigningIdentifier: "com.apple.Safari"
        ))
        #expect(admission.shouldClaim(
            remoteEndpoint: "93.184.216.34:443",
            sourceSigningIdentifier: nil
        ))
    }

    @Test("The session check still comes first")
    func sessionCheckPrecedesEverything() {
        var admission = self.admission
        admission.hasSession = false
        #expect(admission.shouldClaim(
            remoteEndpoint: "93.184.216.34:443",
            sourceSigningIdentifier: "com.apple.Safari"
        ) == false)
    }
}

// SYMPTOM: the first honest test — Wi-Fi off, hotspot off, nothing but the
// phone — and every tab refused to open. The bridge appeared completely dead.
//
// CAUSE: with no other network, the Mac's configured resolvers are whatever the
// last real network gave it, here the home router at 192.168.1.254. Those are
// unreachable, so name resolution failed before a single packet was sent. There
// was nothing for the bridge to carry, and it looked broken while working.
//
// The bridge therefore supplies its own resolvers. That creates a trap the
// second half of this suite guards: while the proxy is running, the system's
// resolver list IS `UpLinkDNS.servers`, and `SystemResolvers` reads that list
// to decide what must be reached directly. Marking our own resolvers "direct"
// sends DNS out an interface that, in this exact scenario, does not exist —
// reintroducing the failure the DNS settings were added to prevent.

@Suite("Regression: the bridge supplies working DNS")
struct BridgeDNSRegressionTests {

    /// The redirect target has to be reachable *through* the bridge, which
    /// means it must be a public address. If it were ever changed to something
    /// the capture policy excludes, every DNS query would be redirected into
    /// the same black hole it was redirected away from.
    @Test("The redirect target is carried by the bridge")
    func redirectTargetIsBridged() {
        let policy = CapturePolicy(
            peerEndpoints: ["172.20.10.1:51820"],
            directHosts: ["192.168.1.254"]
        )
        #expect(policy.shouldCapture(
            remoteEndpoint: "\(UpLinkDNS.primary):\(UpLinkDNS.port)"
        ))
    }

    /// And the resolvers it redirects *away* from are exactly the ones the
    /// policy refuses to bridge, so the two rules cannot disagree.
    @Test("A router resolver is refused by the policy, which is what triggers the redirect")
    func routerResolverTriggersRedirect() {
        let policy = CapturePolicy(
            directHosts: ["192.168.1.254", "2001:db8:1:2::1"]
        )
        // Refused by the policy is precisely the condition `pumpUDP` uses to
        // decide a DNS query needs redirecting, so these two must agree.
        #expect(policy.shouldCapture(remoteEndpoint: "192.168.1.254:53") == false)
        #expect(policy.shouldCapture(remoteEndpoint: "[2001:db8:1:2::1]:53") == false)
    }

    @Test("DNS uses the well-known port")
    func dnsPortIsFiftyThree() {
        #expect(UpLinkDNS.port == 53)
    }

    /// What `ProxyState` computes when building the policy.
    private func directHosts(systemResolvers: Set<String>) -> Set<String> {
        systemResolvers.subtracting(UpLinkDNS.servers.map { $0.lowercased() })
    }

    @Test("Our own resolvers are never marked reach-directly")
    func ownResolversAreNotDirect() {
        // While the proxy runs, this is what the system reports.
        let system: Set<String> = ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111"]
        #expect(directHosts(systemResolvers: system).isEmpty)
    }

    /// And with those excluded, the policy must actually bridge them.
    @Test("DNS queries to the bridge's resolvers are carried over the bridge")
    func bridgeResolversAreBridged() {
        let policy = CapturePolicy(
            peerEndpoints: ["172.20.10.1:51820"],
            directHosts: directHosts(systemResolvers: ["1.1.1.1", "1.0.0.1"])
        )
        #expect(policy.shouldCapture(remoteEndpoint: "1.1.1.1:53"))
        #expect(policy.shouldCapture(remoteEndpoint: "[2606:4700:4700::1111]:53"))
    }

    /// A leftover router resolver must still be excluded — it is genuinely
    /// unreachable through the phone.
    @Test("A stale local resolver is still reached directly")
    func staleLocalResolverStaysDirect() {
        let system: Set<String> = ["1.1.1.1", "192.168.1.254"]
        #expect(directHosts(systemResolvers: system) == ["192.168.1.254"])
    }

    @Test("The bridge's resolvers are public addresses, not local ones")
    func resolversArePublic() {
        let policy = CapturePolicy()
        for server in UpLinkDNS.servers {
            let endpoint = server.contains(":") ? "[\(server)]:53" : "\(server):53"
            #expect(policy.shouldCapture(remoteEndpoint: endpoint),
                    "\(server) must be reachable through the bridge, so it cannot be a private address")
        }
    }

    @Test("Both IPv4 and IPv6 resolvers are offered")
    func bothFamiliesArePresent() {
        #expect(UpLinkDNS.servers.contains { !$0.contains(":") })
        #expect(UpLinkDNS.servers.contains { $0.contains(":") })
    }
}

// SYMPTOM: the Mac kept forgetting the phone. Every relaunch advertised
// `sessionKeys=0`, so the phone's reconnect loop was rejected with
// `-9864: unknown PSK identity` roughly every 15 seconds, and the only way
// forward was to pair again — which the user had to do repeatedly.
//
// CAUSE: pairing happens in the proxy extension, because the extension owns the
// listener. But a system extension runs as root outside the login session and
// cannot reach the keychain, so its device store is in memory and dies with the
// process. The app never pulled those pairings back, and the "devices" message
// it would have used returned only "fingerprint:name" — no public key, so the
// record could not have been reconstructed even if it had.

@Suite("Regression: pairings must survive a restart")
struct PairingPersistenceRegressionTests {

    private func device(name: String) -> PairedDevice {
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        return PairedDevice(
            fingerprint: PairedDevice.fingerprint(of: key),
            name: name,
            publicKey: key,
            pairedAt: Date()
        )
    }

    /// The wire format the app reads back must carry everything needed to
    /// re-seed the extension — above all the public key, which is what the
    /// session PSK is derived from.
    @Test("A round trip through the devices message preserves the public key")
    func devicesRoundTripKeepsPublicKey() throws {
        let original = [device(name: "iPhone"), device(name: "iPad")]

        // What the extension sends.
        let encoded = try JSONEncoder().encode(original).base64EncodedString()
        // What the app does with it.
        let json = try #require(Data(base64Encoded: encoded))
        let decoded = try JSONDecoder().decode([PairedDevice].self, from: json)

        #expect(decoded.count == 2)
        for (before, after) in zip(original, decoded) {
            #expect(after.fingerprint == before.fingerprint)
            #expect(after.publicKey == before.publicKey, "without the key no session PSK can be derived")
            #expect(after.name == before.name)
        }
    }

    /// A session key can actually be derived from a device that made the round
    /// trip — the property the whole handshake depends on.
    @Test("A restored device still derives the same session key")
    func restoredDeviceDerivesSameKey() throws {
        let macIdentity = Curve25519.KeyAgreement.PrivateKey()
        let phoneIdentity = Curve25519.KeyAgreement.PrivateKey()
        let phone = PairedDevice(
            fingerprint: PairedDevice.fingerprint(of: phoneIdentity.publicKey.rawRepresentation),
            name: "iPhone",
            publicKey: phoneIdentity.publicKey.rawRepresentation,
            pairedAt: Date()
        )

        let json = try JSONEncoder().encode([phone]).base64EncodedString()
        let restored = try JSONDecoder().decode(
            [PairedDevice].self,
            from: try #require(Data(base64Encoded: json))
        )[0]

        let before = try KeySchedule.sessionKey(
            localPrivate: macIdentity,
            remotePublic: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: phone.publicKey),
            context: Data(phone.fingerprint.utf8)
        )
        let after = try KeySchedule.sessionKey(
            localPrivate: macIdentity,
            remotePublic: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: restored.publicKey),
            context: Data(restored.fingerprint.utf8)
        )
        #expect(before == after)
    }

    /// An empty reply is normal (nothing paired yet) and must not be mistaken
    /// for corrupt data.
    @Test("An empty devices reply decodes to nothing rather than failing")
    func emptyReplyIsHandled() throws {
        let encoded = try JSONEncoder().encode([PairedDevice]()).base64EncodedString()
        let decoded = try JSONDecoder().decode(
            [PairedDevice].self,
            from: try #require(Data(base64Encoded: encoded))
        )
        #expect(decoded.isEmpty)
    }
}

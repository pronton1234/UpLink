import Testing
import Foundation
@testable import UpLinkKit

// SYMPTOM: with the bridge up, the Mac captured its own control channel to the
// phone. `com.apple.CoreDevice.remotepairingd` — the Mac↔iPhone developer
// connection — was claimed 1217 times in a few seconds and routed at the phone,
// through the phone. Writes stopped being acknowledged, and the session ended
// within three seconds of starting, every time:
//
//     08:32:48  claim tcp 2001:db8:1:2:23:f710:2dae:d09d:49152
//                 by com.apple.CoreDevice.remotepairingd
//     08:32:49  tcp FAIL … handshakeFailed("write not acknowledged within 10s")
//     08:32:51  session ENDED
//
// The address is the phone's, on the user's own home LAN. This Mac's address on
// the same LAN was 2001:db8:1:2:a113:aa40:7944:eaf4 — the same /64.
//
// `CapturePolicy` excluded RFC 1918 and RFC 4193 space by prefix, which works
// for IPv4 and cannot work for IPv6: a home network is delegated a globally
// routable /64, so every neighbour on it looks exactly like a server in another
// country. There is nothing to pattern-match on. The prefix has to be read from
// this Mac's own interfaces.
//
// Same lesson as the resolvers already recorded in docs/REGRESSIONS.md: a
// globally-scoped address can still be local.

@Suite("Regression: a network this Mac is attached to is never bridged")
struct OnLinkNetworkRegressionTests {

    /// The real addresses from the failure, so the test fails the way it failed.
    private let macAddress = "2001:db8:1:2:a113:aa40:7944:eaf4"
    private let phoneAddress = "2001:db8:1:2:23:f710:2dae:d09d"

    private var homeLAN: OnLinkNetwork {
        OnLinkNetwork(address: macAddress, prefixLength: 64)!
    }

    @Test("The phone's globally-scoped address on the home LAN is not bridged")
    func phoneOnTheHomeLANIsNotBridged() {
        let policy = CapturePolicy(localNetworks: [homeLAN])

        // The exact endpoint from the log, and the one that killed the session.
        #expect(policy.shouldCapture(remoteEndpoint: "\(phoneAddress):49152") == false)
        // Bracketed form, which is how an endpoint with a port is usually spelled.
        #expect(policy.shouldCapture(remoteEndpoint: "[\(phoneAddress)]:49152") == false)
    }

    // The rule that made this invisible: nothing about the address says "local".
    @Test("Address prefixes alone cannot recognise it")
    func prefixRulesCannotSeeIt() {
        #expect(CapturePolicy.isPrivateNetwork("\(phoneAddress):49152") == false)
        #expect(CapturePolicy.isLinkLocalOrMulticast("\(phoneAddress):49152") == false)
        // Which is exactly why an empty policy still bridges it.
        #expect(CapturePolicy().shouldCapture(remoteEndpoint: "\(phoneAddress):49152"))
    }

    // Over-excluding is the opposite failure and just as total: a bridge that
    // carries nothing presents as "connected with no traffic", which this
    // codebase has already produced three times for other reasons.
    @Test("A real internet host in a different /64 is still bridged")
    func realInternetHostsAreStillBridged() {
        let policy = CapturePolicy(localNetworks: [homeLAN])
        #expect(policy.shouldCapture(remoteEndpoint: "[2606:4700:4700::1111]:443"))
        #expect(policy.shouldCapture(remoteEndpoint: "[2600:387:15:6712::7]:443"))
        // One bit outside the /64 is outside.
        #expect(policy.shouldCapture(remoteEndpoint: "[2001:db8:1:3::1]:443"))
        // …and the last address inside it is inside.
        #expect(policy.shouldCapture(remoteEndpoint: "[2001:db8:1:2:ffff:ffff:ffff:ffff]:443") == false)
        #expect(policy.shouldCapture(remoteEndpoint: "93.184.216.34:443"))
    }

    // Deliberately a PUBLIC IPv4 network, not 169.254 or 192.168. Those are
    // already caught by rules 3 and 5, so a test using them passes with rule 6
    // deleted — it looks like coverage and pins nothing. A Mac on a public IPv4
    // LAN has exactly the IPv6 problem: neighbours indistinguishable from
    // internet hosts.
    @Test("A public IPv4 network this Mac is on is excluded")
    func publicIPv4OnLinkIsExcluded() {
        let policy = CapturePolicy(localNetworks: [
            OnLinkNetwork(address: "203.0.113.17", prefixLength: 24)!,
        ])
        #expect(policy.shouldCapture(remoteEndpoint: "203.0.113.99:443") == false)
        // One octet outside the /24 is a stranger again.
        #expect(policy.shouldCapture(remoteEndpoint: "203.0.114.99:443"))
        #expect(policy.shouldCapture(remoteEndpoint: "93.184.216.34:443"))
    }

    // The guard that stops one malformed netmask from taking the whole bridge
    // down. `::/0` would exclude every destination on earth, and the symptom —
    // connected, carrying nothing — is the hardest one in this product.
    @Test("A prefix broad enough to swallow the internet is refused")
    func overlyBroadPrefixesAreRefused() {
        #expect(OnLinkNetwork(address: "::", prefixLength: 0) == nil)
        #expect(OnLinkNetwork(address: "2001:db8::", prefixLength: 3) == nil)
        #expect(OnLinkNetwork(address: "2001:db8::", prefixLength: 15) == nil)
        #expect(OnLinkNetwork(address: "10.0.0.1", prefixLength: 0) == nil)
        #expect(OnLinkNetwork(address: "10.0.0.1", prefixLength: 7) == nil)
        // Out of range entirely.
        #expect(OnLinkNetwork(address: "10.0.0.1", prefixLength: 33) == nil)
        #expect(OnLinkNetwork(address: "::1", prefixLength: 129) == nil)
        // And the smallest legitimate ones are accepted.
        #expect(OnLinkNetwork(address: "10.0.0.1", prefixLength: 8) != nil)
        #expect(OnLinkNetwork(address: "2001:db8::", prefixLength: 16) != nil)
    }

    // getnameinfo returns link-local addresses scoped. inet_pton rejects that
    // spelling outright, so without stripping the zone every link-local
    // interface would be skipped in silence.
    @Test("A scoped link-local address still parses")
    func scopedAddressesParse() {
        let network = OnLinkNetwork(address: "fe80::1c28:233a:5340:e924%en0", prefixLength: 64)
        #expect(network != nil)
        #expect(network?.contains("fe80::f9:aaff:fed3:49c6") == true)
        #expect(network?.contains("fe80::f9:aaff:fed3:49c6%en8") == true)
    }

    @Test("Nonsense is not a network")
    func garbageIsRejected() {
        #expect(OnLinkNetwork(address: "", prefixLength: 64) == nil)
        #expect(OnLinkNetwork(address: "example.com", prefixLength: 64) == nil)
        #expect(OnLinkNetwork(address: "999.1.1.1", prefixLength: 24) == nil)
        // A mismatched family never matches.
        #expect(homeLAN.contains("93.184.216.34") == false)
        #expect(homeLAN.contains("not-an-address") == false)
    }

    // Reading the real interfaces of whatever machine this runs on. Exact
    // values are machine-dependent, so the assertions are invariants — but the
    // last one is the whole safety argument, and no unit test of `OnLinkNetwork`
    // in isolation can make it: if a malformed netmask ever produced a broad
    // prefix, the bridge would carry nothing and present as "connected with no
    // traffic", the hardest symptom in this product.
    @Test("The real interface list never excludes the internet")
    func realInterfacesDoNotSwallowTheInternet() {
        let policy = CapturePolicy(localNetworks: LocalNetworks.current())
        for host in [
            "1.1.1.1:53", "93.184.216.34:443", "8.8.8.8:53",
            "[2606:4700:4700::1111]:443", "[2001:4860:4860::8888]:53",
        ] {
            #expect(
                policy.shouldCapture(remoteEndpoint: host),
                "\(host) was excluded — an interface prefix is swallowing the internet"
            )
        }
    }

    @Test("Every network read from the interfaces is within the safe floors")
    func realInterfacesAreWithinTheFloors() {
        for network in LocalNetworks.current() {
            let isIPv6 = network.network.count == 16
            let floor = isIPv6
                ? OnLinkNetwork.minimumIPv6PrefixLength
                : OnLinkNetwork.minimumIPv4PrefixLength
            #expect(network.prefixLength >= floor)
            #expect(network.prefixLength <= (isIPv6 ? 128 : 32))
        }
    }

    // The new rule must not have displaced the old ones.
    @Test("The original guards are intact")
    func originalGuardsIntact() {
        let policy = CapturePolicy(
            peerEndpoints: ["172.20.10.1:51820"],
            directHosts: ["192.168.1.254"],
            localNetworks: [homeLAN]
        )
        #expect(policy.shouldCapture(remoteEndpoint: "172.20.10.1:51820") == false)
        #expect(policy.shouldCapture(remoteEndpoint: "127.0.0.1:3000") == false)
        #expect(policy.shouldCapture(remoteEndpoint: "224.0.0.251:5353") == false)
        #expect(policy.shouldCapture(remoteEndpoint: "192.168.1.254:53") == false)
        #expect(policy.shouldCapture(remoteEndpoint: "10.0.0.5:80") == false)
        #expect(policy.shouldCapture(remoteEndpoint: "93.184.216.34:443"))
    }
}

import Testing
import Foundation
import Network
import CryptoKit
@testable import UpLinkKit

// SYMPTOM: a session established over AWDL, carried real traffic, reported
// `egress: Cellular` — and died 26 seconds later. Then ~97 seconds with nothing,
// until Wi-Fi was reconnected, at which point the phone got back in immediately.
//
// Nothing in the bridge's own log blamed the bridge. The cause was in the
// kernel, which decides AWDL's airtime from how many active AWDL sockets it can
// see. Two seconds before the session died:
//
//     monitorAWDLState: Active Sockets false ... SocketsActive 0
//     setScheduleState: reason:DiscoveryTimeout sc:Idle and force:YES
//     LQM-WiFi:AWDL State #16 Idle(3)
//
// and at the moment a later session worked:
//
//     monitorAWDLState: Active Sockets true ... SocketsActive 1
//     setScheduleState: reason:UserTriggered sc:Infra Priority
//
// The only difference was the address family the phone dialled:
//
//     169.254.203.164:55881            -> SocketsActive 0, dead in 26s
//     fe80::2063:e4ff:fed6:7ce0%awdl0  -> SocketsActive 1, Infra Priority
//
// An IPv4 link-local socket is not attributed to `awdl0`, so the kernel puts
// AWDL to sleep while we are sitting on it. Network.framework had picked a
// technically-valid address that could not do the job — the same shape as the
// earlier `pdp_ip0` bug that `peerLinkProhibitedInterfaces` guards against.

@Suite("Regression: the peer-to-peer link must be IPv6")
struct PeerLinkAddressFamilyRegressionTests {

    private func ipOptions(_ parameters: NWParameters) -> NWProtocolIP.Options? {
        parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options
    }

    @Test("A peer-to-peer session will not open an IPv4 link-local socket")
    func sessionIsIPv6OnlyOverPeerToPeer() throws {
        let parameters = TransportParameters.session(
            psk: SymmetricKey(size: .bits256),
            identity: "test",
            profile: .peerToPeer
        )
        let ip = try #require(ipOptions(parameters))
        #expect(
            ip.version == .v6,
            "the peer link may still choose IPv4 link-local — the kernel does not count that as an AWDL socket, so it drops AWDL to Idle and the session dies within about half a minute"
        )
    }

    @Test("The listener will not accept one either")
    func listenerIsIPv6OnlyOverPeerToPeer() throws {
        let parameters = TransportParameters.listener(
            sessionKeys: [("phone", SymmetricKey(size: .bits256))],
            pairingKey: nil,
            profile: .peerToPeer
        )
        let ip = try #require(ipOptions(parameters))
        #expect(
            ip.version == .v6,
            "a listener that still accepts IPv4 link-local lets the phone open exactly the socket the kernel will not count"
        )
    }

    // The constraint is specific to AWDL, and must not leak into the fallback.
    // `.localLink` is the rung that exists for a shared network, a hotspot, or a
    // cable, where IPv4 is ordinary and forbidding it would remove the escape
    // hatch rather than fix anything.
    @Test("The local-link fallback stays dual-stack")
    func localLinkIsUnconstrained() throws {
        let session = TransportParameters.session(
            psk: SymmetricKey(size: .bits256),
            identity: "test",
            profile: .localLink
        )
        let listener = TransportParameters.listener(
            sessionKeys: [("phone", SymmetricKey(size: .bits256))],
            pairingKey: nil,
            profile: .localLink
        )
        #expect(try #require(ipOptions(session)).version == .any,
                "the local-link fallback was constrained to one address family")
        #expect(try #require(ipOptions(listener)).version == .any,
                "the local-link fallback was constrained to one address family")
    }

    // Guards the reasoning, not just the setting: pinning to IPv6 is only safe
    // because the peer link is a local link, and every local link on an Apple
    // platform has an IPv6 link-local address. If the peer-to-peer profile ever
    // stops meaning "local link", this assumption has to be revisited.
    @Test("Cellular remains prohibited on the peer link")
    func cellularStaysProhibited() {
        for profile in TransportProfile.allCases {
            let parameters = TransportParameters.session(
                psk: SymmetricKey(size: .bits256),
                identity: "test",
                profile: profile
            )
            #expect(
                parameters.prohibitedInterfaceTypes?.contains(.cellular) == true,
                "\(profile) would let the peer link pin itself to pdp_ip0, which reports ready and carries nothing"
            )
        }
    }
}

import Testing
import Foundation
import Network
import CryptoKit
@testable import UpLinkKit

// SYMPTOM: with the Mac's Wi-Fi off and Personal Hotspot off — the exact setup
// the product exists for — the Mac had no internet at all. The phone's browser
// found the Mac over AWDL and resolved it (`nw_resolver_bonjour_resolve_callback
// ... name=…MacBook Air._uplink._tcp.local. port=59175`), so discovery was not
// the problem. But no bytes ever crossed the peer link, and `wifip2pd` reported
// the AWDL datapath idle for tens of minutes at a stretch:
//
//     wifip2pd <Error>: Last TTR 8 minutes leak Browse: _uplink,
//       browses: _uplink, advertises:  and services count: 2
//       no Tx/Rx for 23 minutes/23 minutes
//
// The Mac therefore never got a session, `hasSession` stayed false,
// `handleNewFlow` correctly declined every flow, and with no Wi-Fi there was no
// other path — so the Mac was simply offline.
//
// CAUSE: the peer link's `NWParameters` constrained nothing. The connection to
// the Mac is a *local* link by definition — AWDL, a shared Wi-Fi network, the
// phone's own hotspot, or USB — and can never be reached through the carrier.
// But with cellular up, Network.framework counted `pdp_ip0` as a satisfiable
// path for it and pinned the connection there, then actively suppressed the
// link-local AWDL path that was the only one that could carry data:
//
//     [C1 IPv4#8490d629:59175 ready parent-flow (satisfied (Path is satisfied),
//      interface: pdp_ip0[endc_sub6], scoped, ipv4, ipv6, dns, uses cell, …)]
//      suppressing better path notification
//      (comparing …MacBook Air._uplink._tcp.local. to 169.254.135.159:59175)
//
// A connection to a 169.254/16 link-local address scoped to the cellular radio
// reports `ready` and then carries nothing, which is why this presented as a
// silent dead link rather than an error.
//
// This never showed up over USB or shared Wi-Fi, because there the peer link
// and the working path happened to coincide.

@Suite("Regression: the peer link must never be routed over cellular")
struct PeerLinkInterfaceRegressionTests {

    private let psk = SymmetricKey(size: .bits256)

    /// The dialing side — the phone connecting out to the Mac. This is the one
    /// the field failure was observed on.
    @Test("Session parameters prohibit cellular")
    func sessionProhibitsCellular() {
        for profile in TransportProfile.allCases {
            let parameters = TransportParameters.session(
                psk: psk, identity: "regression", profile: profile
            )
            #expect(
                (parameters.prohibitedInterfaceTypes ?? []).contains(.cellular),
                "\(profile) session parameters must exclude the cellular radio"
            )
        }
    }

    /// The Mac's listener. A Mac has no cellular radio today, but the profile
    /// is shared code and an iPad build would inherit the same defect.
    @Test("Listener parameters prohibit cellular")
    func listenerProhibitsCellular() {
        for profile in TransportProfile.allCases {
            let parameters = TransportParameters.listener(
                sessionKeys: [("regression", psk)],
                pairingKey: nil,
                profile: profile
            )
            #expect(
                (parameters.prohibitedInterfaceTypes ?? []).contains(.cellular),
                "\(profile) listener parameters must exclude the cellular radio"
            )
        }
    }

    /// Pairing runs over the same local link and would strand a first-time user
    /// in exactly the same way — with no paired device, there is no fallback at
    /// all.
    @Test("Pairing parameters prohibit cellular")
    func pairingProhibitsCellular() throws {
        let code = try PairingCode(digits: "123456")
        for profile in TransportProfile.allCases {
            let parameters = TransportParameters.pairing(
                code: code, salt: Data(repeating: 7, count: 16), profile: profile
            )
            #expect(
                (parameters.prohibitedInterfaceTypes ?? []).contains(.cellular),
                "\(profile) pairing parameters must exclude the cellular radio"
            )
        }
    }

    /// Prohibiting cellular must not cost us the peer-to-peer path — that is
    /// the whole transport when there is no Wi-Fi network to share.
    @Test("Prohibiting cellular leaves AWDL intact")
    func peerToPeerStillEnabled() {
        let parameters = TransportParameters.session(
            psk: psk, identity: "regression", profile: .peerToPeer
        )
        #expect(parameters.includePeerToPeer)
        #expect((parameters.prohibitedInterfaceTypes ?? []).contains(.cellular))
    }
}

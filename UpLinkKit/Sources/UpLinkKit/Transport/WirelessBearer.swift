import Foundation
import Network

/// Which link carries the peer connection between the Mac and the phone.
///
/// The bearer owns one decision beyond its own name: **the interface it rides
/// on is the interface destination dials must refuse.**
///
/// `CellularDialer` has always prohibited `.wiredEthernet`, because plugging
/// the phone into the Mac gives the phone a wired interface, and a Mac with any
/// route to share turns the bridge into a loop — Mac to phone and straight back
/// to the Mac. The user bypasses nothing, and the egress report says so only
/// after the fact. The wireless bearer recreates that hazard exactly, one
/// interface over: the phone is now associated to a network the Mac hosts.
///
/// Keeping the rule here rather than as a literal in the dialer is what stops
/// the two from drifting apart when a bearer is added — which is the shape of
/// defect this codebase has already recorded more than once.
public enum WirelessBearer: String, Sendable, CaseIterable, Equatable {

    /// The Mac hosts an access point with nothing behind it, sourced from the
    /// product's own dead-end route tunnel. The target.
    case hostedAP

    /// AWDL. Opportunistic only.
    ///
    /// macOS schedules AWDL around the infrastructure Wi-Fi link, and with the
    /// Mac associated to nothing the kernel logs `Infra link down, disable
    /// dynamic SDB` and stops its timers — a live session died within 400ms of
    /// that line and the phone took ~100s to get back in. Associated-to-nothing
    /// is the deployment target, so this can never be the primary bearer. See
    /// docs/REGRESSIONS.md.
    case peerToPeer

    /// The cable. Retained until the wireless path passes the traffic matrix.
    case usbmux

    public static var preferenceOrder: [WirelessBearer] { [.hostedAP, .peerToPeer, .usbmux] }

    /// Interfaces a proxied destination connection may never use.
    ///
    /// Loopback is deliberately absent: a destination on the phone's own
    /// loopback is not a way around the bridge, and banning it breaks every
    /// integration test that points "the internet" at a local server — which is
    /// how the datagram and refused-destination suites run without a network at
    /// all. Cellular is deliberately absent for the obvious reason.
    public var prohibitedEgressInterfaces: [NWInterface.InterfaceType] {
        switch self {
        case .hostedAP, .peerToPeer:
            // The peer link is Wi-Fi. Egress over Wi-Fi is egress back into the
            // Mac, or onto a network the user did not ask to be on.
            [.wifi, .wiredEthernet]
        case .usbmux:
            [.wiredEthernet]
        }
    }
}

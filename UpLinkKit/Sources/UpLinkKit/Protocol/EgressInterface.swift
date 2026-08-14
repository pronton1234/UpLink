import Foundation

/// Which physical interface a proxied stream actually left the phone on.
///
/// This exists so the Mac can tell the user the truth. The bridge's entire
/// value proposition is "your traffic exits over cellular"; if the phone
/// quietly falls back to its own Wi-Fi, the user sees an identical green
/// "Connected" state while getting none of the benefit. The phone therefore
/// reports the interface it observed on `NWConnection.currentPath` rather than
/// the interface it requested, and the Mac surfaces that verbatim.
public enum EgressInterface: UInt8, Sendable, Equatable, CaseIterable {
    case unknown = 0x00
    case cellular = 0x01
    case wifi = 0x02
    case wired = 0x03
    case loopback = 0x04
    case other = 0x05

    /// Whether this interface delivers what the user turned the bridge on for.
    public var isUnmeteredCellularEgress: Bool { self == .cellular }

    public var displayName: String {
        switch self {
        case .unknown: "Unknown"
        case .cellular: "Cellular"
        case .wifi: "Wi-Fi"
        case .wired: "Wired"
        case .loopback: "Loopback"
        case .other: "Other"
        }
    }
}

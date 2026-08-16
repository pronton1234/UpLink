import Foundation

/// What the phone's single control is offering to do.
///
/// **There is one switch on that screen, and it used to have three names.**
/// "Stop Bridging" while a Mac was connected, "Turn Off" while merely
/// listening, and "Turn On" when off — with the first two calling the same
/// function. Worse, the middle branch was keyed on the tunnel's `NEVPNStatus`
/// rather than on the app's own state, so tapping "Stop Bridging" flipped the
/// label to "Turn Off" for the second or two the tunnel took to actually stop.
/// Switching UpLink off looked like two presses of two different buttons.
///
/// Pulled out here for the reason ``LinkStatus`` was: the decision lived in the
/// iOS app target, which has no test target, so it was unverifiable and could
/// only be checked by physically arranging each state on a device. The bug was
/// not subtle — it was invisible.
public enum PhoneControl: Sendable, Equatable {
    case turnOn
    case turnOff
    /// Recovery from a failure. A different word because it is a different
    /// thing to do, not because a different thing happened to be connected.
    case tryAgain

    public var label: String {
        switch self {
        case .turnOn: "Turn On"
        case .turnOff: "Turn Off"
        case .tryAgain: "Try Again"
        }
    }

    /// Whether tapping it switches the bridge on. `false` means it switches off.
    public var switchesOn: Bool {
        switch self {
        case .turnOn, .tryAgain: true
        case .turnOff: false
        }
    }

    /// Whether it should be styled as destructive.
    public var isDestructive: Bool { self == .turnOff }
}

/// The phone's condition, as the user's own switch sees it.
///
/// Deliberately coarser than `BridgeState`: this is about the switch, and the
/// switch does not care which Mac is on the other end or how traffic is
/// egressing. That belongs on the dial.
public enum PhoneBridgeCondition: Sendable, Equatable {
    case needsPermission
    /// Switched off. Nothing is listening.
    case off
    /// On, and listening, with no Mac connected.
    case listening
    /// On, with a Mac bridging through us.
    case bridging
    case failed
}

public enum PhoneControlResolver {

    public static func control(for condition: PhoneBridgeCondition) -> PhoneControl {
        switch condition {
        case .failed:
            return .tryAgain
        case .off, .needsPermission:
            // Permission is requested at the moment the user first asks to
            // connect, so the offer is the same: turn it on.
            return .turnOn
        case .listening, .bridging:
            // THE FIX, AS ONE LINE. A Mac arriving or leaving is status, not a
            // change of mode, and must not change the word on the switch.
            return .turnOff
        }
    }
}

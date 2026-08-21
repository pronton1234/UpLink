import Foundation

/// What the cable looks like from the app's side.
///
/// Mirrors the Mac app's `USBRelayState` as a plain value so the decision below
/// can be made — and tested — without an app, a menu bar, or a cable.
public enum LinkPresence: Sendable, Equatable {
    case noDevice
    /// The Mac is not hosting its access point, so there is no link at all.
    /// The only cause in this whole matrix the user can personally fix.
    case accessPointDown
    /// The access point is up and no phone has been discovered on it.
    case noPeerDiscovered
    case attachedNotAnswering
    /// Attached and answering on one of the UpLink ports.
    case answering(udid: String)
    case failed(String)
}

/// The honest name for "not bridging right now".
///
/// **This exists as a pure function because the UI was the thing asked for.**
/// "Not bridging" has four causes with completely different remedies — no
/// cable, cable but nothing answering, answering but unpaired, and switched off
/// by hand — and collapsing them is what made the old menu bar say "Waiting for
/// iPhone" at a user whose iPhone was plugged in and sitting right there.
///
/// The decision used to live inside the app target, where nothing could reach
/// it: the Mac app has no test target, so every one of these arms was
/// unverifiable and the only way to see them was to physically arrange each
/// state. Pulled out here, the whole matrix is provable in milliseconds.
public enum LinkStatus: Sendable, Equatable {
    case accessPointDown
    case waitingForPhone
    case waitingForCable
    case deviceNotResponding
    case deviceNotPaired
    case connecting
    /// The phone answers and refuses this Mac's key — its side of the pairing
    /// is gone. Distinct from `deviceNotPaired`, which is a Mac that never had
    /// one: here BOTH sides think differently, and only re-pairing fixes it.
    case pairingLost
    case switchedOff
    case failed(String)

    /// - Parameters:
    ///   - presence: what the relay currently sees.
    ///   - isPaired: whether this Mac holds a pairing for the attached device.
    ///     A record with no UDID counts, because it adopts the first device it
    ///     sessions with — refusing it would make that migration impossible.
    ///   - userDisconnected: whether the user switched the bridge off by hand.
    /// - Parameter pairingRefused: the phone answered and rejected our key on
    ///   several consecutive dials. Checked ahead of everything except an
    ///   explicit switch-off, because retrying cannot fix it and "Connecting…"
    ///   forever gives the user nothing to act on.
    public static func resolve(
        presence: LinkPresence,
        isPaired: Bool,
        userDisconnected: Bool,
        pairingRefused: Bool = false
    ) -> LinkStatus {
        // Checked first, and only when a cable is actually answering. Saying
        // "Switched off" with nothing plugged in would be true but useless —
        // the thing to fix is the cable, and that is what should be on screen.
        // Ahead of everything, including an explicit switch-off, and for the
        // same reason that switch-off is itself gated on something answering:
        // with no access point there is nothing to switch off, and naming the
        // wrong cause is what this type exists to stop.
        if case .accessPointDown = presence { return .accessPointDown }
        if userDisconnected, case .answering = presence { return .switchedOff }
        if pairingRefused, case .answering = presence { return .pairingLost }

        switch presence {
        case .accessPointDown:
            return .accessPointDown
        case .noPeerDiscovered:
            return .waitingForPhone
        case .noDevice:
            return .waitingForCable
        case .attachedNotAnswering:
            return .deviceNotResponding
        case let .failed(reason):
            return .failed(reason)
        case .answering:
            // Answering and paired means the dial is in flight; answering and
            // unpaired means the user has something to do.
            return isPaired ? .connecting : .deviceNotPaired
        }
    }

    /// The line the user reads. Kept next to the decision so a new case cannot
    /// be added without a sentence to go with it.
    public var headline: String {
        switch self {
        case .accessPointDown: "UpLink network is not running"
        case .waitingForPhone: "Waiting for iPhone to join"
        case .waitingForCable: "Waiting for USB connection"
        case .deviceNotResponding: "iPhone connected — not answering"
        case .deviceNotPaired: "iPhone connected — not paired"
        case .connecting: "Connecting…"
        case .pairingLost: "iPhone no longer recognises this Mac"
        case .switchedOff: "Switched off"
        case .failed: "Something went wrong"
        }
    }

    /// What to do about it. Every arm names an action, because a status line
    /// that describes a problem without naming its remedy is the thing this
    /// type was written to replace.
    public var detail: String {
        switch self {
        case .accessPointDown: "Open UpLink on this Mac and turn the network back on"
        case .waitingForPhone: "Open UpLink on your iPhone and tap Connect"
        case .waitingForCable: "Connect your iPhone to this Mac with a cable"
        case .deviceNotResponding: "Open UpLink on your iPhone and turn the bridge on"
        case .deviceNotPaired: "Show a pairing code, then type it on your iPhone"
        case .connecting: "Opening the link over the cable"
        case .pairingLost: "Pair again — reinstalling UpLink on iPhone erases its half"
        case .switchedOff: "Choose Reconnect to start bridging again"
        case let .failed(reason): reason
        }
    }
}

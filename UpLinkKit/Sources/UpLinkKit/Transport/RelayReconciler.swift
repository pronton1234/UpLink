import Foundation

/// What the relay should do next, given what is true right now.
///
/// **This is level-triggered on purpose, and that is the whole point.**
///
/// The relay began as edge-triggered: react to a usbmux attach event, probe
/// once, remember the answer. Every failure it had was a missed or mistimed
/// edge — an attach that arrived before the extension had a client, a probe run
/// a second before the phone finished binding, a device that re-enumerated
/// while a retry loop held the old id, a retry loop that cancelled itself. Each
/// was fixed by reacting to one more edge, and the next gap was always the case
/// that list left out.
///
/// A level-triggered design cannot have that class of bug. Nothing is
/// remembered that is not re-derived: each tick asks what is attached, what is
/// answering, and what we have a listener for, and returns the one action that
/// closes the gap. A missed event costs a tick. It cannot strand anything.
///
/// Pure, so every transition below is provable without a cable, a phone, or a
/// daemon — which matters because these are exactly the paths hardware testing
/// reaches only by accident.
public enum RelayAction: Sendable, Equatable {
    /// Nothing attached. Tear down anything we were holding.
    case standDown
    /// Attached, but no UpLink port answered. Keep looking.
    case waitForPhone(udid: String)
    /// Attached and answering, with no usable relay. Open one.
    case openRelay(device: USBDevice, answeringPort: UInt16)
    /// Already relaying correctly. Do nothing.
    case hold
}

/// What the relay currently holds, as a value.
public struct RelayHolding: Sendable, Equatable {
    public let udid: String?
    public let listenerPort: UInt16?

    public init(udid: String? = nil, listenerPort: UInt16? = nil) {
        self.udid = udid
        self.listenerPort = listenerPort
    }

    public static let nothing = RelayHolding()
}

public enum RelayReconciler {

    /// - Parameters:
    ///   - attached: cabled devices usbmuxd reports **right now**. `nil` means
    ///     the enumeration itself failed, which is NOT evidence the cable is
    ///     out — see below.
    ///   - holding: what the relay currently has open.
    ///   - answeringPort: which UpLink port responded, or nil if neither did.
    ///     Only meaningful when something is attached.
    public static func next(
        attached: [USBDevice]?,
        holding: RelayHolding,
        answeringPort: UInt16?
    ) -> RelayAction {
        // A FAILED ENUMERATION IS NOT A DETACHMENT.
        //
        // usbmuxd can be briefly busy, and treating "I could not ask" as "the
        // cable is out" would drop a working bridge for a transient error and
        // then have to rebuild it. The previous conclusion stands until
        // something positively contradicts it.
        guard let attached else { return .hold }

        guard let device = attached.first else { return .standDown }

        guard let answeringPort else { return .waitForPhone(udid: device.udid) }

        // Holding a relay for this exact device, with a listener still bound.
        if holding.udid == device.udid, holding.listenerPort != nil {
            return .hold
        }

        // Covers the case that broke on hardware: the device re-enumerated, so
        // the udid matches nothing we hold, and a new relay is needed even
        // though a listener is open.
        return .openRelay(device: device, answeringPort: answeringPort)
    }
}

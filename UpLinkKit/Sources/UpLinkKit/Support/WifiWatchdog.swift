import Foundation

/// A snapshot of one network path, reduced to what the watchdog cares about.
///
/// Deliberately a plain value rather than `NWPath`, so the decision logic can
/// be unit-tested exhaustively without conjuring real network conditions.
public struct WatchdogPath: Sendable, Equatable {
    /// Whether a usable Wi-Fi path exists.
    public var hasSatisfiedWifi: Bool
    /// Name of the Wi-Fi interface, e.g. `en0`.
    public var wifiInterfaceName: String?
    /// Whether that Wi-Fi path is a captive portal / has no real internet.
    public var isConstrained: Bool

    public init(hasSatisfiedWifi: Bool, wifiInterfaceName: String? = nil, isConstrained: Bool = false) {
        self.hasSatisfiedWifi = hasSatisfiedWifi
        self.wifiInterfaceName = wifiInterfaceName
        self.isConstrained = isConstrained
    }
}

public enum WatchdogAction: Sendable, Equatable {
    /// Begin the debounce countdown.
    case startTimer
    /// Cancel any countdown in progress.
    case cancelTimer
    /// Nothing changes.
    case none
}

/// Decides when to suggest the user drop the bridge in favour of Wi-Fi.
///
/// The rule from the spec is simple — a stable Wi-Fi path for two minutes while
/// the bridge is up earns one notification. The subtlety, and the reason this
/// is a separate testable type, is that when the Mac reaches the phone over the
/// phone's *own* Personal Hotspot, that hotspot appears as a perfectly good
/// satisfied Wi-Fi path. A naive implementation immediately tells the user
/// "Wi-Fi is available, disconnect to save battery!" about the very link it is
/// bridging over.
public struct WifiWatchdog: Sendable {

    /// Two minutes, per the spec: long enough that walking past a café's Wi-Fi
    /// does not fire it.
    public static let debounce: TimeInterval = 120

    /// The interface currently carrying traffic to the phone, if any. Paths on
    /// this interface are ignored.
    public var bridgeInterfaceName: String?

    private var bridgeActive = false
    private var timerRunning = false

    public init(bridgeInterfaceName: String? = nil) {
        self.bridgeInterfaceName = bridgeInterfaceName
    }

    public var isTimerRunning: Bool { timerRunning }

    /// The watchdog is completely idle while the bridge is off — no monitoring,
    /// no timers, zero background evaluation.
    public mutating func setBridgeActive(_ active: Bool) -> WatchdogAction {
        bridgeActive = active
        guard !active else { return .none }
        guard timerRunning else { return .none }
        timerRunning = false
        return .cancelTimer
    }

    /// Feeds a new path observation in and returns what the caller should do.
    public mutating func handle(_ path: WatchdogPath) -> WatchdogAction {
        guard bridgeActive else {
            guard timerRunning else { return .none }
            timerRunning = false
            return .cancelTimer
        }

        guard qualifiesAsAlternative(path) else {
            guard timerRunning else { return .none }
            timerRunning = false
            return .cancelTimer
        }

        guard !timerRunning else { return .none }
        timerRunning = true
        return .startTimer
    }

    /// Whether this path is genuinely a *different* network worth switching to.
    private func qualifiesAsAlternative(_ path: WatchdogPath) -> Bool {
        guard path.hasSatisfiedWifi else { return false }

        // A captive portal or otherwise constrained link is not an alternative
        // worth dropping cellular for.
        guard !path.isConstrained else { return false }

        // The critical exclusion: never suggest switching to the link we are
        // already bridging over.
        if let bridgeInterfaceName, path.wifiInterfaceName == bridgeInterfaceName {
            return false
        }

        return true
    }

    /// Called when the debounce elapses. Returns whether to actually notify —
    /// false if conditions changed while the clock ran.
    public mutating func timerFired() -> Bool {
        guard bridgeActive, timerRunning else { return false }
        timerRunning = false
        return true
    }
}

import Foundation

/// Backoff schedule for re-establishing a dropped session.
///
/// Network framework provides nothing here — a dropped connection is simply
/// dropped — so reconnection is entirely the app's problem. The shape matters:
/// a bridge that gives up after one failure is useless when the cable is
/// knocked loose and pushed back in, and one that retries in a tight loop
/// drains the phone.
///
/// Over the cable the common failure is different from the AWDL era and the
/// numbers should reflect it. There is no "briefly out of range": the device is
/// either attached or it is not, and detachment is reported explicitly by
/// `usbmuxd` rather than inferred from silence. What remains is the short
/// window where the phone's extension is restarting and nothing is bound to the
/// port yet, so the schedule wants to be quick and to give up scaling early.
public struct ReconnectPolicy: Sendable, Equatable {

    public let baseDelay: TimeInterval
    public let maxDelay: TimeInterval

    private var consecutiveFailures = 0

    public init(baseDelay: TimeInterval = 1, maxDelay: TimeInterval = 30) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    public var attempt: Int { consecutiveFailures }

    /// Records a failed attempt and returns how long to wait before the next.
    ///
    /// Exponential, capped. The cap matters more than the growth rate.
    public mutating func recordFailure() -> TimeInterval {
        let delay = min(baseDelay * pow(2, Double(consecutiveFailures)), maxDelay)
        consecutiveFailures += 1
        return delay
    }

    /// A session came up. The next drop starts from the bottom of the schedule
    /// again, rather than inheriting the backoff from an unrelated earlier one.
    public mutating func recordSuccess() {
        consecutiveFailures = 0
    }
}

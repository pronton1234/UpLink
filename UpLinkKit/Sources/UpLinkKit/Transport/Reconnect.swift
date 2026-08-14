import Foundation

/// Finds a specific peer among whatever discovery currently sees.
///
/// Always matches on the long-term key fingerprint, never on the endpoint. On
/// a local link an address is close to meaningless: the phone's hotspot hands
/// out a new one on every reconnect, AWDL endpoints are ephemeral, and DHCP
/// churns. A fingerprint is the only stable identity either device has.
public enum PeerResolver {

    public static func match(_ peers: [DiscoveredPeer], fingerprint: String) -> DiscoveredPeer? {
        // If the same Mac is visible over more than one transport, prefer the
        // one earlier in the preference order.
        let candidates = peers.filter { $0.fingerprint == fingerprint }
        for profile in TransportProfile.preferenceOrder {
            if let match = candidates.first(where: { $0.profile == profile }) { return match }
        }
        return candidates.first
    }

    /// Waits for the paired Mac to appear, giving up after `timeout`.
    ///
    /// **The deadline must be enforced independently of the stream.** An earlier
    /// version checked the clock inside `for await`, which only runs when the
    /// browser publishes a *new* result. A browser that has nothing to report
    /// publishes once, at subscription, and then stays silent — so the check
    /// never ran again and this waited forever.
    ///
    /// That turned every dropped session into a permanent outage: the reconnect
    /// loop below can only retry once this returns, so the extension sat wedged
    /// in an unbounded await, the Mac never saw another connection attempt, and
    /// with no Wi-Fi the Mac simply had no network until the tunnel was
    /// restarted by hand. Observed as a session ending at 22:33:52 followed by
    /// eight minutes of complete silence from a phone that was sitting right
    /// next to the Mac, still advertising.
    ///
    public static func firstMatch(
        in peers: AsyncStream<[DiscoveredPeer]>,
        fingerprint: String,
        timeout: TimeInterval
    ) async -> DiscoveredPeer? {
        await firstMatch(in: peers, fingerprint: fingerprint, timeout: timeout) {
            try await Task.sleep(for: .seconds($0))
        }
    }

    /// As above, with the clock injected.
    ///
    /// Deliberately an overload rather than a defaulted parameter: an escaping
    /// `@Sendable async` closure used as a *default argument* is emitted into
    /// the caller and miscompiles here — every test that relied on the default
    /// aborted with "freed pointer was not the last allocation", while the same
    /// call passing the closure explicitly ran clean.
    ///
    /// - Parameter sleep: injectable so the timeout is tested in milliseconds
    ///   rather than by waiting out a real one.
    public static func firstMatch(
        in peers: AsyncStream<[DiscoveredPeer]>,
        fingerprint: String,
        timeout: TimeInterval,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void
    ) async -> DiscoveredPeer? {
        await withTaskGroup(of: DiscoveredPeer?.self) { group in
            group.addTask {
                for await found in peers {
                    if let match = match(found, fingerprint: fingerprint) { return match }
                }
                return nil
            }
            // The racing arm. Whichever finishes first wins; the other is
            // cancelled, which is what actually bounds the wait.
            group.addTask {
                try? await sleep(timeout)
                return nil
            }

            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}

/// Backoff schedule for re-establishing a dropped session.
///
/// Network framework provides nothing here — a dropped connection is simply
/// dropped — so reconnection is entirely the app's problem. The shape matters:
/// a bridge that gives up after one failure is useless when the user walks
/// between rooms, and one that retries in a tight loop drains the phone.
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
    /// Exponential, capped. The cap matters more than the growth rate: the
    /// common failure is the user being briefly out of range, and they should
    /// never wait more than ``maxDelay`` after walking back.
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

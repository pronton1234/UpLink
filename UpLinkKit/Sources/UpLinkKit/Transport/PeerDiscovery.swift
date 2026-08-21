import Foundation
import Network

/// The most recently observed endpoint for the phone, with an expiry.
///
/// **Deliberately holds the decision, not the browser.** Wiring to `NWBrowser`
/// lives in the app, where nothing can test it. What is testable — and what was
/// wrong on hardware — is whether an old observation still counts as current.
///
/// From `docs/REGRESSIONS.md`, 2026-08-14: a cached endpoint from before a
/// radio change was yielded unconditionally and treated as current, so every
/// retry burned the full connect timeout dialling something that no longer
/// existed, at exactly the moment the device was trying to recover.
///
/// The window is injectable so that expiry is provable in milliseconds rather
/// than by reconfiguring a radio — and because the first version of that test
/// used a never-started discovery, whose state is empty regardless, and passed
/// with the fix deleted.
public final class PeerDiscovery: @unchecked Sendable {

    private let stalenessWindow: TimeInterval
    private let lock = NSLock()
    private var latest: (endpoint: NWEndpoint, seen: Date)?

    /// - Parameter stalenessWindow: how long an observation stays current.
    public init(stalenessWindow: TimeInterval = 15) {
        self.stalenessWindow = stalenessWindow
    }

    public func record(_ endpoint: NWEndpoint, at date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        latest = (endpoint, date)
    }

    /// The peer to dial, or nil if the last sighting is too old to trust.
    public func current(now: Date = Date()) -> NWEndpoint? {
        lock.lock()
        defer { lock.unlock() }
        guard let latest else { return nil }
        guard now.timeIntervalSince(latest.seen) < stalenessWindow else { return nil }
        return latest.endpoint
    }

    /// Drops the peer regardless of age.
    ///
    /// A radio change invalidates every cached endpoint at once, and the
    /// browser can take seconds to say so. This is how the Mac stops dialling a
    /// corpse in the meantime.
    public func forget() {
        lock.lock()
        defer { lock.unlock() }
        latest = nil
    }
}

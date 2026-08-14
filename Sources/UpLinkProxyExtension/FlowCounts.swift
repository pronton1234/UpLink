import Foundation

/// How many flows each app is holding, safe to touch from any thread.
///
/// The counts are incremented on NetworkExtension's own thread inside
/// `handleNewFlow` — which must answer synchronously and so cannot await an
/// actor — and decremented from a detached task when the flow's pump ends. That
/// is two threads writing the same storage.
///
/// An unguarded `nonisolated(unsafe)` dictionary was tried first and crashed the
/// extension with SIGSEGV about two seconds into every session: concurrent
/// mutation of a Swift `Dictionary` corrupts its heap storage rather than
/// producing a merely stale value. A lock is the whole fix; the critical
/// sections are three lines of arithmetic and are never contended for long.
final class FlowCounts: @unchecked Sendable {

    private var counts: [String: Int] = [:]
    private let lock = NSLock()

    func increment(_ app: String?) {
        guard let app else { return }
        lock.lock()
        defer { lock.unlock() }
        counts[app, default: 0] += 1
    }

    func decrement(_ app: String?) {
        guard let app else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let current = counts[app] else { return }
        if current <= 1 { counts.removeValue(forKey: app) } else { counts[app] = current - 1 }
    }

    func snapshot() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        counts.removeAll()
    }
}

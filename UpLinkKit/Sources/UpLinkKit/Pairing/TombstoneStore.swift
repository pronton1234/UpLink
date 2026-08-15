import Foundation

/// Keeps revocation tombstones across an extension restart.
///
/// **A restart is exactly when a revoked peer comes back to life.** The
/// listener's tombstones live in memory, so without this a peer removed while
/// it was disconnected would be forgotten the moment the extension is
/// relaunched — and the next time it dialled it would either be refused with
/// nothing to explain why, or, if its record somehow survived, accepted again.
///
/// The app group rather than the keychain: this is not a secret, it expires on
/// its own within a day, and both the app and the extension can read it without
/// any of the access-group subtleties that make the keychain awkward here.
/// `@unchecked` because `UserDefaults` predates `Sendable` and is documented as
/// thread-safe; the two accessors here are a single read and a single write.
public struct TombstoneStore: @unchecked Sendable {

    private let defaults: UserDefaults?
    private let key = "revocation-tombstones"

    public init(appGroup: String = PhoneDiagnosticLog.appGroup) {
        self.defaults = UserDefaults(suiteName: appGroup)
    }

    /// Injectable so the round trip is testable without an app group, which a
    /// test process does not have.
    public init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    public func load() -> RevocationTombstones {
        guard let data = defaults?.data(forKey: key),
              var restored = try? JSONDecoder().decode(RevocationTombstones.self, from: data)
        else { return RevocationTombstones() }
        // Expired on read as well as on write: a process that has been asleep
        // for a day should not resurrect a tombstone that timed out while it
        // was not running.
        restored.expire()
        return restored
    }

    public func save(_ tombstones: RevocationTombstones) {
        guard let data = try? JSONEncoder().encode(tombstones) else { return }
        defaults?.set(data, forKey: key)
    }
}

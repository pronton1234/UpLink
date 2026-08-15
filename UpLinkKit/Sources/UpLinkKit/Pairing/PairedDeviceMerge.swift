import Foundation

/// Decides which devices the app should persist after asking the extension what
/// it knows.
///
/// ## Why this is a type rather than four lines in the app
///
/// The Mac app's keychain is durable; the extension's directory is in memory and
/// re-seeded from a snapshot. So the app polls the extension, and anything the
/// extension knows that the app does not is treated as a new pairing and written
/// to the keychain.
///
/// That rule is additive, and additive is wrong in two ways that both present as
/// "I removed the device and it came back":
///
///   1. **It races the Remove button.** The poll sends its request, the user
///      removes a device, the reply arrives listing it, and the device is
///      "unknown" — so it is written straight back.
///   2. **It re-adds resurrections.** If the extension restarts and re-seeds
///      from a stale snapshot, the removed device reappears in its memory, and
///      the next poll copies it back into the keychain.
///
/// Both are fixed by remembering what was deliberately removed, briefly, and
/// refusing to re-learn it. The window only has to outlast an in-flight poll and
/// an extension restart, not the pairing.
///
/// It lives in the kit because the app targets have no tests, and this rule is
/// exactly the kind that looks obviously right and is not.
public struct PairedDeviceMerge: Sendable {

    /// Long enough to cover an in-flight poll and an extension restart, short
    /// enough that a genuine re-pairing minutes later is never blocked.
    public static let forgetWindow: TimeInterval = 120

    private var removed: [String: Date] = [:]

    public init() {}

    /// Records a deliberate removal.
    public mutating func noteRemoved(_ fingerprint: String, at now: Date = Date()) {
        removed[fingerprint] = now
    }

    /// Forgets a removal, so a genuine re-pairing takes effect at once.
    ///
    /// Called when the user pairs the same device again: they have just said
    /// they want it, which outranks having said the opposite two minutes ago.
    public mutating func notePaired(_ fingerprint: String) {
        removed.removeValue(forKey: fingerprint)
    }

    public mutating func expire(at now: Date = Date()) {
        removed = removed.filter { now.timeIntervalSince($0.value) < Self.forgetWindow }
    }

    public func wasRecentlyRemoved(_ fingerprint: String, at now: Date = Date()) -> Bool {
        guard let when = removed[fingerprint] else { return false }
        return now.timeIntervalSince(when) < Self.forgetWindow
    }

    /// Which of the extension's devices the app should write to durable storage.
    public func devicesToPersist(
        reportedByExtension reported: [PairedDevice],
        alreadyKnown known: Set<String>,
        at now: Date = Date()
    ) -> [PairedDevice] {
        reported.filter { device in
            !known.contains(device.fingerprint)
                && !wasRecentlyRemoved(device.fingerprint, at: now)
        }
    }
}

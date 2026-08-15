import Foundation

/// Carries "the Mac has forgotten this phone" from the session that learned it
/// to the app's next status poll.
///
/// **Sticky, and cleared in exactly two places.** The notice arrives as the
/// session is ending, so a flag cleared with the session would never survive to
/// be read — the app polls *after* that, and the notice would be lost, leaving
/// the phone retrying forever against a Mac that no longer holds its key.
///
/// **But stickiness alone is the other half of the bug.** The flag is checked
/// before anything else on every poll, so once set it answers "unpaired" for
/// the life of the extension process. Re-pair, and the first poll tells the app
/// to delete the pairing it has just made — an unbreakable re-pair loop, and
/// what "re-pairing fails and I have to retry several times" actually was.
///
/// So clearing belongs to the state machine, not to a caller who has to
/// remember: establishing a session at all means the Mac accepted us, which
/// means we are paired, which means any earlier revocation is stale.
public actor UnpairNotice {

    private var pending: String?

    public init() {}

    public var isPending: Bool { pending != nil }

    /// A Mac told us it has forgotten this phone.
    public func note(fingerprint: String) {
        pending = fingerprint
    }

    /// A session was established, so any earlier revocation is stale.
    ///
    /// Call this on `sessionStarted`, not on `sessionEnded`: the point is that
    /// a peer accepting our handshake is proof the pairing is live again.
    public func sessionEstablished() {
        pending = nil
    }

    /// Reads and consumes the notice. The app is the only side that can act on
    /// it, and this is its one chance.
    public func take() -> String? {
        defer { pending = nil }
        return pending
    }
}

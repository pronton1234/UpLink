import Foundation

/// Everything mutable about the phone's side of a live session.
///
/// ## Why this is in the kit rather than in the extension
///
/// It used to be a `private actor` inside `PacketTunnelProvider`, where nothing
/// could test it — and it had a bug that survived every round of on-device
/// testing precisely because it presents as a UI problem rather than a
/// networking one.
///
/// `connectOnce` set the channel and never cleared it. It cleared the responder
/// in a `defer`, but the channel had no such thing, and `isConnected` was
/// `channel != nil`. So once the phone had connected even once, it reported
/// itself connected for the life of the tunnel — through the session ending,
/// through every failed retry, through the Mac having no session at all.
///
/// Because the responder *was* cleared, `observedEgress` fell back to
/// `.unknown`, and the phone drew "Connected — waiting for your Mac to send
/// something." That is a screen saying the bridge is fine while the Mac has
/// nothing, which sent two rounds of debugging looking at the wrong side.
///
/// Keeping the state here, with `runningSession` owning the whole lifetime, is
/// what makes "the phone believes it is connected" a testable claim.
public actor PhoneSessionState {

    private var channel: NWConnectionChannel?
    private var task: Task<Void, Never>?
    private var responder: BridgeResponder?

    /// Set when the Mac says it has forgotten this phone.
    ///
    /// Sticky across the session *ending*, because that is exactly when the app
    /// next asks: the notice arrives, the session tears down, and a flag that
    /// cleared with the session would never be seen.
    ///
    /// Cleared when a session *begins* — see ``runningSession``. Both halves are
    /// required and only the first was implemented, which left
    /// `clearUnpairedByPeer()` with no call sites at all. Since the flag is
    /// checked ahead of `isConnected` on every status poll, once set it answered
    /// "unpaired" for the life of the extension process: re-pair, and the first
    /// poll told the app to delete the pairing it had just made. That is an
    /// unbreakable re-pair loop, and it is what "re-pairing fails and I have to
    /// retry several times" actually was.
    public private(set) var wasUnpairedByPeer = false

    /// Which Mac the live session is with, so an unpair can be addressed.
    ///
    /// Without it the extension acted on whichever session was live, and
    /// deleting one Mac could revoke another.
    public private(set) var peerFingerprint: String?

    public init() {}

    public func setPeerFingerprint(_ fingerprint: String?) { peerFingerprint = fingerprint }

    public func noteUnpairedByPeer() { wasUnpairedByPeer = true }
    public func clearUnpairedByPeer() { wasUnpairedByPeer = false }

    /// Whether a session is actually live.
    ///
    /// A channel that has been closed is not a connection, and this is the
    /// question the UI is really asking. Holding a spent channel and answering
    /// "yes" is the bug this type exists to prevent.
    public var isConnected: Bool {
        get async {
            guard let channel else { return false }
            return await !channel.isFinished
        }
    }

    /// What the phone last observed about how traffic is actually leaving.
    public var observedEgress: EgressInterface? {
        get async { await responder?.observedEgress }
    }

    public func setTask(_ task: Task<Void, Never>?) { self.task = task }

    /// Runs one session, and guarantees the state is clean afterwards however
    /// it ends — returned, threw, or cancelled.
    ///
    /// The guarantee is the point. Callers had to remember to clear the channel
    /// on every exit path, and the one that mattered was missed.
    public func runningSession<Result>(
        channel: NWConnectionChannel,
        responder: BridgeResponder,
        body: () async throws -> Result
    ) async throws -> Result {
        // Establishing a session at all means the Mac accepted this phone's PSK,
        // which means the two are paired — so any earlier revocation is stale by
        // construction. Clearing here rather than at a call site is deliberate:
        // the one thing this type has already been burned by is a caller having
        // to remember an invariant.
        wasUnpairedByPeer = false
        self.channel = channel
        self.responder = responder
        defer {
            self.channel = nil
            self.responder = nil
        }
        return try await body()
    }

    /// Records a channel that is being dialled but has no session yet.
    ///
    /// Kept separate from `runningSession` so a connection that never completes
    /// its handshake can still be cancelled by `teardown`, without ever being
    /// reported to the UI as a session.
    public func setPendingChannel(_ channel: NWConnectionChannel?) {
        self.channel = channel
    }

    /// Best effort: tells the Mac this phone has forgotten it, if a session is
    /// still up to carry the notice.
    public func announceUnpaired() async {
        await responder?.announceUnpaired()
    }

    public func teardown() async {
        task?.cancel()
        task = nil
        responder = nil
        await channel?.close()
        channel = nil
    }
}

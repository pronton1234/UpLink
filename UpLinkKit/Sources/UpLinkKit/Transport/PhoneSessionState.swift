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
    /// Sticky across the session ending, because that is exactly when the app
    /// next asks: the notice arrives, the session tears down, and a flag that
    /// cleared with the session would never be seen.
    public private(set) var wasUnpairedByPeer = false

    public init() {}

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

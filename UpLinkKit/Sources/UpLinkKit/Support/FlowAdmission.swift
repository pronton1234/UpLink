import Foundation

/// The gate `handleNewFlow` consults.
///
/// One sentence, and it is the most important one in the codebase: **never
/// claim a flow you cannot service.** A transparent proxy sits in front of
/// every TCP and UDP flow on the machine, and returning `true` means "this
/// extension owns this connection" — the system will not deliver it, and the
/// app has no recourse beyond its own patience. Claiming a flow with nowhere to
/// send it kills it; doing that to every flow kills all networking on the Mac,
/// and because the extension outlives the app, quitting does not fix it.
///
/// Lives in the kit rather than the extension so the decision is testable
/// without a signed, notarized, user-approved system extension. It used to be
/// re-implemented in the test target instead, which meant the guards were
/// verified against a copy and changing the real `handleNewFlow` failed
/// nothing.
public struct FlowAdmission: Sendable {

    public var hasSession: Bool
    public var policy: CapturePolicy

    /// Signing identifier of the extension itself, so its own sockets can be
    /// recognised and declined.
    ///
    /// Structural rather than incidental: `LocalDatagramRelay` deliberately
    /// opens connections to destinations the policy excludes. Without this
    /// guard the relay's own socket would be claimed, handed back to the relay,
    /// and opened again — unbounded recursion with all networking down until
    /// the extension is torn down, which outlives the app and costs a reboot.
    public var ownSigningIdentifier: String

    /// How many flows one app may hold at once.
    ///
    /// SYMPTOM: a single app (`com.relay.mac`, whose embedded Tailscale
    /// reconnect-stormed when the Mac's default route changed) claimed 31,337
    /// flows in six minutes — about 87 a second. That saturated the one channel
    /// to the phone in 13 seconds, and from then on EVERY app on the machine
    /// failed, Chrome included: 30 flows opened against 31,423 failures.
    ///
    /// The mux already caps total streams at `Multiplexer.maxConcurrentStreams`
    /// (4,096), but a global cap is not fairness — it is first-come-first-served,
    /// which is precisely how one process took the bridge down for everything
    /// else.
    ///
    /// Deliberately generous. This is not for policing normal browsing: a busy
    /// browser sits in the low hundreds across all its helpers. It exists so no
    /// single process can consume the whole budget.
    public static let perAppFlowLimit = 512

    /// Flows currently held, by signing identifier.
    public var flowsPerApp: [String: Int] = [:]

    public init(
        hasSession: Bool,
        policy: CapturePolicy,
        ownSigningIdentifier: String = UpLinkIdentifiers.macProxyExtension,
        flowsPerApp: [String: Int] = [:]
    ) {
        self.hasSession = hasSession
        self.policy = policy
        self.ownSigningIdentifier = ownSigningIdentifier
        self.flowsPerApp = flowsPerApp
    }

    /// Whether to claim a TCP flow, which names exactly one destination.
    public func shouldClaim(
        remoteEndpoint: String,
        sourceSigningIdentifier: String? = nil
    ) -> Bool {
        guard admits(sourceSigningIdentifier) else { return false }
        return policy.shouldCapture(remoteEndpoint: remoteEndpoint)
    }

    /// Whether to claim a UDP flow, which names no destination at all.
    ///
    /// A `NEAppProxyUDPFlow` is a *session*: it carries datagrams to many hosts,
    /// so it must be claimed before any of them are known and the pump has to be
    /// able to service every one — including the datagrams the policy says must
    /// not be bridged, which go out this Mac's own interface instead.
    ///
    /// The consequence is that the only thing that can be judged here is who is
    /// asking. That is exactly why ``CapturePolicy/directApps`` exists: it is
    /// the sole way to keep a given app's UDP traffic off the bridge.
    public func shouldClaimDatagramSession(
        sourceSigningIdentifier: String? = nil
    ) -> Bool {
        admits(sourceSigningIdentifier)
    }

    /// The checks common to both, in the order they must happen.
    private func admits(_ sourceSigningIdentifier: String?) -> Bool {
        // The session check comes FIRST, and nothing may override it. A policy
        // that would otherwise say yes must not be able to outvote the absence
        // of anywhere to send the traffic.
        guard hasSession else { return false }
        guard sourceSigningIdentifier != ownSigningIdentifier else { return false }
        guard policy.shouldCapture(app: sourceSigningIdentifier) else { return false }
        return withinFlowLimit(sourceSigningIdentifier)
    }

    /// Whether this app is under its share of the stream budget.
    ///
    /// Declining is the kinder failure: the system then routes the flow
    /// normally, or fails it fast. Both beat claiming a flow that will die in
    /// the write — and beat starving every other app on the machine, which is
    /// what happened without this.
    public func withinFlowLimit(_ sourceSigningIdentifier: String?) -> Bool {
        guard let sourceSigningIdentifier else { return true }
        return (flowsPerApp[sourceSigningIdentifier] ?? 0) < Self.perAppFlowLimit
    }
}

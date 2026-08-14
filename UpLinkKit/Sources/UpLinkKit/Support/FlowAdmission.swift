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

    public init(
        hasSession: Bool,
        policy: CapturePolicy,
        ownSigningIdentifier: String = UpLinkIdentifiers.macProxyExtension
    ) {
        self.hasSession = hasSession
        self.policy = policy
        self.ownSigningIdentifier = ownSigningIdentifier
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
        return policy.shouldCapture(app: sourceSigningIdentifier)
    }
}

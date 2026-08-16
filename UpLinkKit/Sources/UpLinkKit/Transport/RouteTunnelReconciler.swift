import Foundation

/// What the route tunnel should be doing, given what is true right now.
///
/// ## The measurement this exists because of
///
/// NetworkExtension **will not start a packet tunnel on a Mac that has no
/// network**, and says so in as many words. Every one of thirty consecutive
/// start attempts on 2026-08-15 died identically:
///
/// ```
/// Entering state NESMVPNSessionStatePreparingNetwork
/// E  No network available
/// Entering state NESMVPNSessionStateStopping
/// status changed to disconnected, last stop reason No network available
/// ```
///
/// `startVPNTunnel()` did not throw. It was accepted, moved to `connecting`,
/// and was torn down by the system a few milliseconds later. From the app's
/// side that is indistinguishable from a swallowed start, which is why it was
/// retried once a second for thirty-one seconds.
///
/// **But an already-connected tunnel survives the network going away.** Same
/// log, same session: it reached `connected` at 17:50:40.815 and stayed there
/// for the next twenty minutes with the Wi-Fi radio off, with no status change
/// at all. Starting requires an underlying network; running does not.
///
/// ## Why that asymmetry is the whole design
///
/// The previous reconciler stopped the tunnel whenever the bridge session had
/// been gone for ten ticks and another network was available — reasoning that
/// with a network present, dropping it was reversible. That reasoning is sound
/// and the conclusion is still wrong, because *reversibility is a property of
/// the moment you restart, not the moment you stop*, and those are different
/// moments with the user's hands in between. The supported way to use this
/// product is:
///
///   1. bridge over the cable          (tunnel up, Wi-Fi off)
///   2. stop bridging, Wi-Fi back on   (tunnel dropped — "safe", network present)
///   3. Wi-Fi off, cable in, bridge on (tunnel must start — no network. Stuck.)
///
/// Step 2's safety check is evaluated against a network the user is about to
/// turn off precisely so the bridge can do its job. The check can never be
/// right, because the workflow guarantees the network is gone by the time it
/// matters.
///
/// So the tunnel is never stopped for a dead session. It is started **eagerly**,
/// while a network still exists to start it with, and then stays up for the life
/// of the app, switching between two modes instead of between up and down.
///
/// The thing that made stopping seem necessary — a tunnel with a default route
/// and no bridge behind it is a total outage — is handled by ``RouteTunnelMode``
/// instead, which is a settings change on a running tunnel and needs no network
/// to apply.
public enum RouteTunnelMode: Sendable, Equatable {
    /// The interface exists and captures nothing: no routes, no resolver.
    ///
    /// This is what makes never stopping the tunnel safe. Without a bridge
    /// behind it, a capturing tunnel drops every packet the proxy declines,
    /// which is the "quitting both apps was the only way to get Wi-Fi back"
    /// failure. In standby the Mac's own network is untouched.
    case standby
    /// Default routes for both families, plus DNS. What the bridge needs.
    case capture
}

/// What NetworkExtension reports, as a value this package can reason about.
///
/// Mirrors `NEVPNStatus` rather than importing it, so every transition below is
/// provable with no NetworkExtension, no entitlement, and no Mac.
public enum RouteTunnelStatus: Sendable, Equatable {
    /// No configuration has been written yet.
    case unconfigured
    case invalid
    case disconnected
    case connecting
    case connected
    case disconnecting
    case reasserting
}

public enum RouteTunnelAction: Sendable, Equatable {
    /// Write a configuration and start it.
    case configure
    /// Configured and down. Start it — **whether or not a session is live**.
    case start
    /// The saved configuration cannot be started as it stands. Replace it.
    case rebuild
    /// Running. Make sure it is in this mode.
    case setMode(RouteTunnelMode)
    /// A transition is in flight; touching it now is how starts get swallowed.
    case wait
}

public enum RouteTunnelReconciler {

    /// - Parameters:
    ///   - status: what NetworkExtension says right now.
    ///   - sessionLive: is there a bridge session to carry traffic?
    ///   - needsRebuild: did a previous start fail with an unusable-configuration
    ///     error? Retrying such a configuration cannot ever succeed.
    public static func next(
        status: RouteTunnelStatus,
        sessionLive: Bool,
        needsRebuild: Bool = false
    ) -> RouteTunnelAction {
        // A configuration known to be unusable is replaced, not retried. This
        // was reached by nothing more exotic than adopting a tunnel left by a
        // previous launch: a stale configuration reports `.disconnected`, not
        // `.invalid`, so it looks startable and fails forever.
        if needsRebuild, status == .disconnected || status == .invalid || status == .unconfigured {
            return .rebuild
        }

        switch status {
        case .unconfigured, .invalid:
            return .configure

        case .disconnected:
            // THE FIX, IN ONE LINE: no `sessionLive` test here.
            //
            // Waiting for a session before starting means starting at exactly
            // the moment the user has taken the network away — which is the one
            // moment NetworkExtension refuses. Starting eagerly means the tunnel
            // is already up, in standby, harming nothing, by the time it is
            // needed.
            return .start

        case .connecting, .disconnecting:
            // Starting again while a transition is in flight is a no-op that
            // looks like success. That is how a start was silently swallowed
            // and never retried.
            return .wait

        case .connected, .reasserting:
            return .setMode(sessionLive ? .capture : .standby)
        }
    }
}

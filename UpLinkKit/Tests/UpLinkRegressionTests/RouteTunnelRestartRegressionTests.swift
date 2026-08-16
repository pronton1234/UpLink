import Testing
import Foundation
@testable import UpLinkKit

// THE RECONNECT THAT COULD NOT HAPPEN.
//
// Reported 2026-08-15: "I tested with wifi off initially and it worked, but
// when I disconnected from my phone and tried reconnecting, it failed."
//
// The bridge session itself was never the problem — it came up in three
// seconds. What failed was the route tunnel that gives the Mac a default route
// and a resolver, without which a working bridge carries nothing because no
// socket can be created to hand it. NetworkExtension refused to start it, once
// a second, for thirty-one seconds, and said exactly why:
//
//     Entering state NESMVPNSessionStatePreparingNetwork
//     E  No network available
//     status changed to disconnected, last stop reason No network available
//
// It eventually started only because the phone's Personal Hotspot happened to
// give the USB interface an address at 17:50:40, which changed the ranked
// interfaces and gave NE a network to prepare against. With the hotspot off it
// would have retried forever.
//
// The old reconciler dropped the tunnel after ten quiet ticks *if another
// network was available*, on the reasoning that dropping it was then
// reversible. The reasoning is sound and the conclusion is wrong:
// reversibility is a property of the moment you RESTART, and the user turns
// the network off in between — on purpose, because that is what the product is
// for. So the safety check was evaluated against a network guaranteed to be
// gone when it mattered.
//
// These tests are the sequence, as transitions.

@Suite("Regression: the route tunnel must never need a network to come back")
struct RouteTunnelRestartRegressionTests {

    // MARK: The reported sequence, step by step

    // Each step is what the reconciler must decide, given what NE reports and
    // whether a bridge session exists. Step 4 is the one that used to be
    // unreachable.
    @Test("The full disconnect/reconnect cycle never requires a start with no network")
    func theReportedSequence() {
        // 1. Bridging over the cable, Wi-Fi off. Tunnel up and capturing.
        #expect(RouteTunnelReconciler.next(
            status: .connected, sessionLive: true
        ) == .setMode(.capture))

        // 2. The user stops bridging and turns Wi-Fi back on. The session is
        //    gone. The tunnel must NOT be stopped — but it must stop capturing,
        //    or the Mac has a default route into a tunnel with nothing behind
        //    it, which is a total outage.
        #expect(
            RouteTunnelReconciler.next(status: .connected, sessionLive: false)
                == .setMode(.standby),
            "a tunnel kept up with no session must stop capturing, or it strands the Mac"
        )

        // 3. Still no session, however long it lasts. Still not stopped.
        for _ in 0 ..< 100 {
            let action = RouteTunnelReconciler.next(status: .connected, sessionLive: false)
            #expect(action == .setMode(.standby), "the tunnel was eventually torn down")
        }

        // 4. Wi-Fi off, cable in, bridge on. THE STEP THAT FAILED. Because the
        //    tunnel was never stopped it is already connected, and all that is
        //    needed is a settings change — which needs no underlying network.
        #expect(
            RouteTunnelReconciler.next(status: .connected, sessionLive: true)
                == .setMode(.capture),
            "reconnecting required a fresh start, which NetworkExtension refuses with no network"
        )
    }

    // MARK: The property that makes the above true

    // Nothing this reconciler can return stops the tunnel. If any input
    // produced a stop, the sequence above could reach step 4 with the tunnel
    // down, and NE would refuse it exactly as it did on the day.
    @Test("No combination of inputs ever tears the tunnel down")
    func neverStops() {
        let statuses: [RouteTunnelStatus] = [
            .unconfigured, .invalid, .disconnected,
            .connecting, .connected, .disconnecting, .reasserting,
        ]
        for status in statuses {
            for live in [true, false] {
                for rebuild in [true, false] {
                    let action = RouteTunnelReconciler.next(
                        status: status, sessionLive: live, needsRebuild: rebuild
                    )
                    // `.rebuild` replaces a configuration that cannot start; it
                    // is not a teardown of a working tunnel, and it is only
                    // ever reachable from a down state.
                    if action == .rebuild {
                        #expect(
                            status == .disconnected || status == .invalid || status == .unconfigured,
                            "a running tunnel was rebuilt out from under a live session"
                        )
                    }
                }
            }
        }
    }

    // MARK: Eager start — the other half

    // Starting only when a session is live means starting at the one moment the
    // user has taken the network away. The tunnel must come up while there is
    // still a network to come up with, and sit in standby until it is wanted.
    @Test("A down tunnel is started even with no session, so it is up before the network goes")
    func startsEagerly() {
        #expect(
            RouteTunnelReconciler.next(status: .disconnected, sessionLive: false) == .start,
            "the tunnel waited for a session, so it could only ever start after the network was gone"
        )
        // And having started, it must not capture anything until there is a
        // bridge — otherwise eager starting would break the user's Wi-Fi.
        #expect(RouteTunnelReconciler.next(
            status: .connected, sessionLive: false
        ) == .setMode(.standby))
    }

    // MARK: The failures already paid for, which must not regress

    // 13:56:36 ENDED, 13:56:37 started again — 0.9s. `startVPNTunnel()` while
    // the previous session is still tearing down is a no-op that reports
    // success, so the start was swallowed and nothing tried again.
    @Test("A transition in flight is waited out, not started into")
    func doesNotStartIntoATransition() {
        #expect(RouteTunnelReconciler.next(status: .disconnecting, sessionLive: true) == .wait)
        #expect(RouteTunnelReconciler.next(status: .connecting, sessionLive: true) == .wait)
    }

    // A stale adopted configuration reports `.disconnected`, not `.invalid`, so
    // it looks perfectly startable and throws every single time. Retrying it
    // once a second forever was the observed behaviour.
    @Test("An unusable configuration is rebuilt rather than retried")
    func rebuildsUnusableConfiguration() {
        #expect(RouteTunnelReconciler.next(
            status: .disconnected, sessionLive: true, needsRebuild: true
        ) == .rebuild)
        // But a rebuild flag must not interrupt a tunnel that is actually up.
        #expect(RouteTunnelReconciler.next(
            status: .connected, sessionLive: true, needsRebuild: true
        ) == .setMode(.capture))
    }

    // MARK: Convergence

    // The reconciler runs at 1Hz against whatever NE reports. Whatever state it
    // starts in, an unchanging reality must land it somewhere stable — a
    // reconciler that oscillates would toggle the user's default route once a
    // second.
    @Test("Every starting state converges to a stable answer")
    func converges() {
        for live in [true, false] {
            var status = RouteTunnelStatus.unconfigured
            var action = RouteTunnelAction.wait
            // configure → (connecting) → connected, with a tick to spare.
            for _ in 0 ..< 6 {
                action = RouteTunnelReconciler.next(status: status, sessionLive: live)
                switch action {
                case .configure, .start, .rebuild: status = .connecting
                case .wait: status = .connected
                case .setMode: break
                }
            }
            #expect(
                action == .setMode(live ? .capture : .standby),
                "never settled with sessionLive=\(live)"
            )
            // And it stays there.
            #expect(RouteTunnelReconciler.next(status: status, sessionLive: live) == action)
        }
    }
}

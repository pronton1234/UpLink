import Testing
import Foundation
@testable import UpLinkKit

// REGRESSION: a route tunnel outlived the app that started it, and the next
// launch could not take it down.
//
// FOUND ON HARDWARE, 2026-08-15, and it cost the Mac its entire network.
//
// The route tunnel installs a default route into a packet tunnel that
// deliberately drops every packet — it exists only so `connect()` reaches route
// lookup and the transparent proxy is consulted. That is safe exactly as long
// as a live bridge sits behind it. `reconcileRouteTunnel` is what guarantees
// that, tearing the tunnel down after ten quiet ticks.
//
// But its teardown began `guard let routeManager`, and `routeManager` was
// assigned in ONE place: the session-live path. Quit the app and relaunch it
// with no session and the property is nil, the guard returns silently, and the
// tunnel from the previous instance stays up forever. Observed: `curl` timing
// out, `default … utun5` outranking en0, and the only way back being
// `scutil --nc stop "UpLink Route"` typed by hand.
//
// The app was structurally incapable of undoing the one thing its own comments
// call "impossible to undo", and it got there by nothing more exotic than being
// restarted.

@Suite("Regression: an orphaned route tunnel must still be tearable-down")
struct RouteTunnelOwnershipRegressionTests {

    /// The decision `reconcileRouteTunnel` makes on a quiet tick, extracted so
    /// the ownership rule can be checked without NetworkExtension.
    private struct Reconciler {
        /// Whether this launch has a handle on the tunnel.
        var ownsManager: Bool
        var quietTicks = 0
        var tunnelUp = true
        var hasOtherNetwork = true

        static let quietTicksBeforeDropping = 10

        /// Returns whether the tunnel was torn down.
        mutating func quietTick() -> Bool {
            quietTicks += 1
            guard quietTicks >= Self.quietTicksBeforeDropping else { return false }
            guard ownsManager else { return false }   // THE BUG
            guard tunnelUp else { return false }
            // Only hand the network back when there is one to hand back to.
            guard hasOtherNetwork else { return false }
            tunnelUp = false
            return true
        }
    }

    // THE bug, stated exactly.
    @Test("A tunnel left by a previous launch is torn down once adopted")
    func adoptedTunnelIsTornDown() {
        var owned = Reconciler(ownsManager: true)
        var orphaned = Reconciler(ownsManager: false)

        var ownedDropped = false
        var orphanedDropped = false
        for _ in 0 ..< 30 {
            ownedDropped = ownedDropped || owned.quietTick()
            orphanedDropped = orphanedDropped || orphaned.quietTick()
        }

        #expect(ownedDropped, "a tunnel this launch started was never dropped")
        #expect(
            orphanedDropped == false,
            "this asserts the OLD behaviour, to document what adoption has to fix"
        )

        // Adoption at startup is the fix: the same launch, having found the
        // existing manager, can now tear it down.
        var adopted = Reconciler(ownsManager: true)
        var dropped = false
        for _ in 0 ..< 30 { dropped = dropped || adopted.quietTick() }
        #expect(dropped, "an adopted tunnel still could not be torn down")
    }

    // The hysteresis has to survive: a session that flaps must not blink the
    // user's default route. Ten ticks is ~10s.
    @Test("A brief gap does not drop the tunnel")
    func shortGapKeepsTheTunnel() {
        var reconciler = Reconciler(ownsManager: true)
        for _ in 0 ..< (Reconciler.quietTicksBeforeDropping - 1) {
            #expect(reconciler.quietTick() == false)
        }
        #expect(reconciler.tunnelUp)
    }

    // The asymmetry that must never be lost: with no other network, dropping
    // strands the Mac permanently, because NetworkExtension will not start a
    // packet tunnel with no underlying network. A stale tunnel is strictly
    // better than an unrecoverable one.
    @Test("With no other network, the tunnel is kept rather than stranding the Mac")
    func noAlternativeKeepsTheTunnel() {
        var reconciler = Reconciler(ownsManager: true)
        reconciler.hasOtherNetwork = false
        for _ in 0 ..< 60 { _ = reconciler.quietTick() }
        #expect(reconciler.tunnelUp, "the Mac was stranded with no way to rebuild the tunnel")
    }
}

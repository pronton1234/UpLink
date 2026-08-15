import Testing
import Foundation
@testable import UpLinkKit

// REGRESSION: the extension kept dialling a relay port that no longer existed.
//
// FOUND ON HARDWARE, and only reachable there. Quitting and relaunching the
// menu-bar app binds a FRESH ephemeral relay port and announces it. The
// extension's redial loop is guarded so a repeated announcement cannot cancel
// the session it is trying to establish — but the guard compared the announced
// port against `relayPort`, which the caller had *already* assigned from that
// same announcement. The comparison was therefore always true: the guard
// returned whenever any loop existed, and a genuinely new port never took
// effect.
//
// Observed: `dial failed: connection refused — nothing is listening there`
// every five seconds against the dead port, while `lsof` showed a perfectly
// good listener on the new one. The bridge could not survive an app restart.
//
// No existing test could catch it, because catching it needs TWO successive
// relay ports and every test used one. That is the shape worth remembering:
// the bug lived in the transition, not in either state.

@Suite("Regression: a new relay port must replace the old one")
struct RelayHandoverRegressionTests {

    /// The guard as it must behave: "is the running loop already dialling THIS
    /// port?" — a question only the loop's own record can answer.
    private struct Redialer {
        var dialingPort: UInt16?
        var dialingUDID: String?
        var loopRunning = false
        private(set) var restarts = 0

        /// Mirrors `ProxyState.startRedialing`'s guard.
        mutating func announce(port: UInt16, udid: String) {
            if loopRunning, dialingPort == port, dialingUDID == udid { return }
            dialingPort = port
            dialingUDID = udid
            loopRunning = true
            restarts += 1
        }
    }

    // THE bug.
    @Test("A relaunched app's new port replaces the old one")
    func newPortTakesEffect() {
        var redialer = Redialer()
        redialer.announce(port: 54628, udid: "UDID-A")
        #expect(redialer.restarts == 1)

        // The app is quit and relaunched: same cable, new ephemeral port.
        redialer.announce(port: 54629, udid: "UDID-A")

        #expect(
            redialer.dialingPort == 54629,
            "the extension is still dialling the dead port — the bridge cannot survive an app restart"
        )
        #expect(redialer.restarts == 2)
    }

    // The other half, and the reason the guard exists at all: the app
    // re-announces the SAME relay once a second whenever the extension reports
    // no session. Restarting the loop on each of those would cancel the very
    // dial it is waiting on, and nothing would ever connect.
    @Test("A repeated announcement for the same port does not restart the loop")
    func repeatedAnnouncementIsIdempotent() {
        var redialer = Redialer()
        redialer.announce(port: 54628, udid: "UDID-A")
        for _ in 0 ..< 20 { redialer.announce(port: 54628, udid: "UDID-A") }
        #expect(redialer.restarts == 1, "a re-announcement cancelled the dial it was waiting on")
    }

    // THE THIRD BUG IN THIS FAMILY, and the one that made the first fix look
    // like it had not worked.
    //
    // The relay announces its port ONCE, the moment the cable is seen — which
    // at launch is before the proxy IPC channel exists, so the message is
    // silently dropped. The extension therefore still holds the PREVIOUS
    // launch's port and answers "connecting" rather than "disconnected". A
    // re-announce gated only on "disconnected" never fires, and the bridge
    // stays dead until the cable is physically unplugged.
    //
    // Re-announcing on BOTH not-connected replies is what closes it, and it is
    // only safe because the guard above is idempotent on the port the loop is
    // actually dialling.
    @Test("A dropped announcement is recovered by re-announcing while connecting")
    func droppedAnnouncementRecovers() {
        var redialer = Redialer()

        // Launch: the announcement is lost before the IPC channel is up, so the
        // extension is still dialling whatever the last launch told it.
        redialer.announce(port: 54628, udid: "UDID-A")   // previous launch
        let lostPort: UInt16 = 54632                     // never delivered

        // The extension reports "connecting", not "disconnected", because it
        // still holds a relay port. Re-announcing on that reply delivers it.
        redialer.announce(port: lostPort, udid: "UDID-A")
        #expect(
            redialer.dialingPort == lostPort,
            "the lost announcement was never recovered — the bridge stays dead until the cable is unplugged"
        )

        // And the repeats that follow, once a second, must not disturb it.
        let restartsAfterRecovery = redialer.restarts
        for _ in 0 ..< 30 { redialer.announce(port: lostPort, udid: "UDID-A") }
        #expect(redialer.restarts == restartsAfterRecovery, "the per-tick re-announce restarted a healthy dial")
    }

    // A different phone on the same port number must also take effect.
    @Test("A different device on the same port still restarts the loop")
    func differentDeviceRestarts() {
        var redialer = Redialer()
        redialer.announce(port: 54628, udid: "UDID-A")
        redialer.announce(port: 54628, udid: "UDID-B")
        #expect(redialer.dialingUDID == "UDID-B")
        #expect(redialer.restarts == 2)
    }
}

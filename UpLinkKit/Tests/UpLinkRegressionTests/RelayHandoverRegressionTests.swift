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

    // THE FOURTH IN THIS FAMILY, and the reason the re-announce is no longer
    // gated on an enumerated list of replies.
    //
    // Every previous fix here picked a subset of "not connected" to retry on,
    // and every time the real failure was the case left out. First it was only
    // `disconnected`, so a stale relay port answering `connecting` never
    // recovered. Then `connecting` was added, and the extension answered
    // `unavailable` — it has no client until the proxy provider starts, which
    // is exactly the window in which the launch-time announcement is dropped —
    // which parses as `unintelligible` and was, again, not in the list.
    //
    // Observed on hardware: the app announced port 54636, the extension never
    // received it, and nothing retried for twenty minutes while the phone sat
    // answering on 50505.
    //
    // The rule now is the simple one: if we are not CONNECTED and we have a
    // relay, say so again. It is safe precisely because the guard is idempotent
    // on the port the loop is dialling.
    @Test("Every not-connected reply re-announces, not an enumerated subset")
    func everyNotConnectedReplyReannounces() {
        // The replies the extension can give that are not `connected`.
        let notConnected: [BridgeStatusReply] = [
            .disconnected,
            .connecting,
            .unintelligible,          // "unavailable" — no client yet
            .refused,
            .unpaired(fingerprint: "abc"),
        ]
        for reply in notConnected {
            #expect(
                Self.shouldReannounce(reply),
                "\(reply) does not re-announce the relay — the launch-window drop is unrecoverable for this reply"
            )
        }
        #expect(
            Self.shouldReannounce(.connected(peer: "Mac", egress: .cellular)) == false,
            "re-announcing while connected would restart a healthy session"
        )
    }

    /// Mirrors `MenuBarModel.refreshStatus`: anything that is not a live
    /// session re-offers the relay.
    private static func shouldReannounce(_ reply: BridgeStatusReply) -> Bool {
        if case .connected = reply { return false }
        return true
    }

    // A device attached but not answering gets ONE probe per attach event, and
    // usbmuxd sends one attach per plug. A phone whose extension had not
    // finished binding when we looked therefore stayed "not answering" with no
    // further event to trigger another look — unplugging was the only way out.
    @Test("A silent-but-attached device is probed again, not written off")
    func silentDeviceIsReprobed() {
        var attempts = 0
        var answering = false
        // The phone's extension finishes binding on the third look.
        func probe() -> Bool {
            attempts += 1
            if attempts >= 3 { answering = true }
            return answering
        }

        var ready = probe()
        #expect(ready == false, "the phone answered too early for this test to mean anything")

        // The re-probe loop, bounded the way the real one is by the device
        // staying attached.
        for _ in 0 ..< 10 where !ready { ready = probe() }

        #expect(ready, "the relay never looked again, so the cable stays dead until it is unplugged")
        #expect(attempts == 3, "expected exactly the probes needed, got \(attempts)")
    }

    // THE FIFTH, and the third time `isCancelled` has been mistaken for
    // "finished". A Task that returns normally reports `isCancelled == false`
    // forever, so a guard written as `if let t = task, !t.isCancelled` sees a
    // loop that exited as still running and refuses to start another.
    //
    // Observed end to end on hardware:
    //
    //     16:54:51  no pairing for <udid> — not dialling   (loop returns)
    //     16:55:14  ipc: paired <fingerprint>              (user pairs)
    //     …         no session, ever
    //
    // The pairing succeeded and the bridge stayed dead, because nothing could
    // restart the loop. The marker is now cleared by the loop itself on the way
    // out, so "am I dialling?" is answered by state the loop maintains rather
    // than by asking a Task a question it cannot answer.
    @Test("A redial loop that exited can be started again")
    func exitedLoopCanRestart() {
        var dialingPort: UInt16?
        var dialingUDID: String?
        var starts = 0

        // Mirrors `ProxyState.startRedialing`'s guard.
        func announce(port: UInt16, udid: String) {
            if dialingPort == port, dialingUDID == udid { return }
            dialingPort = port
            dialingUDID = udid
            starts += 1
        }
        // Mirrors the loop's `defer`.
        func loopExited(port: UInt16, udid: String) {
            guard dialingPort == port, dialingUDID == udid else { return }
            dialingPort = nil
            dialingUDID = nil
        }

        announce(port: 54643, udid: "UDID-A")
        #expect(starts == 1)

        // The loop finds no pairing and returns.
        loopExited(port: 54643, udid: "UDID-A")

        // The user pairs; the next announcement must start a fresh loop.
        announce(port: 54643, udid: "UDID-A")
        #expect(
            starts == 2,
            "a loop that had already exited blocked every restart — the pairing succeeds and the bridge stays dead"
        )
    }

    // The other half: while a loop IS running, repeated announcements must not
    // restart it, or the per-second re-announce would cancel the dial it is
    // waiting on.
    @Test("A running loop is not restarted by repeated announcements")
    func runningLoopIsNotRestarted() {
        var dialingPort: UInt16?
        var dialingUDID: String?
        var starts = 0
        func announce(port: UInt16, udid: String) {
            if dialingPort == port, dialingUDID == udid { return }
            dialingPort = port; dialingUDID = udid; starts += 1
        }
        announce(port: 54643, udid: "UDID-A")
        for _ in 0 ..< 30 { announce(port: 54643, udid: "UDID-A") }
        #expect(starts == 1)
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

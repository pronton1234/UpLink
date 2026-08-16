import Testing
import Foundation
@testable import UpLinkKit

// Every failure the relay has actually had, as a transition.
//
// These are not hypotheticals. Each one below cost a real debugging session on
// real hardware, and each was fixed by adding one more edge to react to — after
// which the next gap was, every time, the case that list left out:
//
//   * an attach event arriving before the proxy extension had a client
//   * a probe run a second before the phone's listener finished binding
//   * a device re-enumerating, so a retry loop held an id that no longer existed
//   * a retry loop that cancelled itself by calling the function that armed it
//   * usbmuxd briefly failing to answer, read as "the cable is out"
//
// The relay is level-triggered now, so none of these is a special case: each
// tick asks what is true and closes the gap. That is only worth anything if the
// transitions are pinned, which is what this suite is.
//
// **A simulator cannot cover this.** usbmuxd enumerates USB devices, and a
// simulator is a process on the Mac — no cable, no deviceID, nothing for
// `Connect` to reach. This suite is the substitute, and it is a better one:
// it reaches states a device reaches only by accident.

@Suite("Regression: the relay must re-derive truth, not remember it")
struct RelayReconcilerRegressionTests {

    private func phone(_ udid: String, id: UInt32 = 1) -> USBDevice {
        USBDevice(deviceID: id, udid: udid, connectionType: .usb)
    }

    // MARK: The ordinary path

    @Test("Nothing attached means stand down")
    func nothingAttached() {
        #expect(RelayReconciler.next(
            attached: [], holding: .nothing, answeringPort: nil
        ) == .standDown)
    }

    @Test("Attached and answering with no relay opens one")
    func opensRelay() {
        let device = phone("UDID-A")
        #expect(RelayReconciler.next(
            attached: [device], holding: .nothing, answeringPort: 50505
        ) == .openRelay(device: device, answeringPort: 50505))
    }

    @Test("Already relaying for this device holds")
    func holdsWhenCorrect() {
        #expect(RelayReconciler.next(
            attached: [phone("UDID-A")],
            holding: RelayHolding(udid: "UDID-A", listenerPort: 54321),
            answeringPort: 50505
        ) == .hold)
    }

    // MARK: The failures that actually happened

    // A phone whose Network Extension has not finished binding answers on
    // neither port. This is NOT a terminal state — it was treated as one, and
    // the cable stayed dead until it was physically unplugged.
    @Test("Attached but silent keeps waiting, and recovers when it answers")
    func silentPhoneRecovers() {
        let device = phone("UDID-A")

        #expect(RelayReconciler.next(
            attached: [device], holding: .nothing, answeringPort: nil
        ) == .waitForPhone(udid: "UDID-A"))

        // Next tick, the phone is up.
        #expect(RelayReconciler.next(
            attached: [device], holding: .nothing, answeringPort: 50505
        ) == .openRelay(device: device, answeringPort: 50505))
    }

    // THE one that took twenty minutes to spot on hardware. usbmuxd assigns a
    // new deviceID on every replug, and the relay held the old one.
    @Test("A re-enumerated device opens a fresh relay rather than holding a stale one")
    func reEnumeratedDeviceReopens() {
        let replugged = phone("UDID-B", id: 6)
        let action = RelayReconciler.next(
            attached: [replugged],
            holding: RelayHolding(udid: "UDID-A", listenerPort: 54321),
            answeringPort: 50505
        )
        #expect(
            action == .openRelay(device: replugged, answeringPort: 50505),
            "the relay kept a listener for a device that is no longer attached"
        )
    }

    // A listener that died leaves us holding a udid with no port. Holding would
    // mean the extension dials a port nothing is bound to — the exact
    // "connection refused, forever" symptom.
    @Test("A dead listener is reopened, not held")
    func deadListenerReopens() {
        let device = phone("UDID-A")
        #expect(RelayReconciler.next(
            attached: [device],
            holding: RelayHolding(udid: "UDID-A", listenerPort: nil),
            answeringPort: 50505
        ) == .openRelay(device: device, answeringPort: 50505))
    }

    // THE ASYMMETRY THAT MATTERS. "I could not ask usbmuxd" is not "the cable
    // is out". Treating them the same tears down a working bridge because the
    // daemon was busy for one tick.
    @Test("A failed enumeration holds, and never stands down")
    func failedEnumerationHolds() {
        let holding = RelayHolding(udid: "UDID-A", listenerPort: 54321)
        #expect(
            RelayReconciler.next(attached: nil, holding: holding, answeringPort: 50505) == .hold,
            "a transient usbmuxd failure tore down a working relay"
        )
        // Even with nothing held, it must not conclude anything.
        #expect(
            RelayReconciler.next(attached: nil, holding: .nothing, answeringPort: nil) == .hold
        )
    }

    // MARK: Convergence — the property the whole design rests on

    // Whatever state the relay is in, and whatever it has wrongly remembered,
    // a few ticks against unchanging reality must land on the right answer.
    // That is what "level-triggered" buys, and it is worth asserting directly
    // rather than trusting the individual cases above to be exhaustive.
    @Test("Any stale belief converges once reality stops changing")
    func convergesFromAnyState() {
        let device = phone("UDID-REAL", id: 9)
        let staleBeliefs: [RelayHolding] = [
            .nothing,
            RelayHolding(udid: "UDID-OLD", listenerPort: 111),
            RelayHolding(udid: "UDID-REAL", listenerPort: nil),
            RelayHolding(udid: nil, listenerPort: 222),
        ]

        for belief in staleBeliefs {
            var holding = belief
            var settled: RelayAction = .hold
            // Three ticks is generous; one is enough for all of these.
            for _ in 0 ..< 3 {
                settled = RelayReconciler.next(
                    attached: [device], holding: holding, answeringPort: 50505
                )
                if case let .openRelay(found, port) = settled {
                    holding = RelayHolding(udid: found.udid, listenerPort: 54321)
                    _ = port
                }
            }
            #expect(
                settled == .hold,
                "starting from \(belief) the relay never settled — it would flap forever"
            )
            #expect(holding.udid == "UDID-REAL")
        }
    }

    // The mirror: once the cable is out, no amount of stale belief keeps it up.
    @Test("Unplugging converges to stand-down from any belief")
    func convergesToStandDown() {
        for belief in [RelayHolding.nothing, RelayHolding(udid: "UDID-A", listenerPort: 54321)] {
            #expect(RelayReconciler.next(
                attached: [], holding: belief, answeringPort: nil
            ) == .standDown)
        }
    }
}

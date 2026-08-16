import Testing
import Foundation
@testable import UpLinkKit

// THE SWITCH THAT TOOK TWO PRESSES AND TWO WORDS.
//
// Reported 2026-08-15: "I can stop bridging and then I have to 'turn off'. Like
// it is not clear."
//
// The phone's one control had three branches. "Stop Bridging" while a Mac was
// connected and "Turn Off" while merely listening both called `disconnect()` —
// the same action under two names. And the listening branch was keyed on the
// tunnel's NEVPNStatus rather than on the app's own state, while `disconnect()`
// sets the state immediately, so tapping "Stop Bridging" changed the label to
// "Turn Off" for the second or two the tunnel took to stop, and only then to
// "Turn On". One action, three words, and it read as two presses.
//
// None of this was testable where it lived: the decision was inline in a
// SwiftUI `@ViewBuilder` in the iOS app target, which has no test target. The
// only way to see it was to physically arrange each state on a device — which
// is exactly how it survived to the user.

@Suite("Regression: the phone has one switch, and it has one name per action")
struct PhoneControlRegressionTests {

    private func control(_ c: PhoneBridgeCondition) -> PhoneControl {
        PhoneControlResolver.control(for: c)
    }

    // MARK: The bug itself

    // A Mac connecting or disconnecting is STATUS. It belongs on the dial. It
    // must not change the word on the switch, because the switch does the same
    // thing either way.
    @Test("A Mac arriving or leaving does not rename the switch")
    func macPresenceDoesNotRenameTheSwitch() {
        #expect(
            control(.listening) == control(.bridging),
            "the switch was renamed because a Mac connected, so one action had two names"
        )
        #expect(control(.bridging).label == "Turn Off")
    }

    // The sequence the user actually performed: it was on with a Mac bridging,
    // they pressed once to switch it off, and the switch must then offer to
    // turn it back ON — not offer a second, differently-worded way to turn it
    // off.
    @Test("Switching off takes one press, not two")
    func switchingOffTakesOnePress() {
        let before = control(.bridging)
        #expect(before.switchesOn == false, "the switch was not offering to turn anything off")

        // One press. The bridge is now off; whether the tunnel has finished
        // tearing down is machinery and must not reach the label.
        let after = control(.off)
        #expect(
            after.switchesOn,
            "after one press the switch STILL offered to turn it off — the second press the user reported"
        )
        #expect(after.label == "Turn On")
    }

    // The intermediate state that produced the third word. While the tunnel is
    // stopping the app is `.off` by intent, and the label must already reflect
    // that rather than tracking the tunnel's own status.
    @Test("The label follows intent, never the tunnel's own status")
    func labelFollowsIntent() {
        // There is deliberately no condition here meaning "off but the tunnel
        // has not finished stopping". If one existed the bug could come back,
        // so the type is the guarantee: `off` is `off`.
        #expect(control(.off) == .turnOn)
    }

    // MARK: Every action has exactly one name

    // The general property, so a new condition cannot reintroduce a synonym.
    // Two conditions offering the same action must show the same word — with
    // one deliberate exception, recovery, which is a genuinely different thing
    // to do and is asserted separately below.
    @Test("No action has two names")
    func noActionHasTwoNames() {
        let all: [PhoneBridgeCondition] = [.needsPermission, .off, .listening, .bridging, .failed]

        var labelsForSwitchingOff = Set<String>()
        for condition in all where !control(condition).switchesOn {
            labelsForSwitchingOff.insert(control(condition).label)
        }
        #expect(
            labelsForSwitchingOff.count <= 1,
            "switching off is offered under more than one name: \(labelsForSwitchingOff.sorted())"
        )

        // Switching on has exactly two names, and the second is only ever for
        // recovery. Anything else sharing it would be the same defect again.
        var onNames = [PhoneBridgeCondition: String]()
        for condition in all where control(condition).switchesOn {
            onNames[condition] = control(condition).label
        }
        for (condition, label) in onNames where label != "Turn On" {
            #expect(
                condition == .failed,
                "\(condition) shows \"\(label)\" instead of \"Turn On\" without being a failure"
            )
        }
    }

    // MARK: The states that are not the switch's business

    @Test("Permission and off both simply offer to turn it on")
    func permissionOffersTheSameThing() {
        #expect(control(.needsPermission) == .turnOn)
        #expect(control(.needsPermission) == control(.off))
    }

    // A failure gets its own word because the useful action is "start it again",
    // and making the user deduce that "Turn Off" then "Turn On" is the fix is
    // the same class of unclarity this whole suite exists for.
    @Test("A failure offers recovery, and recovery switches on")
    func failureOffersRecovery() {
        #expect(control(.failed) == .tryAgain)
        #expect(control(.failed).switchesOn, "Try Again did not actually start anything")
        #expect(control(.failed).label == "Try Again")
    }

    // Only the off switch is destructive styling. A recovery button styled
    // destructive reads as "this will break something".
    @Test("Only switching off is styled destructive")
    func onlyOffIsDestructive() {
        #expect(control(.bridging).isDestructive)
        #expect(!control(.off).isDestructive)
        #expect(!control(.failed).isDestructive)
    }
}

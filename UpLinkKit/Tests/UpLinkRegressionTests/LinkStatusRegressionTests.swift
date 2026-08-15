import Testing
import Foundation
@testable import UpLinkKit

// REGRESSION: the menu bar said "Waiting for iPhone" at a user whose iPhone was
// plugged in and sitting right there.
//
// "Not bridging" has four causes and they need four different actions from the
// user. Collapsing them into one string meant the one piece of UI that exists
// to tell you what to do next told everybody the same thing.
//
// These arms lived in the Mac app, which has no test target, so none of them
// could be checked without physically arranging each state — no cable, cable
// with the phone's app closed, cable with no pairing, and so on. That is the
// real reason the wrong string survived: not that it was hard, but that seeing
// it cost a device and four setups.

@Suite("Regression: the cable's state must name the thing to fix")
struct LinkStatusRegressionTests {

    // THE bug, stated exactly.
    @Test("A plugged-in iPhone never reads as waiting for a cable")
    func attachedIsNeverWaitingForCable() {
        let attached: [LinkPresence] = [
            .attachedNotAnswering,
            .answering(udid: "UDID-A"),
        ]
        for presence in attached {
            for paired in [true, false] {
                for off in [true, false] {
                    let status = LinkStatus.resolve(
                        presence: presence, isPaired: paired, userDisconnected: off
                    )
                    #expect(
                        status != .waitingForCable,
                        "\(presence) paired=\(paired) off=\(off) told the user to plug in a cable that is already plugged in"
                    )
                }
            }
        }
    }

    @Test("Each cause maps to its own remedy")
    func eachCauseIsDistinct() {
        #expect(LinkStatus.resolve(
            presence: .noDevice, isPaired: true, userDisconnected: false
        ) == .waitingForCable)

        #expect(LinkStatus.resolve(
            presence: .attachedNotAnswering, isPaired: true, userDisconnected: false
        ) == .deviceNotResponding)

        #expect(LinkStatus.resolve(
            presence: .answering(udid: "UDID-A"), isPaired: false, userDisconnected: false
        ) == .deviceNotPaired)

        #expect(LinkStatus.resolve(
            presence: .answering(udid: "UDID-A"), isPaired: true, userDisconnected: false
        ) == .connecting)

        #expect(LinkStatus.resolve(
            presence: .answering(udid: "UDID-A"), isPaired: true, userDisconnected: true
        ) == .switchedOff)
    }

    // An explicit Disconnect must not hide a more urgent fact. If the cable is
    // out, the cable is what needs fixing — "Switched off" would be true and
    // useless, and Reconnect would not help.
    @Test("Switched-off never masks a missing cable")
    func switchedOffDoesNotMaskTheCable() {
        #expect(LinkStatus.resolve(
            presence: .noDevice, isPaired: true, userDisconnected: true
        ) == .waitingForCable)

        #expect(LinkStatus.resolve(
            presence: .attachedNotAnswering, isPaired: true, userDisconnected: true
        ) == .deviceNotResponding)
    }

    // A record written before the wired transport carries no UDID and adopts
    // the first device it sessions with. Treating it as unpaired would tell the
    // user to pair a phone that is already paired, and the migration could
    // never happen.
    @Test("A legacy pairing with no UDID still counts as paired")
    func legacyPairingCounts() {
        #expect(LinkStatus.resolve(
            presence: .answering(udid: "UDID-NEW"), isPaired: true, userDisconnected: false
        ) == .connecting)
    }

    @Test("A relay failure surfaces its reason rather than a generic state")
    func failureCarriesItsReason() {
        let status = LinkStatus.resolve(
            presence: .failed("cannot reach usbmuxd"), isPaired: true, userDisconnected: false
        )
        #expect(status == .failed("cannot reach usbmuxd"))
        #expect(status.detail == "cannot reach usbmuxd")
    }

    // The headline is the product's answer to "why isn't it working?", so it
    // has to be distinct per cause — two states sharing a sentence is the bug
    // this suite exists for, one level up.
    @Test("No two states share a headline, and every one names an action")
    func everyStateIsDistinctAndActionable() {
        let states: [LinkStatus] = [
            .waitingForCable, .deviceNotResponding, .deviceNotPaired,
            .connecting, .switchedOff, .failed("boom"),
        ]
        let headlines = states.map(\.headline)
        #expect(Set(headlines).count == states.count, "two states say the same thing")
        for state in states {
            #expect(!state.detail.isEmpty, "\(state) offers the user nothing to do")
        }
        // The string the user actually asked to see.
        #expect(LinkStatus.waitingForCable.headline == "Waiting for USB connection")
    }
}

import Testing
@testable import UpLinkKit

@Suite("Not bridging, over the air")
struct LinkStatusAccessPointTests {

    @Test("An access point that is down is reported as such")
    func accessPointDownIsReported() {
        let status = LinkStatus.resolve(
            presence: .accessPointDown, isPaired: true, userDisconnected: false
        )
        #expect(status == .accessPointDown)
    }

    // With no access point there is no link to switch off, and "Switched off"
    // would send the user looking at the wrong thing entirely.
    @Test("Access point down outranks the user having switched off")
    func accessPointDownOutranksSwitchedOff() {
        let status = LinkStatus.resolve(
            presence: .accessPointDown, isPaired: true, userDisconnected: true
        )
        #expect(status == .accessPointDown)
    }

    @Test("An access point up with no phone on it is a distinct state")
    func noPeerDiscovered() {
        let status = LinkStatus.resolve(
            presence: .noPeerDiscovered, isPaired: true, userDisconnected: false
        )
        #expect(status == .waitingForPhone)
    }

    // The same guard the existing cases have: a case cannot be added without a
    // sentence and a remedy to go with it.
    @Test("Every status has both a headline and an action")
    func everyStatusHasBoth() {
        let all: [LinkStatus] = [
            .accessPointDown, .waitingForPhone, .waitingForCable,
            .deviceNotResponding, .deviceNotPaired, .connecting,
            .pairingLost, .switchedOff, .failed("x"),
        ]
        for status in all {
            #expect(!status.headline.isEmpty)
            #expect(!status.detail.isEmpty)
        }
    }
}

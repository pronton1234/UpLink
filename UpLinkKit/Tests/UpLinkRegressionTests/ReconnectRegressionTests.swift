import Testing
import Foundation
import Network
@testable import UpLinkKit

@Suite("Regression: reconnect")
struct ReconnectRegressionTests {

    // The peer-matching half of this suite is gone with `PeerResolver`.
    // Finding the peer used to be a real problem — an address that churned on
    // every AWDL reconnect, a fingerprint that had to be read out of a Bonjour
    // TXT record before dialling. Over the cable there is nothing to resolve:
    // `usbmuxd` reports the device by UDID, and the Mac dials it. What remains
    // worth guarding is the backoff, because the extension can still be
    // restarting when the Mac dials and a tight retry loop would drain the
    // phone.
    // lid and nothing happened.
    @Test("Backoff is capped so a long outage still recovers promptly")
    func backoffIsCapped() {
        var policy = ReconnectPolicy(baseDelay: 1, maxDelay: 30)
        var last: TimeInterval = 0
        for _ in 0 ..< 50 { last = policy.recordFailure() }
        #expect(last == 30)
    }

    @Test("Backoff grows between successive failures")
    func backoffGrows() {
        var policy = ReconnectPolicy(baseDelay: 1, maxDelay: 30)
        let first = policy.recordFailure()
        let second = policy.recordFailure()
        let third = policy.recordFailure()

        #expect(first < second)
        #expect(second < third)
    }

    // SYMPTOM: a successful reconnect left the failure count intact, so the
    // next unrelated drop started at the top of the backoff schedule and took
    // 30 seconds to recover from a momentary blip.
    @Test("A successful connection resets the backoff schedule")
    func successResetsBackoff() {
        var policy = ReconnectPolicy(baseDelay: 1, maxDelay: 30)
        for _ in 0 ..< 10 { _ = policy.recordFailure() }
        policy.recordSuccess()

        #expect(policy.attempt == 0)
        #expect(policy.recordFailure() == 1)
    }
}

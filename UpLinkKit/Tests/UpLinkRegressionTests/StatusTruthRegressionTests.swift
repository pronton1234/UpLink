import Testing
import Foundation
@testable import UpLinkKit

// SYMPTOM: "I have to reconnect the devices even though they seem to already be
// connected. And when I 'forget' a device, it still shows as connected."
//
// That is worse than a cosmetic bug. Every on-device measurement taken while
// the indicator was wrong was measuring an unknown state — including a coverage
// run that reported no connectivity at all, taken in good faith against a
// session that had already ended.
//
// CAUSE: the status poll did `guard parts.first == "connected" else { return }`.
// Any other reply — including an explicit `disconnected` — was treated as "no
// new information", so the UI kept the last connected state forever. Nothing
// distinguished "the extension says it is gone" from "the extension did not
// answer".

@Suite("Regression: the status indicator must be truthful")
struct StatusTruthRegressionTests {

    @Test("An explicit disconnected reply is believed")
    func disconnectedIsBelieved() {
        #expect(BridgeStatusReply.parse("disconnected") == .disconnected)
        #expect(BridgeStatusReply.parse("waiting") == .disconnected)
        #expect(BridgeStatusReply.parse("disconnected").isConnected == false)
    }

    /// Garbage must NOT read as disconnected. A momentary unintelligible reply
    /// should make the caller ask again, not tear down a working session's UI.
    @Test("An unintelligible reply is distinct from a disconnection")
    func garbageIsNotDisconnection() {
        #expect(BridgeStatusReply.parse(nil) == .unintelligible)
        #expect(BridgeStatusReply.parse("") == .unintelligible)
        #expect(BridgeStatusReply.parse("wat") == .unintelligible)
        #expect(BridgeStatusReply.parse("unavailable") == .unintelligible)
    }

    @Test("The Mac's reply shape parses, peer and egress included")
    func macReplyParses() {
        // ProxyState sends "connected|<peer>|<egressByte>".
        #expect(
            BridgeStatusReply.parse("connected|169.254.203.164:63056|1")
                == .connected(peer: "169.254.203.164:63056", egress: .cellular)
        )
    }

    @Test("The phone's reply shape parses too")
    func phoneReplyParses() {
        // PacketTunnelProvider sends "connected|<egressByte>".
        #expect(BridgeStatusReply.parse("connected|1") == .connected(peer: "", egress: .cellular))
        #expect(BridgeStatusReply.parse("connected|2") == .connected(peer: "", egress: .wifi))
    }

    /// A connection whose egress is not yet known is still a connection — it
    /// must not be mistaken for a disconnection.
    @Test("Connected with no egress yet is still connected")
    func connectedWithoutEgress() {
        #expect(BridgeStatusReply.parse("connected").isConnected)
        #expect(BridgeStatusReply.parse("connected") == .connected(peer: "", egress: .unknown))
    }

    /// The egress byte is found wherever it sits, because the two senders order
    /// their fields differently.
    @Test("Egress is recognised in either field position")
    func egressPositionIndependent() {
        if case let .connected(_, egress) = BridgeStatusReply.parse("connected|peer|1") {
            #expect(egress == .cellular)
        } else {
            Issue.record("should have parsed as connected")
        }
    }
}

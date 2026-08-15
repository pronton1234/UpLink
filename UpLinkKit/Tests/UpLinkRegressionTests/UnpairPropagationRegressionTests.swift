import Testing
import Foundation
import Network
@testable import UpLinkKit

// SYMPTOM, in the user's words: "when I remove a device from my mac, it doesn't
// automatically register on my phone and vice versa. This leads to a problem
// where the mac thinks the phone is connected even though the phone is trying
// to connect."
//
// Unpairing was purely local on both sides. `MenuBarModel.unpair` and
// `BridgeController.unpair` each dropped the key from their own store and tore
// down their own session, and neither told the other end anything.
//
// So after removing the phone on the Mac, the Mac rebuilt its listener
// advertising `sessionKeys=0` while the phone still held the pairing and kept
// dialling — failing the TLS-PSK handshake against an identity that no longer
// existed, on every retry, forever. From the phone there was nothing to
// distinguish that from any other connection failure, and from the Mac it
// looked like a device that would not connect.
//
// It also poisons any test run afterwards, which is how it surfaced: a stale
// pairing on one side makes every later measurement meaningless.

@Suite("Regression: unpairing must reach the other device")
struct UnpairPropagationRegressionTests {

    /// Discard port; nothing listens. Only the channel's lifecycle matters here.
    private func liveLookingChannel() -> NWConnectionChannel {
        NWConnectionChannel(connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp))
    }

    @Test("The unpaired frame survives a round trip")
    func framRoundTrips() throws {
        let frame = Multiplexer.unpairedFrame()
        #expect(frame.kind == .unpaired)
        #expect(frame.streamID == Multiplexer.controlStreamID)

        var decoder = FrameDecoder()
        decoder.append(FrameEncoder.encode(frame))
        let decoded = try #require(try decoder.next())
        #expect(decoded == frame, "an unpair notice did not survive encoding")
    }

    @Test("Receiving it raises unpairedByPeer")
    func receivingRaisesTheEvent() throws {
        var mux = Multiplexer(role: .initiator)
        let events = try mux.receive(Multiplexer.unpairedFrame())

        guard case .unpairedByPeer = try #require(events.first) else {
            Issue.record("expected .unpairedByPeer, got \(events)")
            return
        }
    }

    // It carries no payload deliberately. A strict parse would turn "you have
    // been unpaired" into "malformed frame" — leaving the user with a device
    // that keeps retrying and still no explanation, which is the bug.
    @Test("A payload on the notice is tolerated, not rejected")
    func extraPayloadIsTolerated() throws {
        var mux = Multiplexer(role: .initiator)
        let padded = Frame(
            kind: .unpaired,
            streamID: Multiplexer.controlStreamID,
            payload: Data([0x01, 0x02, 0x03])
        )
        let events = try mux.receive(padded)

        guard case .unpairedByPeer = try #require(events.first) else {
            Issue.record("a future sender adding a payload would be read as malformed")
            return
        }
    }

    // Control frames belong on the control stream. Accepting one on a data
    // stream would let a compromised stream revoke a pairing.
    @Test("It is refused on a data stream")
    func refusedOnDataStream() {
        var mux = Multiplexer(role: .initiator)
        let onDataStream = Frame(kind: .unpaired, streamID: 7, payload: Data())

        #expect(throws: (any Error).self) {
            _ = try mux.receive(onDataStream)
        }
    }

    // The reply the phone's UI acts on. `unpaired` must not be read as
    // `disconnected`, because those call for opposite behaviour: one means
    // retry, the other means stop and tell the user to pair again.
    @Test("An unpaired status is not mistaken for disconnected")
    func unpairedStatusIsDistinct() {
        #expect(BridgeStatusReply.parse("unpaired") == .unpaired(fingerprint: nil))
        #expect(BridgeStatusReply.parse("disconnected") == .disconnected)
        #expect(BridgeStatusReply.parse("unpaired") != .disconnected)
    }

    // The Mac names WHICH phone forgot it. Only the app can update the keychain,
    // and it cannot act on "someone unpaired us".
    @Test("An unpaired status carries the fingerprint when the Mac sends one")
    func unpairedStatusCarriesFingerprint() {
        #expect(
            BridgeStatusReply.parse("unpaired|336ee249d249baa4")
                == .unpaired(fingerprint: "336ee249d249baa4"),
            "the Mac cannot tell its app which device to forget"
        )
    }

    // Sticky on purpose: the notice arrives as the session is ending, so a flag
    // cleared with the session would never survive to the app's next poll.
    @Test("The phone remembers being unpaired after the session ends")
    func unpairFlagSurvivesTeardown() async {
        let state = PhoneSessionState()
        #expect(await state.wasUnpairedByPeer == false)

        await state.noteUnpairedByPeer()
        await state.teardown()

        #expect(
            await state.wasUnpairedByPeer,
            "the phone forgot it had been unpaired while tearing down — the app polls after that, so the notice is lost and it retries forever"
        )
    }

    // THE OTHER HALF, and the one I got wrong. The test above was the whole
    // suite, so it pinned stickiness as though stickiness alone were the
    // requirement — and `clearUnpairedByPeer()` ended up with ZERO call sites.
    //
    // The flag is checked before `isConnected` on every status poll, so once set
    // it answers "unpaired" for the life of the extension process. Re-pair, and
    // the first poll tells the app to delete the pairing it just made. That is
    // an unbreakable re-pair loop, and it is what "re-pairing fails and I have
    // to retry several times" actually was.
    //
    // Clearing belongs to the state machine, not to a caller who has to
    // remember: establishing a session at all means the Mac accepted us, which
    // means we are paired, which means any earlier revocation is stale.
    @Test("Starting a new session clears a stale unpaired flag")
    func newSessionClearsTheFlag() async throws {
        let state = PhoneSessionState()
        let channel = liveLookingChannel()
        let responder = BridgeResponder(
            channel: channel,
            dialer: CellularDialer(queue: DispatchQueue(label: "regression.repair"), requiredInterface: nil),
            localFingerprint: "phone"
        )

        // A previous pairing was revoked, and the flag correctly survived.
        await state.noteUnpairedByPeer()
        await state.teardown()
        #expect(await state.wasUnpairedByPeer)

        // Now the user re-pairs and a session is established.
        try await state.runningSession(channel: channel, responder: responder) {
            #expect(
                await state.wasUnpairedByPeer == false,
                "a freshly established session still reports the phone as unpaired — the app's next poll deletes the pairing that was just created, and re-pairing can never succeed"
            )
        }
    }

    @Test("The opcode is distinct from every other kind")
    func opcodeIsUnique() {
        let all = Frame.Kind.allCases
        #expect(Set(all.map(\.rawValue)).count == all.count, "two frame kinds share an opcode")
        #expect(Frame.Kind(rawValue: 0x0D) == .unpaired)
    }
}

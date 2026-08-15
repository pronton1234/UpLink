import Testing
import Foundation
import Network
@testable import UpLinkKit

// SYMPTOM, in the user's words: "even though my phone says its connected,
// sometimes the mac doesn't and now I'm not sure what is going on".
//
// The Mac was right. At the time of the screenshot the Mac had had no session
// for minutes — no `accept:`, nothing but idle status polling — while the phone
// showed "Connected to Pranit's MacBook Air / Waiting for your Mac to send
// something."
//
// `connectOnce` set the channel on the shared state and never cleared it. The
// responder was cleared in a `defer`; the channel had no such thing. Since
// `isConnected` was `channel != nil`, the phone reported itself connected for
// the life of the tunnel — through the session ending, through every failed
// retry, through the Mac having nothing at all.
//
// And because the responder WAS cleared, `observedEgress` fell back to
// `.unknown`, which the UI renders as exactly that "waiting for your Mac"
// caption. So the failure disguised itself as a Mac-side problem and cost two
// rounds of debugging aimed at the wrong device.
//
// The deeper fault was that this lived in a `private actor` inside the
// extension, where no test could reach it. That is why it survived every
// on-device round: it presents as a UI bug and lives in networking code.

@Suite("Regression: the phone must not claim a session it does not have")
struct PhoneConnectedStateRegressionTests {

    /// A channel that is closed from the start, standing in for one whose
    /// session has ended. Building a real connected pair needs a listener and a
    /// handshake; the claim under test is only about lifecycle bookkeeping.
    private func spentChannel() async -> NWConnectionChannel {
        let channel = NWConnectionChannel(
            connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
        )
        await channel.close()
        return channel
    }

    private func liveLookingChannel() -> NWConnectionChannel {
        NWConnectionChannel(connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp))
    }

    @Test("A session that ends leaves the phone reporting disconnected")
    func endedSessionIsNotConnected() async throws {
        let state = PhoneSessionState()
        let channel = liveLookingChannel()
        let responder = BridgeResponder(
            channel: channel,
            dialer: CellularDialer(queue: DispatchQueue(label: "regression.phone"), requiredInterface: nil),
            localFingerprint: "phone"
        )

        #expect(await state.isConnected == false, "connected before anything happened")

        try await state.runningSession(channel: channel, responder: responder) {
            #expect(await state.isConnected, "not connected during a session")
        }

        #expect(
            await state.isConnected == false,
            "the phone still reports a live session after it ended — the UI will show 'Connected' while the Mac has nothing, which is what sent two rounds of debugging at the wrong device"
        )
    }

    @Test("A session that throws also leaves it disconnected")
    func failedSessionIsNotConnected() async {
        let state = PhoneSessionState()
        let channel = liveLookingChannel()
        let responder = BridgeResponder(
            channel: channel,
            dialer: CellularDialer(queue: DispatchQueue(label: "regression.phone"), requiredInterface: nil),
            localFingerprint: "phone"
        )

        struct Dropped: Error {}
        await #expect(throws: Dropped.self) {
            try await state.runningSession(channel: channel, responder: responder) {
                throw Dropped()
            }
        }

        #expect(
            await state.isConnected == false,
            "a failed attempt left the phone believing it was connected — every retry after this reports success"
        )
    }

    // The other half: holding a channel is not the same as having a connection.
    // Even without the lifecycle fix, a closed channel must never read as live,
    // because the reconnect path can hand back a channel that died on its own.
    @Test("A closed channel is not a connection")
    func closedChannelIsNotConnected() async {
        let state = PhoneSessionState()
        await state.setPendingChannel(await spentChannel())

        #expect(
            await state.isConnected == false,
            "a spent channel reads as a live session — 'do I have a channel' is not 'am I connected'"
        )
    }

    @Test("Teardown clears the session")
    func teardownClearsEverything() async {
        let state = PhoneSessionState()
        await state.setPendingChannel(liveLookingChannel())
        await state.teardown()

        #expect(await state.isConnected == false, "still connected after teardown")
        #expect(await state.observedEgress == nil, "still reporting egress after teardown")
    }
}

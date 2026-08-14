import Testing
import Foundation
@testable import UpLinkKit

// SYMPTOM: with the bridge live and the Mac running on the phone alone, pages
// half-loaded. Not "no internet" — some requests worked and most did not, which
// is a far more confusing symptom than being offline.
//
// One app (`com.relay.mac`, reconnect-storming after the Mac lost Wi-Fi)
// produced 55,536 claimed flows in about two minutes:
//
//     tcp FAIL : 55,618   of which streamLimitReached: 50,712
//     tcp open :     13
//
// and, decisively, **the failures did not stop when the storm did**. Four
// minutes later, with 1–6 claims per 15s, every request still failed. The 4,096
// stream slots had not been consumed by live traffic — they had been leaked.
//
// `openStream` allocates the mux slot, then writes the OPEN frame. Both steps
// after the allocation could abandon the stream without releasing it:
//
//   1. the write throws — routine, not exceptional, because
//      `NWConnectionChannel.sendTimeout` bounds it and congestion is when it
//      bites;
//   2. the caller's `withFlowDeadline` expires while the OPEN is in flight.
//      That cancels the surrounding group but does not unwind `openStream`,
//      which carries on and allocates a slot nobody owns.
//
// The second is the dominant one under load: congestion is precisely when the
// write outlives the deadline.
//
// A leaked slot is never reclaimed for the life of the session, so this is not
// a transient degradation — it is a session that gets permanently worse.

@Suite("Regression: stream slots are never leaked")
struct StreamLeakRegressionTests {

    /// A channel that refuses to carry anything, so `write` throws exactly as it
    /// does when the peer has stopped draining.
    private actor DeadChannel: FrameChannel {
        func send(_ bytes: Data) async throws { throw ChannelError.peerClosed }
        func receive() async throws -> Data? {
            try await Task.sleep(for: .seconds(60))
            return nil
        }
        func close() async {}
    }

    /// A channel that accepts writes but never delivers, so an OPEN is "in
    /// flight" for as long as the test needs.
    private actor SlowChannel: FrameChannel {
        func send(_ bytes: Data) async throws { try await Task.sleep(for: .seconds(30)) }
        func receive() async throws -> Data? {
            try await Task.sleep(for: .seconds(60))
            return nil
        }
        func close() async {}
    }

    private let destination = StreamOpen(proto: .tcp, host: "example.com", port: 443)

    // Leak path 1: the write fails.
    @Test("A failed OPEN write gives the stream slot back")
    func failedWriteReleasesTheSlot() async throws {
        let initiator = BridgeInitiator(channel: DeadChannel())

        // Far more attempts than there are slots. If each failure leaked one,
        // the errors would change from the channel's to streamLimitReached.
        for _ in 0 ..< (Multiplexer.maxConcurrentStreams + 500) {
            do {
                _ = try await initiator.openStream(to: destination)
                Issue.record("open unexpectedly succeeded on a dead channel")
            } catch let error as MuxError {
                #expect(
                    error != .streamLimitReached,
                    "slots ran out, so failed opens are leaking them"
                )
            } catch {
                // The channel error is the expected outcome.
            }
        }

        // And the mux is still usable afterwards, which is the property that
        // actually matters: one app's storm must not poison the session.
        await #expect(throws: Never.self) {
            _ = try? await initiator.openStream(to: destination)
        }
    }

    // Leak path 2, and the one that did the damage: the caller gives up while
    // the OPEN is still being written.
    @Test("An OPEN abandoned by its deadline gives the stream slot back")
    func abandonedOpenReleasesTheSlot() async throws {
        let initiator = BridgeInitiator(channel: SlowChannel())

        for _ in 0 ..< 200 {
            // Exactly what `withFlowDeadline` does to a slow open: start it,
            // then walk away.
            let attempt = Task { try await initiator.openStream(to: destination) }
            try await Task.sleep(for: .milliseconds(2))
            attempt.cancel()
            _ = try? await attempt.value
        }

        // 200 abandoned opens is well under the 4,096 cap, so this does not
        // prove the cap — it proves the slots came back.
        let live = await initiator.openStreamCount
        #expect(
            live == 0,
            "\(live) stream slots are held by opens nobody owns — this is the leak"
        )
    }
}

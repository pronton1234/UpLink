import Testing
import Foundation
import Network
@testable import UpLinkKit

// SYMPTOM: with the bridge "connected" and the Mac running on the phone, every
// new browser tab failed to load. Six minutes of a live session:
//
//     tcp claim  31,453      tcp open  30
//     tcp FAIL   31,423      of which POSIXErrorCode(32) Broken pipe: 31,034
//     session ENDED: 0
//
// The pipe to the phone broke 13 seconds in and NOTHING NOTICED. `hasSession`
// stayed true, so `handleNewFlow` went on claiming every flow on the machine —
// Chrome's 268 among them — and every one died in `openStream`'s write. Both
// ends kept reporting a healthy bridge.
//
// Two causes, both of them a failure to observe:
//
//   1. `NWConnectionChannel` installed its `stateUpdateHandler` inside
//      `start(on:)`'s `OneShot`-guarded continuation, and `OneShot` nils the
//      continuation on first use. After `.ready`, every later state — including
//      `.failed` and `.cancelled` — was silently discarded. The only remaining
//      liveness sensor was an outstanding `connection.receive` callback, so a
//      connection that died while no read was armed became a zombie:
//      `isClosed == false`, `receive()` suspended on a continuation nobody
//      would resume, `sessionFinished` never called.
//
//   2. `send` threw the raw error and did nothing else — it did not mark the
//      channel closed or cancel the connection — so a permanently broken pipe
//      was rediscovered by every subsequent flow, forever.
//
// docs/REGRESSIONS.md already half-stated the rule: "a failure path that closes
// the flow". That was implemented. The sequel — "and fail the session" — was
// not, even though `sendTimeout`'s own comment claims it.

@Suite("Regression: a dead channel must end the session")
struct DeadChannelRegressionTests {

    // The classification that decides whether one write failing means the
    // CONNECTION is finished. Getting this wrong in the permissive direction
    // ends sessions over hiccups; getting it wrong in the strict direction is
    // the bug above.
    @Test("Hard connection errors are terminal, transient ones are not")
    func terminalErrorsAreClassified() {
        // The one actually observed, 31,034 times.
        #expect(NWConnectionChannel.isTerminal(.posix(.EPIPE)))
        #expect(NWConnectionChannel.isTerminal(.posix(.ECONNRESET)))
        #expect(NWConnectionChannel.isTerminal(.posix(.ENOTCONN)))
        // Losing the network under a live session is equally final for this
        // socket — the phone has to redial.
        #expect(NWConnectionChannel.isTerminal(.posix(.ENETDOWN)))
        #expect(NWConnectionChannel.isTerminal(.posix(.EHOSTUNREACH)))
        #expect(NWConnectionChannel.isTerminal(.posix(.ENETUNREACH)))

        // NOT terminal: retrying can genuinely help, and ending a session here
        // would be its own outage.
        #expect(NWConnectionChannel.isTerminal(.posix(.EAGAIN)) == false)
        #expect(NWConnectionChannel.isTerminal(.posix(.EINTR)) == false)
        // A TLS or DNS error at this point is not a dead pipe.
        #expect(NWConnectionChannel.isTerminal(.dns(0)) == false)
    }

    // The property the whole change exists for, at the level the session cares
    // about: once the channel is finished, the frame loop must END rather than
    // suspend forever. `BridgeInitiator.pump()` exits on `receive() -> nil`,
    // and `MacSessionHost` turns that into `.sessionEnded`.
    @Test("A finished channel makes the frame loop end instead of hanging")
    func finishedChannelEndsTheFrameLoop() async throws {
        let channel = ClosableChannel()
        let initiator = BridgeInitiator(channel: channel)

        let ran = Task { try await initiator.run() }

        // Let the loop suspend on receive.
        try await Task.sleep(for: .milliseconds(50))

        // Exactly what the live `stateUpdateHandler` now does on `.failed`.
        await channel.finishFromStateHandler()

        // Bounded: before the fix this never returned, which is the bug.
        let ended = await withTaskGroup(of: Bool.self) { group in
            group.addTask { _ = try? await ran.value; return true }
            group.addTask { try? await Task.sleep(for: .seconds(3)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        #expect(ended, "the frame loop did not end — the session would never be torn down")
    }

    // NOT YET PINNED BY A TEST — stated plainly rather than left implied.
    //
    // The property that actually failed is the send path: after a write finds
    // the connection dead, the CHANNEL must close once, so the frame loop ends
    // and the next 31,000 flows do not each rediscover the same corpse. The fix
    // for it is `isTerminal` + `finish()` in `NWConnectionChannel.send`, and
    // `terminalErrorsAreClassified` above covers the classification half.
    //
    // Two attempts at an end-to-end version were abandoned. The first killed the
    // far side while a read was armed and passed WITHOUT the fix — the receive
    // callback already handled that case, which is precisely why it was the
    // wrong test: the failure was never on the receive path. The second drove
    // real writes into a dead socket and hung, because `sendTimeout` is 10s and
    // a loop of them costs minutes.
    //
    // The honest next step is a `FrameChannel` seam that lets a test inject a
    // terminal send error without a real socket, rather than a slower real-socket
    // test that still would not isolate the property. Doing it properly is worth
    // more than a test that passes for the wrong reason.

    // Kept as a guard on the plumbing: a finished channel must end the frame
    // loop. It passes with or without the state-handler change, and is here so
    // that property cannot regress independently.
    @Test("A real connection killed after .ready surfaces as end-of-stream", .timeLimit(.minutes(1)))
    func realConnectionDeathIsNoticed() async throws {
        let queue = DispatchQueue(label: "regression.deadchannel")

        // A listener that accepts, then drops the connection on the floor.
        let listener = try NWListener(using: .tcp)
        nonisolated(unsafe) var accepted: NWConnection?
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            accepted = connection
        }
        listener.start(queue: queue)
        defer { listener.cancel() }

        var port: NWEndpoint.Port?
        for _ in 0 ..< 300 {
            if let p = listener.port, p.rawValue != 0 { port = p; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let bound = try #require(port)

        let connection = NWConnection(host: "127.0.0.1", port: bound, using: .tcp)
        let channel = NWConnectionChannel(connection: connection)
        try await channel.start(on: queue)

        // Now suspend on a read, exactly as the frame loop does.
        let reading = Task { try await channel.receive() }
        try await Task.sleep(for: .milliseconds(100))

        // Kill it from the far side. The connection goes terminal AFTER
        // `.ready`, which is precisely the state the old code discarded.
        accepted?.forceCancel()
        accepted = nil

        let result = await withTaskGroup(of: Bool.self) { group in
            group.addTask { _ = try? await reading.value; return true }
            group.addTask { try? await Task.sleep(for: .seconds(5)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        reading.cancel()

        #expect(
            result,
            "receive() never returned after the connection died — the channel is a zombie and the session would never end"
        )
    }

    /// A channel whose `receive` suspends until something declares it finished,
    /// which is precisely the shape of the real one.
    private actor ClosableChannel: FrameChannel {
        private var waiters: [CheckedContinuation<Data?, Error>] = []
        private var isClosed = false

        func send(_ bytes: Data) async throws {}

        func receive() async throws -> Data? {
            if isClosed { return nil }
            return try await withCheckedThrowingContinuation { waiters.append($0) }
        }

        func close() async { finishFromStateHandler() }

        /// Stands in for the connection reporting `.failed` after `.ready`.
        func finishFromStateHandler() {
            guard !isClosed else { return }
            isClosed = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume(returning: nil) }
        }
    }
}

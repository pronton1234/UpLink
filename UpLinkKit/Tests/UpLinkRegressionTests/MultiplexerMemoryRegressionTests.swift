import Testing
import Foundation
@testable import UpLinkKit

@Suite("Regression: multiplexer memory")
struct MultiplexerMemoryRegressionTests {

    private let dest = StreamOpen(proto: .tcp, host: "example.com", port: 443)

    // SYMPTOM: the multiplexer remembered every closed stream ID forever so it
    // could tell a stale frame apart from a frame for a stream that never
    // existed. A browser opens streams constantly, so across a multi-day
    // session that set grows without bound inside the macOS system extension —
    // a slow leak in the one process the user never restarts.
    //
    // Stream IDs are allocated monotonically, so a high-water mark answers the
    // same question in constant space.
    @Test("Closed-stream bookkeeping does not grow with the number of closed streams")
    func closedStreamBookkeepingIsBounded() throws {
        var mux = Multiplexer(role: .initiator)

        for _ in 0 ..< 50_000 {
            let id = try mux.openStream(to: dest).streamID
            _ = try mux.closeStream(id)
        }

        #expect(mux.retainedStreamStateCount == 0)
        #expect(mux.openStreamIDs.isEmpty)
    }

    // The bookkeeping change must not cost the behaviour it existed for.
    @Test("A stale frame for a closed stream is still ignored after many cycles")
    func staleFrameStillIgnoredAfterManyCycles() throws {
        var mux = Multiplexer(role: .responder)

        for id in UInt32(1) ... 1_000 {
            _ = try mux.receive(Frame(kind: .open, streamID: id, payload: dest.encoded()))
            _ = try mux.receive(Frame(kind: .close, streamID: id))
        }

        // Long-closed stream: ignored.
        #expect(try mux.receive(Frame(kind: .data, streamID: 1, payload: Data([0]))).isEmpty)
        // Never-opened stream beyond the high-water mark: still an error.
        #expect(throws: MuxError.unknownStream(9_999)) {
            try mux.receive(Frame(kind: .data, streamID: 9_999, payload: Data([0])))
        }
    }

    // SYMPTOM: a peer opens streams without ever closing them and the
    // multiplexer allocates state for each, exhausting memory in the extension.
    @Test("A peer cannot open unbounded concurrent streams")
    func concurrentStreamsAreCapped() throws {
        var mux = Multiplexer(role: .responder)

        for id in UInt32(1) ... UInt32(Multiplexer.maxConcurrentStreams) {
            _ = try mux.receive(Frame(kind: .open, streamID: id, payload: dest.encoded()))
        }

        #expect(throws: MuxError.streamLimitReached) {
            try mux.receive(
                Frame(kind: .open,
                      streamID: UInt32(Multiplexer.maxConcurrentStreams) + 1,
                      payload: dest.encoded())
            )
        }
    }
}

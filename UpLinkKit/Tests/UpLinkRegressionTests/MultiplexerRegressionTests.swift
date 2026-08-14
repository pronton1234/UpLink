import Testing
import Foundation
@testable import UpLinkKit

@Suite("Regression: multiplexer")
struct MultiplexerRegressionTests {

    private let dest = StreamOpen(proto: .tcp, host: "example.com", port: 443)

    // SYMPTOM: a large download saturates the single shared TLS connection and
    // every other stream stalls behind it — clicking a link while a file is
    // downloading appears to hang the whole bridge. Per-stream credit is what
    // bounds any one stream's occupancy of the shared link; without it, one
    // stream can enqueue unbounded bytes and head-of-line block the rest.
    @Test("A stream that has exhausted its credit cannot starve other streams")
    func exhaustedStreamDoesNotStarveOthers() throws {
        var mux = Multiplexer(role: .initiator)
        let bigDownload = try mux.openStream(to: dest).streamID
        let smallRequest = try mux.openStream(to: dest).streamID

        // Saturate the big stream.
        let saturating = try mux.send(
            Data(repeating: 0, count: Multiplexer.initialWindow * 4), on: bigDownload
        )
        #expect(saturating.accepted == Multiplexer.initialWindow)
        #expect(try mux.sendCredit(for: bigDownload) == 0)

        // The whole point: the other stream is completely unaffected.
        let small = try mux.send(Data(repeating: 1, count: 8_192), on: smallRequest)
        #expect(small.accepted == 8_192)
        #expect(try mux.sendCredit(for: smallRequest) == Multiplexer.initialWindow - 8_192)
    }

    // SYMPTOM: window accounting is tracked globally rather than per stream, so
    // consuming bytes on one stream hands credit back for another. The peer
    // then overruns a window it was never actually granted.
    @Test("Consuming bytes on one stream never grants credit on another")
    func windowAccountingIsPerStream() throws {
        var mux = Multiplexer(role: .responder)
        _ = try mux.receive(Frame(kind: .open, streamID: 1, payload: dest.encoded()))
        _ = try mux.receive(Frame(kind: .open, streamID: 2, payload: dest.encoded()))

        // Fill stream 1's window completely.
        var sent = 0
        while sent < Multiplexer.initialWindow {
            let chunk = min(Frame.maxPayloadSize, Multiplexer.initialWindow - sent)
            _ = try mux.receive(Frame(kind: .data, streamID: 1, payload: Data(repeating: 0, count: chunk)))
            sent += chunk
        }

        // Draining stream 2 must not make room on stream 1.
        _ = try? mux.consumedReceivedBytes(Multiplexer.initialWindow, on: 2)

        #expect(throws: MuxError.flowControlViolation(1)) {
            try mux.receive(Frame(kind: .data, streamID: 1, payload: Data([0])))
        }
    }

    // SYMPTOM: stream IDs are reused after close while the peer still has
    // frames in flight for the old stream, so a late DATA frame is delivered
    // into a brand-new, unrelated flow — one site's bytes appear inside
    // another's connection.
    @Test("A closed stream's ID is not immediately handed to a new stream")
    func closedStreamIDsAreNotImmediatelyReused() throws {
        var mux = Multiplexer(role: .initiator)

        var seen = Set<UInt32>()
        for _ in 0 ..< 200 {
            let id = try mux.openStream(to: dest).streamID
            #expect(!seen.contains(id), "stream ID \(id) was reused after close")
            seen.insert(id)
            _ = try mux.closeStream(id)
        }
    }
}

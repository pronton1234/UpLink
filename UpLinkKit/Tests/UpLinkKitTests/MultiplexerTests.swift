import Testing
import Foundation
@testable import UpLinkKit

// The multiplexer carries every proxied flow over one TLS connection. It owns
// no socket by design: it takes frames in and hands frames out, so the whole of
// its flow-control behaviour is exercised here without a network in sight.

@Suite("Multiplexer")
struct MultiplexerTests {

    private func initiator() -> Multiplexer { Multiplexer(role: .initiator) }
    private func responder() -> Multiplexer { Multiplexer(role: .responder) }

    private let dest = StreamOpen(proto: .tcp, host: "example.com", port: 443)

    // MARK: Stream lifecycle

    @Test("Opening a stream emits an OPEN frame carrying the destination")
    func openEmitsOpenFrame() throws {
        var mux = initiator()
        let opened = try mux.openStream(to: dest)

        #expect(opened.frame.kind == .open)
        #expect(opened.frame.streamID == opened.streamID)
        #expect(try StreamOpen(payload: opened.frame.payload) == dest)
    }

    @Test("Each opened stream gets a distinct ID")
    func streamIDsAreDistinct() throws {
        var mux = initiator()
        let ids = try (0 ..< 100).map { _ in try mux.openStream(to: dest).streamID }
        #expect(Set(ids).count == 100)
    }

    @Test("Stream ID 0 is never allocated — it is reserved for the control channel")
    func controlStreamIDIsNeverAllocated() throws {
        var mux = initiator()
        let ids = try (0 ..< 50).map { _ in try mux.openStream(to: dest).streamID }
        #expect(!ids.contains(0))
    }

    @Test("The responder side may not open streams")
    func responderCannotOpen() {
        var mux = responder()
        #expect(throws: MuxError.responderCannotOpenStreams) { try mux.openStream(to: dest) }
    }

    @Test("An inbound OPEN surfaces as an event with its destination")
    func inboundOpenSurfaces() throws {
        var mux = responder()
        let events = try mux.receive(Frame(kind: .open, streamID: 1, payload: dest.encoded()))

        #expect(events == [.openRequested(streamID: 1, destination: dest)])
    }

    @Test("Two OPENs for the same stream ID are rejected")
    func duplicateOpenIsRejected() throws {
        var mux = responder()
        _ = try mux.receive(Frame(kind: .open, streamID: 1, payload: dest.encoded()))

        #expect(throws: MuxError.duplicateStream(1)) {
            try mux.receive(Frame(kind: .open, streamID: 1, payload: dest.encoded()))
        }
    }

    @Test("Closing a stream emits CLOSE and forgets the stream")
    func closeForgetsStream() throws {
        var mux = initiator()
        let opened = try mux.openStream(to: dest)

        let frame = try mux.closeStream(opened.streamID)
        #expect(frame.kind == .close)
        #expect(mux.openStreamIDs.isEmpty)
    }

    @Test("Data for a stream that was never opened is rejected")
    func dataForUnknownStreamIsRejected() {
        var mux = responder()
        #expect(throws: MuxError.unknownStream(9)) {
            try mux.receive(Frame(kind: .data, streamID: 9, payload: Data("x".utf8)))
        }
    }

    // A closed stream's frames arrive routinely — the peer closed while our
    // DATA was already in flight. That is a race, not an attack, so it must be
    // ignored rather than treated as a protocol violation that kills the link.
    @Test("Data arriving after CLOSE is ignored, not treated as an error")
    func dataAfterCloseIsIgnored() throws {
        var mux = responder()
        _ = try mux.receive(Frame(kind: .open, streamID: 1, payload: dest.encoded()))
        _ = try mux.receive(Frame(kind: .close, streamID: 1))

        #expect(try mux.receive(Frame(kind: .data, streamID: 1, payload: Data("late".utf8))).isEmpty)
    }

    // MARK: Flow control

    @Test("A newly opened stream starts with exactly one window of credit")
    func newStreamHasFullCredit() throws {
        var mux = initiator()
        let opened = try mux.openStream(to: dest)
        #expect(try mux.sendCredit(for: opened.streamID) == Multiplexer.initialWindow)
    }

    @Test("Sending consumes credit byte for byte")
    func sendingConsumesCredit() throws {
        var mux = initiator()
        let id = try mux.openStream(to: dest).streamID

        _ = try mux.send(Data(repeating: 0, count: 1_000), on: id)

        #expect(try mux.sendCredit(for: id) == Multiplexer.initialWindow - 1_000)
    }

    @Test("A send larger than the remaining credit is accepted only in part")
    func oversizedSendIsPartiallyAccepted() throws {
        var mux = initiator()
        let id = try mux.openStream(to: dest).streamID

        let result = try mux.send(Data(repeating: 0, count: Multiplexer.initialWindow + 5_000), on: id)

        #expect(result.accepted == Multiplexer.initialWindow)
        #expect(try mux.sendCredit(for: id) == 0)
    }

    @Test("A send with no credit left is accepted as zero bytes rather than throwing")
    func sendWithoutCreditAcceptsNothing() throws {
        var mux = initiator()
        let id = try mux.openStream(to: dest).streamID
        _ = try mux.send(Data(repeating: 0, count: Multiplexer.initialWindow), on: id)

        let result = try mux.send(Data(repeating: 0, count: 100), on: id)

        #expect(result.accepted == 0)
        #expect(result.frames.isEmpty)
    }

    @Test("A WINDOW frame replenishes credit and surfaces a creditGranted event")
    func windowFrameReplenishesCredit() throws {
        var mux = initiator()
        let id = try mux.openStream(to: dest).streamID
        _ = try mux.send(Data(repeating: 0, count: Multiplexer.initialWindow), on: id)

        var payload = Data()
        payload.append(bigEndian: UInt32(4_096))
        let events = try mux.receive(Frame(kind: .window, streamID: id, payload: payload))

        #expect(events == [.creditGranted(streamID: id)])
        #expect(try mux.sendCredit(for: id) == 4_096)
    }

    @Test("No single DATA frame exceeds the maximum payload size")
    func dataIsChunkedToMaxPayload() throws {
        var mux = initiator()
        let id = try mux.openStream(to: dest).streamID

        let result = try mux.send(Data(repeating: 0, count: Multiplexer.initialWindow), on: id)

        #expect(result.frames.allSatisfy { $0.payload.count <= Frame.maxPayloadSize })
        #expect(result.frames.reduce(0) { $0 + $1.payload.count } == Multiplexer.initialWindow)
    }

    @Test("A peer that sends beyond the advertised window is a flow-control violation")
    func inboundOverrunIsViolation() throws {
        var mux = responder()
        _ = try mux.receive(Frame(kind: .open, streamID: 1, payload: dest.encoded()))

        // Fill the window exactly.
        var sent = 0
        while sent < Multiplexer.initialWindow {
            let chunk = min(Frame.maxPayloadSize, Multiplexer.initialWindow - sent)
            _ = try mux.receive(Frame(kind: .data, streamID: 1, payload: Data(repeating: 0, count: chunk)))
            sent += chunk
        }

        #expect(throws: MuxError.flowControlViolation(1)) {
            try mux.receive(Frame(kind: .data, streamID: 1, payload: Data([0])))
        }
    }

    @Test("Consuming received bytes emits a WINDOW frame once half the window is free")
    func consumingEmitsWindowUpdate() throws {
        var mux = responder()
        _ = try mux.receive(Frame(kind: .open, streamID: 1, payload: dest.encoded()))
        _ = try mux.receive(Frame(kind: .data, streamID: 1,
                                  payload: Data(repeating: 0, count: Multiplexer.initialWindow / 2)))

        let frame = try mux.consumedReceivedBytes(Multiplexer.initialWindow / 2, on: 1)

        #expect(frame?.kind == .window)
        #expect(frame?.streamID == 1)
    }

    @Test("Consuming a trickle does not emit a WINDOW frame for every byte")
    func smallConsumptionDoesNotSpamWindowUpdates() throws {
        var mux = responder()
        _ = try mux.receive(Frame(kind: .open, streamID: 1, payload: dest.encoded()))
        _ = try mux.receive(Frame(kind: .data, streamID: 1, payload: Data(repeating: 0, count: 1_000)))

        #expect(try mux.consumedReceivedBytes(1, on: 1) == nil)
    }

    // MARK: Control channel

    @Test("A PING is answered with a PONG on the control stream")
    func pingIsAnswered() throws {
        var mux = initiator()
        let events = try mux.receive(Frame(kind: .ping, streamID: 0))
        #expect(events == [.pingReceived])
    }

    @Test("An egress report surfaces the interface the peer actually used")
    func egressReportSurfaces() throws {
        var mux = initiator()
        let events = try mux.receive(
            Frame(kind: .egressReport, streamID: 0, payload: Data([EgressInterface.cellular.rawValue]))
        )
        #expect(events == [.egressReported(.cellular)])
    }

    @Test("Control frames are refused on a non-zero stream ID")
    func controlFramesRejectedOffControlStream() throws {
        var mux = initiator()
        _ = try mux.openStream(to: dest)

        #expect(throws: MuxError.self) {
            try mux.receive(Frame(kind: .ping, streamID: 1))
        }
    }
}

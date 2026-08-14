import Testing
import Foundation
@testable import UpLinkKit

// The bridge reads from a stream socket, so frames arrive in arbitrary chunks:
// half a header, three frames at once, a payload split across five reads. The
// decoder is the one component that sees every byte the peer sends, including
// bytes from a peer that is confused or hostile, so it carries most of the
// robustness burden in the protocol layer.

@Suite("Frame codec")
struct FrameCodecTests {

    @Test("A frame survives an encode/decode round trip intact")
    func roundTrip() throws {
        let original = Frame(kind: .data, streamID: 42, payload: Data("hello bridge".utf8))

        var decoder = FrameDecoder()
        decoder.append(FrameEncoder.encode(original))

        #expect(try decoder.next() == original)
    }

    @Test("The decoder yields nothing until an entire header has arrived")
    func partialHeaderYieldsNothing() throws {
        let encoded = FrameEncoder.encode(Frame(kind: .ping, streamID: 0, payload: Data()))

        var decoder = FrameDecoder()
        decoder.append(encoded.prefix(Frame.headerSize - 1))

        #expect(try decoder.next() == nil)
    }

    @Test("A frame split across single-byte appends is reassembled")
    func reassemblesByteAtATime() throws {
        let original = Frame(kind: .open, streamID: 7, payload: Data("example.com".utf8))
        let encoded = FrameEncoder.encode(original)

        var decoder = FrameDecoder()
        var decoded: Frame?
        for byte in encoded {
            decoder.append(Data([byte]))
            if let frame = try decoder.next() {
                decoded = frame
            }
        }

        #expect(decoded == original)
    }

    @Test("Several frames delivered in one append are yielded in order")
    func multipleFramesInOneAppend() throws {
        let frames = [
            Frame(kind: .open, streamID: 1, payload: Data("a".utf8)),
            Frame(kind: .data, streamID: 1, payload: Data("bb".utf8)),
            Frame(kind: .close, streamID: 1, payload: Data()),
        ]

        var decoder = FrameDecoder()
        decoder.append(frames.map(FrameEncoder.encode).reduce(Data(), +))

        var decoded: [Frame] = []
        while let frame = try decoder.next() { decoded.append(frame) }

        #expect(decoded == frames)
    }

    @Test("An empty payload round trips without being confused for a short read")
    func emptyPayloadRoundTrips() throws {
        let original = Frame(kind: .pong, streamID: 0, payload: Data())

        var decoder = FrameDecoder()
        decoder.append(FrameEncoder.encode(original))

        #expect(try decoder.next() == original)
        #expect(try decoder.next() == nil)
    }

    @Test("An unrecognised frame kind is rejected rather than silently skipped")
    func unknownKindIsRejected() {
        var encoded = FrameEncoder.encode(Frame(kind: .data, streamID: 1, payload: Data()))
        encoded[0] = 0xFE

        var decoder = FrameDecoder()
        decoder.append(encoded)

        #expect(throws: FrameDecodingError.unknownKind(0xFE)) { try decoder.next() }
    }
}

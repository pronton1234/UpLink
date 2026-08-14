import Testing
import Foundation
@testable import UpLinkKit

// Permanent guards against defects. Each test names the symptom it prevents.
// These outlive refactors — see docs/REGRESSIONS.md. Do not delete one because
// "the code obviously handles that now"; that is precisely when it earns its
// keep.

@Suite("Regression: frame codec")
struct FrameCodecRegressionTests {

    // SYMPTOM: a peer (buggy, or hostile, on a shared network before pairing is
    // checked) sends a header claiming a 4 GiB payload. An unguarded decoder
    // reserves that much waiting for bytes that never arrive, and the extension
    // is OOM-killed by the system — taking the user's whole bridge down from a
    // single 9-byte frame.
    @Test("A payload length above the maximum is rejected, not allocated")
    func oversizedPayloadLengthIsRejected() {
        var hostile = Data()
        hostile.append(Frame.Kind.data.rawValue)
        hostile.append(bigEndian: UInt32(1))            // streamID
        hostile.append(bigEndian: UInt32.max)           // claimed payload: 4 GiB

        var decoder = FrameDecoder()
        decoder.append(hostile)

        #expect(throws: FrameDecodingError.payloadTooLarge(UInt32.max)) {
            try decoder.next()
        }
    }

    // SYMPTOM: malformed input causes an index-out-of-range trap rather than a
    // thrown error. A crash in the macOS system extension drops every proxied
    // flow at once, so the decoder must degrade by throwing, never by trapping.
    @Test("Arbitrary garbage never traps — it throws or asks for more bytes")
    func arbitraryGarbageNeverTraps() {
        // Seeded so any failure reproduces exactly rather than once a week.
        var rng = SeededGenerator(seed: 0x0BAD_F1AC_5EED_0001)

        for _ in 0 ..< 2_000 {
            let length = Int.random(in: 0 ... 64, using: &rng)
            let garbage = Data((0 ..< length).map { _ in UInt8.random(in: 0 ... 255, using: &rng) })

            var decoder = FrameDecoder()
            decoder.append(garbage)

            // The contract is only "does not trap". Throwing is a valid
            // outcome, so is nil, so is a frame that happens to parse.
            _ = try? decoder.next()
        }
    }

    // SYMPTOM: a frame whose payload length is valid but whose bytes have not
    // all arrived is treated as complete, handing a truncated payload to the
    // multiplexer and silently corrupting the proxied stream.
    @Test("A frame one byte short of complete is never yielded")
    func truncatedFrameIsNotYielded() throws {
        let complete = FrameEncoder.encode(
            Frame(kind: .data, streamID: 3, payload: Data(repeating: 0xAB, count: 512))
        )

        var decoder = FrameDecoder()
        decoder.append(complete.dropLast())

        #expect(try decoder.next() == nil)

        // …and it appears intact the moment the final byte lands.
        decoder.append(complete.suffix(1))
        #expect(try decoder.next()?.payload.count == 512)
    }
}

/// Deterministic PRNG so fuzz failures are reproducible.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

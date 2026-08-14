import Testing
import Foundation
@testable import UpLinkKit

@Suite("Regression: datagrams")
struct DatagramRegressionTests {

    private let session = StreamOpen(proto: .udp, host: "*", port: 0)

    private func openSession() throws -> (Multiplexer, UInt32) {
        var mux = Multiplexer(role: .initiator)
        let opened = try mux.openStream(to: session)
        return (mux, opened.streamID)
    }

    // SYMPTOM: UDP was sent through the TCP path, which chunks payloads at
    // maxPayloadSize and reassembles them as a byte stream. Datagram boundaries
    // vanished: two DNS replies arriving together were delivered as one blob,
    // and a large QUIC packet arrived as two. Both are corrupt packets that the
    // receiver has no way to detect, so the failure looks like random,
    // unreproducible network flakiness rather than a bug.
    @Test("Datagram boundaries survive byte-exact across many sizes")
    func boundariesSurviveExactly() throws {
        var rng = SeededGenerator(seed: 0x0DA7_A6BA_0000_0001)
        var mux = Multiplexer(role: .responder)
        _ = try mux.receive(Frame(kind: .open, streamID: 1, payload: session.encoded()))

        for _ in 0 ..< 300 {
            let size = Int.random(in: 0 ... 2_000, using: &rng)
            let payload = Data((0 ..< size).map { _ in UInt8.random(in: 0 ... 255, using: &rng) })
            let envelope = DatagramEnvelope(host: "1.1.1.1", port: 53, payload: payload)

            let events = try mux.receive(
                Frame(kind: .datagram, streamID: 1, payload: envelope.encoded())
            )

            guard case let .datagramReceived(_, decoded) = events.first else {
                Issue.record("expected a datagram event for a \(size)-byte payload")
                continue
            }
            #expect(decoded.payload == payload)

            // Keep the window open so this loop measures framing, not credit.
            _ = try? mux.consumedReceivedBytes(envelope.encoded().count, on: 1)
        }
    }

    @Test("One datagram is always exactly one frame, never two")
    func datagramIsNeverSplit() throws {
        var (mux, id) = try openSession()

        // Right at the edge of what fits, where a chunking bug would show.
        let host = "example.com"
        let payload = Data(repeating: 0xCD, count: DatagramEnvelope.maxPayloadSize(forHost: host))

        let result = try mux.sendDatagram(payload, to: host, port: 443, on: id)

        #expect(result.dropped == false)
        guard let frame = result.frame else {
            Issue.record("a maximum-size datagram must be sendable, not dropped")
            return
        }
        #expect(frame.payload.count <= Frame.maxPayloadSize)
        // And it must fit within a fresh stream's credit, or it is unsendable
        // in practice no matter what the frame layer allows.
        #expect(frame.payload.count <= Multiplexer.initialWindow)
    }

    // SYMPTOM: an oversized datagram was split across two frames. The peer
    // reassembled two separate, malformed packets and forwarded both. Dropping
    // is what a real network does and what the sender already tolerates.
    @Test("An oversized datagram is dropped rather than truncated or split")
    func oversizedIsDroppedNotMangled() throws {
        var (mux, id) = try openSession()
        let host = "example.com"
        let tooBig = Data(repeating: 0x01, count: DatagramEnvelope.maxPayloadSize(forHost: host) + 1)

        let result = try mux.sendDatagram(tooBig, to: host, port: 443, on: id)

        #expect(result.dropped)
        #expect(result.frame == nil)
    }

    // SYMPTOM: the destination was stored per stream, as TCP does. One
    // NEAppProxyUDPFlow carries datagrams to many hosts, so every packet on the
    // flow went to whichever destination happened to be recorded first — DNS
    // queries for one resolver arriving at another, QUIC packets crossing
    // between hosts.
    @Test("Each datagram carries its own destination, not the session's")
    func destinationIsPerDatagramNotPerSession() throws {
        var mux = Multiplexer(role: .responder)
        _ = try mux.receive(Frame(kind: .open, streamID: 1, payload: session.encoded()))

        let destinations = [
            ("1.1.1.1", UInt16(53)),
            ("8.8.8.8", UInt16(53)),
            ("dns.google", UInt16(443)),
            ("2606:4700:4700::1111", UInt16(53)),
        ]

        for (host, port) in destinations {
            let envelope = DatagramEnvelope(host: host, port: port, payload: Data([0x01]))
            let events = try mux.receive(
                Frame(kind: .datagram, streamID: 1, payload: envelope.encoded())
            )
            guard case let .datagramReceived(_, decoded) = events.first else {
                Issue.record("no datagram event for \(host)")
                continue
            }
            #expect(decoded.host == host)
            #expect(decoded.port == port)
            _ = try? mux.consumedReceivedBytes(envelope.encoded().count, on: 1)
        }
    }

    // SYMPTOM: a hostname in a datagram was resolved on the Mac before sending.
    // DNS is the single most revealing thing a bridge can leak, and UDP is
    // where DNS lives — resolving locally would have defeated the bridge for
    // exactly the traffic it most needs to cover.
    @Test("A hostname in a datagram is carried unresolved")
    func hostnameCarriedUnresolved() throws {
        let envelope = DatagramEnvelope(host: "private.internal.example", port: 53, payload: Data([1]))
        let decoded = try DatagramEnvelope(decoding: envelope.encoded())
        #expect(decoded.host == "private.internal.example")
    }

    // SYMPTOM: a peer sent a datagram frame whose envelope was garbage. Parsing
    // it leniently produced a datagram addressed to a nonsense host, which the
    // phone then tried to dial.
    @Test("A malformed datagram envelope is rejected, never guessed at")
    func malformedEnvelopeRejected() throws {
        var mux = Multiplexer(role: .responder)
        _ = try mux.receive(Frame(kind: .open, streamID: 1, payload: session.encoded()))

        #expect(throws: MuxError.malformedDatagram(1)) {
            try mux.receive(Frame(kind: .datagram, streamID: 1, payload: Data([0xFF, 0x00])))
        }
    }
}

import Testing
import Foundation
@testable import UpLinkKit

// UDP is not a byte stream, and the whole reason this type exists is that the
// TCP path cannot carry it. Two properties matter above all others: a datagram
// arrives byte-exact or not at all, and its destination travels WITH it —
// because one NEAppProxyUDPFlow fans out to many destinations, so a per-stream
// destination (which is what TCP uses) cannot express where a packet is going.

@Suite("Datagram envelope")
struct DatagramEnvelopeTests {

    @Test("An envelope round trips")
    func roundTrip() throws {
        let envelope = DatagramEnvelope(host: "1.1.1.1", port: 53, payload: Data("query".utf8))
        #expect(try DatagramEnvelope(decoding: envelope.encoded()) == envelope)
    }

    // A zero-length UDP datagram is legal and meaningful (keepalives, some
    // discovery protocols), so it must survive rather than be mistaken for a
    // short read.
    @Test("An empty payload round trips")
    func emptyPayloadRoundTrips() throws {
        let envelope = DatagramEnvelope(host: "example.com", port: 443, payload: Data())
        let decoded = try DatagramEnvelope(decoding: envelope.encoded())
        #expect(decoded.payload.isEmpty)
        #expect(decoded.port == 443)
    }

    @Test("A hostname round trips unresolved")
    func hostnameRoundTrips() throws {
        let envelope = DatagramEnvelope(host: "dns.google", port: 53, payload: Data([0x01]))
        #expect(try DatagramEnvelope(decoding: envelope.encoded()).host == "dns.google")
    }

    @Test("An IPv6 destination round trips")
    func ipv6RoundTrips() throws {
        let envelope = DatagramEnvelope(host: "2606:4700:4700::1111", port: 53, payload: Data([0x02]))
        #expect(try DatagramEnvelope(decoding: envelope.encoded()).host == "2606:4700:4700::1111")
    }

    @Test("A truncated envelope is rejected")
    func truncatedRejected() {
        let encoded = DatagramEnvelope(host: "1.1.1.1", port: 53, payload: Data("x".utf8)).encoded()
        #expect(throws: DatagramError.malformed) {
            _ = try DatagramEnvelope(decoding: encoded.dropLast(3))
        }
    }

    @Test("An empty envelope is rejected")
    func emptyRejected() {
        #expect(throws: DatagramError.malformed) { _ = try DatagramEnvelope(decoding: Data()) }
    }

    @Test("An empty host is rejected")
    func emptyHostRejected() {
        var encoded = Data()
        encoded.append(0)                    // host length 0
        encoded.append(contentsOf: [0, 53])  // port
        #expect(throws: DatagramError.malformed) { _ = try DatagramEnvelope(decoding: encoded) }
    }

    @Test("A host that is not valid UTF-8 is rejected rather than substituted")
    func invalidUTF8HostRejected() {
        var encoded = Data()
        encoded.append(2)
        encoded.append(contentsOf: [0xFF, 0xFE])
        encoded.append(contentsOf: [0x00, 0x35])
        #expect(throws: DatagramError.malformed) { _ = try DatagramEnvelope(decoding: encoded) }
    }

    // The budget is the real UDP maximum, not the frame maximum. Deriving it
    // from the frame cap produced a budget bigger than a stream's credit
    // window, so a maximum-size datagram could never actually be sent.
    @Test("The payload budget is the real UDP limit, not the frame limit")
    func payloadBudgetIsUDPLimit() {
        let budget = DatagramEnvelope.maxPayloadSize(forHost: "example.com")
        #expect(budget == DatagramEnvelope.maxDatagramSize)
        #expect(budget < Frame.maxPayloadSize)
    }

    // The binding constraint in practice: whatever the frame layer allows, a
    // datagram that does not fit in one stream's credit is unsendable.
    @Test("A maximum-size datagram fits within one stream's credit window")
    func maximumDatagramFitsCreditWindow() {
        let host = String(repeating: "a", count: 255)
        let budget = DatagramEnvelope.maxPayloadSize(forHost: host)
        let encoded = DatagramEnvelope(
            host: host, port: 53, payload: Data(repeating: 0, count: budget)
        ).encoded()
        #expect(encoded.count <= Multiplexer.initialWindow)
    }

    @Test("A payload exactly at the budget still encodes within one frame")
    func maximumPayloadFitsOneFrame() {
        let host = "1.1.1.1"
        let payload = Data(repeating: 0xAB, count: DatagramEnvelope.maxPayloadSize(forHost: host))
        let encoded = DatagramEnvelope(host: host, port: 53, payload: payload).encoded()
        #expect(encoded.count <= Frame.maxPayloadSize)
    }
}

@Suite("Multiplexer datagrams")
struct MultiplexerDatagramTests {

    private let session = StreamOpen(proto: .udp, host: "*", port: 0)

    private func openUDPSession() throws -> (Multiplexer, UInt32) {
        var mux = Multiplexer(role: .initiator)
        let opened = try mux.openStream(to: session)
        return (mux, opened.streamID)
    }

    @Test("A datagram is emitted as exactly one frame")
    func datagramIsOneFrame() throws {
        var (mux, id) = try openUDPSession()
        let result = try mux.sendDatagram(
            Data(repeating: 0x01, count: 1_200), to: "1.1.1.1", port: 53, on: id
        )
        #expect(result.frame != nil)
        #expect(result.frame?.kind == .datagram)
    }

    @Test("Sending a datagram consumes credit for its whole encoded size")
    func datagramConsumesCredit() throws {
        var (mux, id) = try openUDPSession()
        let before = try mux.sendCredit(for: id)
        _ = try mux.sendDatagram(Data(repeating: 0x01, count: 500), to: "1.1.1.1", port: 53, on: id)
        #expect(try mux.sendCredit(for: id) < before)
    }

    // Dropping is correct UDP semantics. Splitting would deliver two corrupt
    // packets that the receiver has no way to recognise as broken.
    @Test("An oversized datagram is dropped, never split")
    func oversizedDatagramIsDropped() throws {
        var (mux, id) = try openUDPSession()
        let huge = Data(repeating: 0x01, count: Frame.maxPayloadSize + 1)

        let result = try mux.sendDatagram(huge, to: "1.1.1.1", port: 53, on: id)

        #expect(result.frame == nil)
        #expect(result.dropped)
    }

    @Test("A datagram with no credit left is dropped rather than queued")
    func datagramWithoutCreditIsDropped() throws {
        var (mux, id) = try openUDPSession()
        // Exhaust the window.
        _ = try mux.send(Data(repeating: 0, count: Multiplexer.initialWindow), on: id)

        let result = try mux.sendDatagram(Data([0x01]), to: "1.1.1.1", port: 53, on: id)
        #expect(result.frame == nil)
        #expect(result.dropped)
    }

    @Test("An inbound datagram surfaces with its destination intact")
    func inboundDatagramSurfaces() throws {
        var mux = Multiplexer(role: .responder)
        _ = try mux.receive(Frame(kind: .open, streamID: 1, payload: session.encoded()))

        let envelope = DatagramEnvelope(host: "8.8.8.8", port: 53, payload: Data("q".utf8))
        let events = try mux.receive(
            Frame(kind: .datagram, streamID: 1, payload: envelope.encoded())
        )

        #expect(events == [.datagramReceived(streamID: 1, envelope)])
    }

    // The fan-out case: one UDP session, many destinations. If the destination
    // did not travel with each datagram this would be impossible to express.
    @Test("Datagrams to different destinations on one session stay addressed")
    func fanOutKeepsDestinations() throws {
        var mux = Multiplexer(role: .responder)
        _ = try mux.receive(Frame(kind: .open, streamID: 1, payload: session.encoded()))

        let first = DatagramEnvelope(host: "1.1.1.1", port: 53, payload: Data([0xAA]))
        let second = DatagramEnvelope(host: "8.8.8.8", port: 443, payload: Data([0xBB]))

        let a = try mux.receive(Frame(kind: .datagram, streamID: 1, payload: first.encoded()))
        let b = try mux.receive(Frame(kind: .datagram, streamID: 1, payload: second.encoded()))

        #expect(a == [.datagramReceived(streamID: 1, first)])
        #expect(b == [.datagramReceived(streamID: 1, second)])
    }

    @Test("A malformed inbound datagram is a protocol error, not a silent drop")
    func malformedInboundDatagramThrows() throws {
        var mux = Multiplexer(role: .responder)
        _ = try mux.receive(Frame(kind: .open, streamID: 1, payload: session.encoded()))

        #expect(throws: MuxError.self) {
            try mux.receive(Frame(kind: .datagram, streamID: 1, payload: Data([0xFF])))
        }
    }

    @Test("An inbound datagram beyond the window is a flow-control violation")
    func inboundDatagramOverrunIsViolation() throws {
        var mux = Multiplexer(role: .responder)
        _ = try mux.receive(Frame(kind: .open, streamID: 1, payload: session.encoded()))

        var sent = 0
        while sent < Multiplexer.initialWindow {
            let chunk = min(Frame.maxPayloadSize, Multiplexer.initialWindow - sent)
            _ = try mux.receive(Frame(kind: .data, streamID: 1, payload: Data(repeating: 0, count: chunk)))
            sent += chunk
        }

        let envelope = DatagramEnvelope(host: "1.1.1.1", port: 53, payload: Data([0x01]))
        #expect(throws: MuxError.flowControlViolation(1)) {
            try mux.receive(Frame(kind: .datagram, streamID: 1, payload: envelope.encoded()))
        }
    }
}

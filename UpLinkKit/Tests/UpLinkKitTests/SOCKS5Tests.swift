import Testing
import Foundation
@testable import UpLinkKit

// SOCKS5 (RFC 1928) is the Mac's front door now: browsers and CLI tools speak
// it to the app, and the app turns each CONNECT into a multiplexed stream to
// the phone. Every byte here comes from another process on the machine, so the
// parser has to be total.

@Suite("SOCKS5 handshake")
struct SOCKS5Tests {

    private func greeting(methods: [UInt8]) -> Data {
        Data([0x05, UInt8(methods.count)] + methods)
    }

    // MARK: Greeting

    @Test("A no-auth greeting is accepted")
    func noAuthGreetingAccepted() throws {
        var handshake = SOCKS5Handshake()
        let reply = try handshake.consume(greeting(methods: [0x00]))

        #expect(reply == Data([0x05, 0x00]))
        #expect(handshake.state == .awaitingRequest)
    }

    @Test("A greeting offering several methods still selects no-auth")
    func multipleMethodsSelectsNoAuth() throws {
        var handshake = SOCKS5Handshake()
        let reply = try handshake.consume(greeting(methods: [0x02, 0x01, 0x00]))
        #expect(reply == Data([0x05, 0x00]))
    }

    // The proxy binds to loopback only, so anything reaching it is already a
    // local process. Demanding credentials would just break every client for
    // no security gain — but a client that refuses no-auth must be told, not
    // left hanging.
    @Test("A greeting with no acceptable method is refused explicitly")
    func noAcceptableMethodIsRefused() throws {
        var handshake = SOCKS5Handshake()
        let reply = try handshake.consume(greeting(methods: [0x02]))
        #expect(reply == Data([0x05, 0xFF]))
        #expect(handshake.state == .failed)
    }

    @Test("A non-SOCKS5 version byte is rejected")
    func wrongVersionRejected() {
        var handshake = SOCKS5Handshake()
        #expect(throws: SOCKS5Error.unsupportedVersion(0x04)) {
            try handshake.consume(Data([0x04, 0x01, 0x00]))
        }
    }

    @Test("A greeting split across reads is reassembled")
    func splitGreetingReassembled() throws {
        var handshake = SOCKS5Handshake()
        #expect(try handshake.consume(Data([0x05])) == nil)
        #expect(try handshake.consume(Data([0x01])) == nil)
        #expect(try handshake.consume(Data([0x00])) == Data([0x05, 0x00]))
    }

    // MARK: CONNECT request

    private func connectRequest(atyp: UInt8, address: [UInt8], port: UInt16) -> Data {
        Data([0x05, 0x01, 0x00, atyp] + address + [UInt8(port >> 8), UInt8(port & 0xFF)])
    }

    @Test("A domain-name CONNECT yields the hostname and port")
    func domainConnectParsed() throws {
        var handshake = SOCKS5Handshake()
        _ = try handshake.consume(greeting(methods: [0x00]))

        let host = Array("example.com".utf8)
        _ = try handshake.consume(
            connectRequest(atyp: 0x03, address: [UInt8(host.count)] + host, port: 443)
        )

        #expect(handshake.destination == StreamOpen(proto: .tcp, host: "example.com", port: 443))
    }

    @Test("An IPv4 CONNECT yields a dotted-quad host")
    func ipv4ConnectParsed() throws {
        var handshake = SOCKS5Handshake()
        _ = try handshake.consume(greeting(methods: [0x00]))
        _ = try handshake.consume(connectRequest(atyp: 0x01, address: [93, 184, 216, 34], port: 80))

        #expect(handshake.destination?.host == "93.184.216.34")
        #expect(handshake.destination?.port == 80)
    }

    @Test("An IPv6 CONNECT yields a colon-form host")
    func ipv6ConnectParsed() throws {
        var handshake = SOCKS5Handshake()
        _ = try handshake.consume(greeting(methods: [0x00]))

        var address = [UInt8](repeating: 0, count: 16)
        address[0] = 0x20; address[1] = 0x01; address[15] = 0x01
        _ = try handshake.consume(connectRequest(atyp: 0x04, address: address, port: 443))

        #expect(handshake.destination?.host.contains(":") == true)
    }

    // Browsers pass hostnames through rather than resolving them, which is what
    // keeps DNS on the phone. If this ever started resolving locally, every
    // site the user visits would leak to the Mac's network.
    @Test("A hostname is passed through unresolved")
    func hostnameIsNotResolvedLocally() throws {
        var handshake = SOCKS5Handshake()
        _ = try handshake.consume(greeting(methods: [0x00]))
        let host = Array("private.internal.example".utf8)
        _ = try handshake.consume(
            connectRequest(atyp: 0x03, address: [UInt8(host.count)] + host, port: 8443)
        )
        #expect(handshake.destination?.host == "private.internal.example")
    }

    @Test("A request split across reads is reassembled")
    func splitRequestReassembled() throws {
        var handshake = SOCKS5Handshake()
        _ = try handshake.consume(greeting(methods: [0x00]))

        let host = Array("example.com".utf8)
        let request = connectRequest(atyp: 0x03, address: [UInt8(host.count)] + host, port: 443)

        for byte in request.dropLast() {
            #expect(try handshake.consume(Data([byte])) == nil)
        }
        _ = try handshake.consume(request.suffix(1))
        #expect(handshake.destination?.host == "example.com")
    }

    @Test("A command other than CONNECT is refused")
    func bindAndAssociateRefused() throws {
        var handshake = SOCKS5Handshake()
        _ = try handshake.consume(greeting(methods: [0x00]))

        // 0x02 = BIND
        #expect(throws: SOCKS5Error.unsupportedCommand(0x02)) {
            try handshake.consume(Data([0x05, 0x02, 0x00, 0x01, 1, 2, 3, 4, 0x00, 0x50]))
        }
    }

    @Test("An unknown address type is rejected")
    func unknownAddressTypeRejected() throws {
        var handshake = SOCKS5Handshake()
        _ = try handshake.consume(greeting(methods: [0x00]))

        #expect(throws: SOCKS5Error.unsupportedAddressType(0x09)) {
            try handshake.consume(Data([0x05, 0x01, 0x00, 0x09, 0x00, 0x50]))
        }
    }

    @Test("A zero-length domain is rejected rather than dialled")
    func emptyDomainRejected() throws {
        var handshake = SOCKS5Handshake()
        _ = try handshake.consume(greeting(methods: [0x00]))

        #expect(throws: SOCKS5Error.malformedRequest) {
            try handshake.consume(Data([0x05, 0x01, 0x00, 0x03, 0x00, 0x00, 0x50]))
        }
    }

    @Test("A domain that is not valid UTF-8 is rejected, not substituted")
    func invalidUTF8DomainRejected() throws {
        var handshake = SOCKS5Handshake()
        _ = try handshake.consume(greeting(methods: [0x00]))

        #expect(throws: SOCKS5Error.malformedRequest) {
            try handshake.consume(Data([0x05, 0x01, 0x00, 0x03, 0x02, 0xFF, 0xFE, 0x00, 0x50]))
        }
    }

    // MARK: Replies

    @Test("A success reply is well formed")
    func successReplyShape() {
        let reply = SOCKS5Handshake.reply(.succeeded)
        #expect(reply.count == 10)
        #expect(reply[0] == 0x05)
        #expect(reply[1] == 0x00)
        #expect(reply[3] == 0x01)  // IPv4 bind address
    }

    @Test("A failure reply carries the right code", arguments: [
        (SOCKS5Reply.hostUnreachable, UInt8(0x04)),
        (SOCKS5Reply.connectionRefused, UInt8(0x05)),
        (SOCKS5Reply.generalFailure, UInt8(0x01)),
    ])
    func failureReplyCodes(_ reply: SOCKS5Reply, _ code: UInt8) {
        #expect(SOCKS5Handshake.reply(reply)[1] == code)
    }
}

import Testing
import Foundation
import Network
import CryptoKit
@testable import UpLinkKit

// SYMPTOM: pairing failed on every attempt from a real iPhone, for days. The
// Mac logged an inbound connection and then a generic -9816 rejection, which
// reads like a wrong pairing code and is not. Nothing failed off-device,
// because nothing off-device ever opened a real TLS connection.
//
// CAUSE: `sec_protocol_options_add_pre_shared_key` does not work under TLS 1.3
// in Network.framework. The transport asked for a TLS 1.3 floor, so the PSK was
// never offered and the handshake failed with -9858. Worse, the failure arrives
// as `.waiting`, not `.failed`, and the channel only resumed on `.ready`,
// `.failed` or `.cancelled` — so the connection did not fail, it hung forever.
//
// Two defects, both permanent-test-worthy: the wrong TLS configuration, and a
// state machine that could wait on a dead connection with no timeout.

@Suite("Regression: TLS-PSK handshake")
struct TLSHandshakeRegressionTests {

    private func port(of listener: NWListener) async -> NWEndpoint.Port? {
        for _ in 0 ..< 100 {
            if let port = listener.port, port.rawValue != 0 { return port }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    /// The one that matters: the product's own parameters must produce a
    /// connection that actually completes. Anything that reintroduces a TLS 1.3
    /// floor fails here in milliseconds instead of on a phone in a day.
    @Test("A PSK connection built from the product's parameters reaches ready")
    func productParametersNegotiate() async throws {
        let psk = SymmetricKey(size: .bits256)
        let identity = "regression"
        let queue = DispatchQueue(label: "regression.tls")

        let listener = try NWListener(
            using: TransportParameters.listener(
                sessionKeys: [(identity, psk)],
                pairingKey: nil,
                profile: .localLink
            )
        )
        let held = Held<NWConnection?>(nil)
        listener.newConnectionHandler = { connection in
            held.value = connection
            connection.start(queue: queue)
        }
        listener.start(queue: queue)
        defer { listener.cancel() }

        let bound = try #require(await port(of: listener))

        let connection = NWConnection(
            host: "127.0.0.1",
            port: bound,
            using: TransportParameters.session(psk: psk, identity: identity, profile: .localLink)
        )
        defer { connection.cancel() }

        let channel = NWConnectionChannel(connection: connection)
        // Throws on failure; the assertion is that this returns at all.
        try await channel.start(on: queue)
        await channel.close()
    }

    /// The PSK is only offered if a compatible ciphersuite is named. This
    /// asserts the transport still refuses to pin TLS 1.3, which is the exact
    /// setting that broke it.
    @Test("A TLS 1.3 floor makes the same PSK handshake fail")
    func tls13FloorStillBroken() async throws {
        // Documents the platform behaviour this design works around. If Apple
        // ever fixes external PSKs under TLS 1.3 this test starts failing —
        // which is the signal to revisit the ciphersuite choice, not to delete
        // the test.
        let psk = SymmetricKey(size: .bits256)
        let queue = DispatchQueue(label: "regression.tls13")

        func brokenOptions() -> NWParameters {
            let tls = NWProtocolTLS.Options()
            let keyData = psk.withUnsafeBytes { DispatchData(bytes: $0) }
            let identityData = Data("regression".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(
                tls.securityProtocolOptions,
                keyData as __DispatchData,
                identityData as __DispatchData
            )
            sec_protocol_options_set_min_tls_protocol_version(
                tls.securityProtocolOptions, .TLSv13
            )
            let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
            parameters.allowLocalEndpointReuse = true
            return parameters
        }

        let listener = try NWListener(using: brokenOptions())
        let held = Held<NWConnection?>(nil)
        listener.newConnectionHandler = { connection in
            held.value = connection
            connection.start(queue: queue)
        }
        listener.start(queue: queue)
        defer { listener.cancel() }

        let bound = try #require(await port(of: listener))
        let connection = NWConnection(host: "127.0.0.1", port: bound, using: brokenOptions())
        defer { connection.cancel() }

        let channel = NWConnectionChannel(connection: connection)
        await #expect(throws: (any Error).self) {
            try await channel.start(on: queue)
        }
    }

    /// The second defect, on its own: a peer that never completes must produce
    /// an error, not an indefinite wait. Without this the UI shows "Connecting…"
    /// forever and the logs say nothing at all.
    @Test("A rejected handshake fails promptly instead of hanging")
    func rejectedHandshakeFailsFast() async throws {
        let queue = DispatchQueue(label: "regression.reject")

        // Two different keys: the listener will reject this client.
        let listener = try NWListener(
            using: TransportParameters.listener(
                sessionKeys: [("regression", SymmetricKey(size: .bits256))],
                pairingKey: nil,
                profile: .localLink
            )
        )
        let held = Held<NWConnection?>(nil)
        listener.newConnectionHandler = { connection in
            held.value = connection
            connection.start(queue: queue)
        }
        listener.start(queue: queue)
        defer { listener.cancel() }

        let bound = try #require(await port(of: listener))
        let connection = NWConnection(
            host: "127.0.0.1",
            port: bound,
            using: TransportParameters.session(
                psk: SymmetricKey(size: .bits256),
                identity: "regression",
                profile: .localLink
            )
        )
        defer { connection.cancel() }

        let started = Date()
        let channel = NWConnectionChannel(connection: connection)
        await #expect(throws: (any Error).self) {
            try await channel.start(on: queue)
        }
        // Well inside the connect timeout: the point is that it does not sit
        // there until the timeout, let alone forever.
        #expect(Date().timeIntervalSince(started) < NWConnectionChannel.connectTimeout)
    }

    /// Even a connection that no one answers must give up eventually.
    @Test("The connect timeout is bounded and short enough to surface in a UI")
    func connectTimeoutIsBounded() {
        #expect(NWConnectionChannel.connectTimeout > 0)
        #expect(NWConnectionChannel.connectTimeout <= 30)
    }
}

/// Minimal mutable holder so an inbound connection is not deallocated
/// mid-handshake.
private final class Held<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

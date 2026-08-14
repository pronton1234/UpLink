import Testing
import Foundation
import Network
import CryptoKit
@testable import UpLinkKit

// The gap these tests fill: every other pairing test checks key-schedule maths
// or the attempt state machine, and all of them passed while pairing failed on
// a real phone every single time. Nothing exercised the part in between — a
// real NWListener, a real TLS 1.3 PSK handshake, and the pairRequest /
// pairResponse frame exchange over an actual socket.
//
// These run against 127.0.0.1 in about a second, so the handshake is now
// covered by the fast loop rather than by rebuilding an app onto a phone.

/// Fails the test instead of hanging it.
///
/// A stalled TLS handshake produces no error and no timeout of its own, so
/// without this the suite blocks forever and reports nothing — which is exactly
/// how this bug hid.
func withTimeout<T: Sendable>(
    _ seconds: Double = 10,
    _ label: String,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw ChannelError.handshakeFailed("timed out after \(seconds)s: \(label)")
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

@Suite("Loopback pairing over a real TLS-PSK socket")
struct LoopbackPairingTests {

    /// Spins up a real `MacSessionHost` and returns it with a peer that points
    /// straight at its port, skipping Bonjour.
    private func makeHost(
        deviceName: String = "Test Mac"
    ) async throws -> (host: MacSessionHost, identity: Curve25519.KeyAgreement.PrivateKey, store: InMemoryDeviceDirectory) {
        let identity = Curve25519.KeyAgreement.PrivateKey()
        let store = InMemoryDeviceDirectory()
        let host = MacSessionHost(
            identity: identity,
            deviceName: deviceName,
            store: store,
            queue: DispatchQueue(label: "test.host"),
            // Loopback, not AWDL: the peer-to-peer profile needs two devices.
            profile: .localLink
        )
        try await host.start()
        return (host, identity, store)
    }

    private func peer(for host: MacSessionHost, name: String = "Test Mac") async throws -> DiscoveredPeer {
        // NWListener binds asynchronously, so the port is nil for a beat after
        // start(). Dialing port 0 would stall in .waiting forever rather than
        // fail, so wait for a real one.
        var port: NWEndpoint.Port?
        for _ in 0 ..< 100 {
            port = await host.listeningPort
            if let port, port.rawValue != 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let port, port.rawValue != 0 else {
            throw ChannelError.handshakeFailed("listener never bound a port")
        }
        return DiscoveredPeer(
            id: name,
            name: name,
            endpoint: .hostPort(host: "127.0.0.1", port: port),
            fingerprint: await host.fingerprint,
            profile: .localLink
        )
    }

    /// Waits for the host to record the pairing.
    ///
    /// The Mac sends its half of the exchange *before* it writes to the store,
    /// so a client that returns the instant it reads the reply can legitimately
    /// observe an empty store. Polling makes the assertion about the outcome
    /// rather than about which side won a microsecond race.
    private func awaitSavedDevices(
        in store: InMemoryDeviceDirectory,
        count: Int,
        within seconds: Double = 2
    ) async throws -> [PairedDevice] {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let saved = (try? store.pairedDevices()) ?? []
            if saved.count >= count { return saved }
            try await Task.sleep(for: .milliseconds(20))
        }
        return (try? store.pairedDevices()) ?? []
    }

    // The whole point. If this fails, pairing cannot work on a phone either.
    @Test("A correct code completes the handshake and both sides learn each other")
    func correctCodePairs() async throws {
        let (host, hostIdentity, store) = try await makeHost()
        defer { Task { await host.stop() } }

        let code = PairingCode.random()
        try await host.setPairingCode(code)

        let phoneIdentity = Curve25519.KeyAgreement.PrivateKey()
        let target = try await peer(for: host)
        let device = try await withTimeout(10, "correct-code pairing") {
            try await PairingClient(
                queue: DispatchQueue(label: "test.client"),
                deviceName: "Test iPhone"
            ).pair(with: target, code: code, localIdentity: phoneIdentity)
        }

        // The phone learned the Mac.
        #expect(device.publicKey == hostIdentity.publicKey.rawRepresentation)
        #expect(device.name == "Test Mac")

        // The Mac learned the phone.
        let saved = try await awaitSavedDevices(in: store, count: 1)
        #expect(saved.count == 1)
        #expect(saved.first?.name == "Test iPhone")
        #expect(saved.first?.publicKey == phoneIdentity.publicKey.rawRepresentation)
    }

    @Test("A wrong code fails and pairs nothing")
    func wrongCodeFails() async throws {
        let (host, _, store) = try await makeHost()
        defer { Task { await host.stop() } }

        try await host.setPairingCode(try PairingCode(digits: "123456"))

        let target = try await peer(for: host)
        await #expect(throws: (any Error).self) {
            try await withTimeout(10, "wrong-code pairing") {
                try await PairingClient(queue: DispatchQueue(label: "test.client"))
                    .pair(
                        with: target,
                        code: try PairingCode(digits: "654321"),
                        localIdentity: Curve25519.KeyAgreement.PrivateKey()
                    )
            }
        }
        #expect((try store.pairedDevices()).isEmpty)
    }

    // The Mac must not be pairable when the user has not asked it to be.
    @Test("With no code on screen, pairing is refused")
    func noCodeRefuses() async throws {
        let (host, _, store) = try await makeHost()
        defer { Task { await host.stop() } }

        let target = try await peer(for: host)
        await #expect(throws: (any Error).self) {
            try await withTimeout(10, "no-code pairing") {
                try await PairingClient(queue: DispatchQueue(label: "test.client"))
                    .pair(
                        with: target,
                        code: PairingCode.random(),
                        localIdentity: Curve25519.KeyAgreement.PrivateKey()
                    )
            }
        }
        #expect((try store.pairedDevices()).isEmpty)
    }

    // A display name with a typographic apostrophe is the default on a Mac
    // ("Pranit's MacBook Air"), and it used to feed the salt. It must now be
    // irrelevant to the handshake.
    @Test("A name with a typographic apostrophe still pairs")
    func awkwardNamePairs() async throws {
        let name = "Pranit\u{2019}s MacBook Air"
        let (host, _, store) = try await makeHost(deviceName: name)
        defer { Task { await host.stop() } }

        let code = PairingCode.random()
        try await host.setPairingCode(code)

        let target = try await peer(for: host, name: name)
        let device = try await withTimeout(10, "apostrophe-name pairing") {
            try await PairingClient(
                queue: DispatchQueue(label: "test.client"),
                deviceName: "Test iPhone"
            ).pair(with: target, code: code, localIdentity: .init())
        }

        #expect(device.name == name)
        #expect((try await awaitSavedDevices(in: store, count: 1)).count == 1)
    }

    // Pairing consumes the code and rebuilds the listener with the new phone's
    // session PSK. A second attempt on the same code must not succeed.
    @Test("A code cannot be used twice")
    func codeIsSingleUse() async throws {
        let (host, _, _) = try await makeHost()
        defer { Task { await host.stop() } }

        let code = PairingCode.random()
        try await host.setPairingCode(code)

        let target = try await peer(for: host)
        _ = try await withTimeout(10, "first use of code") {
            try await PairingClient(queue: DispatchQueue(label: "test.client"))
                .pair(with: target, code: code, localIdentity: .init())
        }

        let second = try await peer(for: host)
        await #expect(throws: (any Error).self) {
            try await withTimeout(10, "replay of code") {
                try await PairingClient(queue: DispatchQueue(label: "test.client2"))
                    .pair(with: second, code: code, localIdentity: .init())
            }
        }
    }
}

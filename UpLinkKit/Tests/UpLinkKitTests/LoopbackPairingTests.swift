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

/// Pairing never dials a destination, so this exists only to satisfy the
/// responder's dependency. Anything reaching it is a bug in the test.
actor NeverDialer: DestinationDialer {
    func connect(to destination: StreamOpen) async throws -> DestinationConnection {
        throw ChannelError.notConnected
    }
}

@Suite("Loopback pairing over a real TLS-PSK socket")
struct LoopbackPairingTests {

    /// Spins up a real `PhoneSessionHost` — the phone, which is the LISTENER
    /// now that `usbmuxd` dictates the Mac must be the one that dials.
    ///
    /// Its `store` holds paired **Macs**, which is the mirror image of what it
    /// held when the Mac was the host. The port is randomised per test so these
    /// can run in parallel against a fixed-port design.
    fileprivate func makeHost(
        deviceName: String = "Test iPhone"
    ) async throws -> (host: PhoneSessionHost, identity: Curve25519.KeyAgreement.PrivateKey, store: InMemoryDeviceDirectory) {
        let identity = Curve25519.KeyAgreement.PrivateKey()
        let store = InMemoryDeviceDirectory()
        let host = PhoneSessionHost(
            identity: identity,
            deviceName: deviceName,
            store: store,
            dialer: NeverDialer(),
            queue: DispatchQueue(label: "test.host"),
            port: UInt16.random(in: 41000 ..< 48000)
        )
        try await host.start()
        return (host, identity, store)
    }

    /// The port the phone actually bound.
    ///
    /// `NWListener` binds asynchronously, so it is nil for a beat after
    /// `start()`. Dialing port 0 would stall in `.waiting` forever rather than
    /// fail, so wait for a real one.
    fileprivate func port(of host: PhoneSessionHost) async throws -> UInt16 {
        for _ in 0 ..< 100 {
            if let bound = await host.listeningPort, bound.rawValue != 0 {
                return bound.rawValue
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ChannelError.handshakeFailed("listener never bound a port")
    }

    /// Dials the phone as the Mac would and runs the pairing exchange.
    ///
    /// In production the loopback port belongs to the menu-bar app's relay,
    /// which pumps it down the cable. Here the phone's listener is on loopback
    /// directly, so everything from TLS-PSK upward is byte-for-byte the
    /// production path — only the cable in the middle is absent.
    @discardableResult
    fileprivate func dialAndPair(
        port: UInt16,
        code: PairingCode,
        macIdentity: Curve25519.KeyAgreement.PrivateKey = .init(),
        deviceName: String = "Test Mac",
        udid: String = "TEST-UDID",
        store: InMemoryDeviceDirectory = InMemoryDeviceDirectory(),
        label: String = "test.client"
    ) async throws -> PairedDevice {
        try await MacSessionClient(
            identity: macIdentity,
            deviceName: deviceName,
            store: store,
            queue: DispatchQueue(label: label)
        ).pair(relayPort: port, code: code, udid: udid)
    }

    /// Waits for the host to record the pairing.
    ///
    /// The listener sends its half of the exchange *before* it writes to the
    /// store, so a dialer that returns the instant it reads the reply can
    /// legitimately observe an empty store. Polling makes the assertion about
    /// the outcome rather than about which side won a microsecond race.
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

        let macIdentity = Curve25519.KeyAgreement.PrivateKey()
        let target = try await port(of: host)
        let device = try await withTimeout(10, "correct-code pairing") {
            try await dialAndPair(port: target, code: code, macIdentity: macIdentity, deviceName: "Test Mac", label: "test.client")
        }

        // The Mac learned the phone it dialled.
        #expect(device.publicKey == hostIdentity.publicKey.rawRepresentation)
        #expect(device.name == "Test iPhone")
        // And pinned it to the physical device usbmuxd reported.
        #expect(device.udid == "TEST-UDID")

        // The phone learned the Mac.
        let saved = try await awaitSavedDevices(in: store, count: 1)
        #expect(saved.count == 1)
        #expect(saved.first?.name == "Test Mac")
        #expect(saved.first?.publicKey == macIdentity.publicKey.rawRepresentation)
        // The phone never sees a UDID — iOS does not let an app read its own.
        #expect(saved.first?.udid == nil)
    }

    @Test("A wrong code fails and pairs nothing")
    func wrongCodeFails() async throws {
        let (host, _, store) = try await makeHost()
        defer { Task { await host.stop() } }

        try await host.setPairingCode(try PairingCode(digits: "123456"))

        let target = try await port(of: host)
        await #expect(throws: (any Error).self) {
            try await withTimeout(10, "wrong-code pairing") {
                try await dialAndPair(port: target, code: try PairingCode(digits: "654321"), macIdentity: Curve25519.KeyAgreement.PrivateKey(), label: "test.client")
            }
        }
        #expect((try store.pairedDevices()).isEmpty)
    }

    // The Mac must not be pairable when the user has not asked it to be.
    @Test("With no code on screen, pairing is refused")
    func noCodeRefuses() async throws {
        let (host, _, store) = try await makeHost()
        defer { Task { await host.stop() } }

        let target = try await port(of: host)
        await #expect(throws: (any Error).self) {
            try await withTimeout(10, "no-code pairing") {
                try await dialAndPair(port: target, code: PairingCode.random(), macIdentity: Curve25519.KeyAgreement.PrivateKey(), label: "test.client")
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

        let target = try await port(of: host)
        let device = try await withTimeout(10, "apostrophe-name pairing") {
            try await dialAndPair(port: target, code: code, macIdentity: .init(), deviceName: "Test iPhone", label: "test.client")
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

        let target = try await port(of: host)
        _ = try await withTimeout(10, "first use of code") {
            try await dialAndPair(port: target, code: code, macIdentity: .init(), label: "test.client")
        }

        let second = try await port(of: host)
        await #expect(throws: (any Error).self) {
            try await withTimeout(10, "replay of code") {
                try await dialAndPair(port: second, code: code, macIdentity: .init(), label: "test.client2")
            }
        }
    }
}

// SYMPTOM: "re-pairing is such a pain for some reason" — you type a code, the
// spinner stops, and nothing else happens.
//
// Two separate reasons a pairing failure was mute, and they need different
// fixes because they fail at different layers:
//
//   1. A WRONG CODE fails inside the TLS-PSK handshake, before any frame can be
//      exchanged. The phone gets an opaque `NWError` from `channel.start`, and
//      `pairingMessage(for:)`'s `.codeMismatch` arm — which says exactly the
//      right thing — is never reached, because that error is never thrown.
//
//   2. A code that is RIGHT but expired, exhausted, or already used gets past
//      TLS, because the PSK is still on the air. The Mac's `PairingSession`
//      then refuses it — and `accept()` catches the throw and merely closes the
//      channel. The Mac never sends a failure, so the phone's `receive()`
//      returns nil and it reports the generic `handshakeFailed`.
//
// So `.expired`, `.tooManyAttempts` and `.alreadyConsumed` were unreachable on
// the phone: the values existed, the human-readable strings existed, and no
// path could ever produce them.

@Suite("Regression: a failed pairing must say which failure it was")
struct PairingFailureReportingTests {

    @Test("A wrong code reports a code mismatch, not an opaque transport error")
    func wrongCodeIsReportedAsMismatch() async throws {
        let harness = LoopbackPairingTests()
        let (host, _, _) = try await harness.makeHost()
        defer { Task { await host.stop() } }

        try await host.setPairingCode(try PairingCode(digits: "123456"))
        let target = try await harness.port(of: host)

        await #expect(throws: PairingError.codeMismatch) {
            try await withTimeout(10, "wrong-code pairing") {
                try await harness.dialAndPair(port: target, code: try PairingCode(digits: "654321"), macIdentity: Curve25519.KeyAgreement.PrivateKey(), label: "test.client")
            }
        }
    }

    // The post-TLS refusal, and the one that actually happens in the field.
    //
    // The pairing PSK stays in the listener until someone calls
    // `setPairingCode(nil)`, and the only thing that does so on a timer is an
    // app-side `Task.sleep`. If the app quits or that IPC is lost, the code is
    // still ON THE AIR while its `PairingSession` has expired. TLS then
    // succeeds and the Mac refuses afterwards — the one case where the Mac is
    // the only side that knows why, and so the only case a failure frame can
    // possibly help.
    @Test("An expired session reports expiry, not a generic handshake failure")
    func expiredSessionIsReportedSpecifically() async throws {
        let harness = LoopbackPairingTests()
        let (host, _, store) = try await harness.makeHost()
        defer { Task { await host.stop() } }

        // Issued two minutes ago: past `PairingSession.validity` (60s), but the
        // PSK is on the air, so the handshake still succeeds.
        let code = try PairingCode(digits: "424242")
        try await host.setPairingCode(code, now: Date().addingTimeInterval(-120))
        let target = try await harness.port(of: host)

        await #expect(throws: PairingError.expired) {
            try await withTimeout(10, "expired pairing") {
                try await harness.dialAndPair(port: target, code: code, macIdentity: Curve25519.KeyAgreement.PrivateKey(), label: "test.client.exp")
            }
        }
        #expect((try store.pairedDevices()).isEmpty, "an expired code paired anyway")
    }
}

/// A directory whose `save` always fails, standing in for the real ways the
/// step after verification can go wrong: a keychain write refused before first
/// unlock, a channel that dies mid-response.
private final class FailingDeviceDirectory: DeviceDirectory, @unchecked Sendable {
    struct Refused: Error {}
    func pairedDevices() throws -> [PairedDevice] { [] }
    func save(_ device: PairedDevice) throws { throw Refused() }
    func remove(fingerprint: String) throws {}
}

@Suite("Regression: a failure after verification must not burn the code")
struct PairingCodeConsumptionTests {

    // `verify` marks the code consumed and `handlePairing` persisted that
    // immediately, BEFORE writing the response and saving the device. So any
    // failure after that point cost a whole new code — while the phone may
    // already have saved the Mac, leaving a one-sided pairing that then has to
    // be cleaned up by hand. Exactly the "re-pairing is a pain" shape.
    @Test("A code survives a failure that happens after it was verified")
    func codeSurvivesLateFailure() async throws {
        let store = FailingDeviceDirectory()
        let host = PhoneSessionHost(
            identity: Curve25519.KeyAgreement.PrivateKey(),
            deviceName: "Test iPhone",
            store: store,
            dialer: NeverDialer(),
            queue: DispatchQueue(label: "test.consumption"),
            port: UInt16.random(in: 41000 ..< 48000)
        )
        try await host.start()
        defer { Task { await host.stop() } }

        let code = try PairingCode(digits: "515151")
        try await host.setPairingCode(code)

        let harness = LoopbackPairingTests()
        // The Mac must not confirm a pairing it could not record: the phone
        // fails too, rather than storing a Mac that has no record of it.
        let first = try await harness.port(of: host)
        await #expect(throws: (any Error).self) {
            try await withTimeout(10, "first attempt") {
                try await harness.dialAndPair(port: first, code: code, macIdentity: Curve25519.KeyAgreement.PrivateKey(), label: "test.c1")
            }
        }

        // The same code again. If the first attempt burned it, this comes back
        // as `.alreadyConsumed` — a user who did nothing wrong being told to go
        // and fetch a new code. Any OTHER error is fine: the point is that the
        // code itself survived.
        // Asserted by NAME, not merely "some error". `(any Error).self` would
        // accept `.alreadyConsumed` — the exact failure under test — and the
        // test would pass for the wrong reason.
        let second = try await harness.port(of: host)
        do {
            _ = try await withTimeout(10, "second attempt") {
                try await harness.dialAndPair(port: second, code: code, macIdentity: Curve25519.KeyAgreement.PrivateKey(), label: "test.c2")
            }
            Issue.record("the second attempt should still have failed on the store")
        } catch let error as PairingError {
            #expect(
                error != .alreadyConsumed,
                "a failure the user did not cause burned the code — they are sent for a fresh one to fix a one-sided pairing they cannot see"
            )
        } catch {
            // The store refusal, surfacing as a transport error. Expected.
        }
    }
}

import Testing
import Foundation
import Network
import CryptoKit
@testable import UpLinkKit

// The whole flow, over a real socket, with production code on both sides:
// pair, remove the device, watch the far side find out, pair again.
//
// Every pairing bug fixed today was found by reading code and then argued about
// on hardware one round trip at a time. The parts were unit-tested; the
// SEQUENCE never was — and the sequence is what the user actually does:
//
//     pair → remove it → pair again
//
// Nothing exercised that end to end, which is how "removing a device doesn't
// register on the other one" and "re-pairing fails and I have to retry" could
// both be true with a green suite.
//
// Real `MacSessionHost`, real `NWListener`, real TLS-PSK, real `PairingClient`.

@Suite("Pairing lifecycle: pair, remove, pair again")
struct PairingLifecycleTests {

    private func makeHost() async throws -> (MacSessionHost, InMemoryDeviceDirectory) {
        let store = InMemoryDeviceDirectory()
        let host = MacSessionHost(
            identity: Curve25519.KeyAgreement.PrivateKey(),
            deviceName: "Lifecycle Mac",
            store: store,
            queue: DispatchQueue(label: "lifecycle.host"),
            profile: .localLink,
            monitorsPath: false
        )
        try await host.start()
        return (host, store)
    }

    /// Aimed straight at the host's port, so the test does not depend on Bonjour
    /// resolving inside a test runner.
    private func peer(for host: MacSessionHost) async throws -> DiscoveredPeer {
        let port = try #require(await host.listeningPort)
        return DiscoveredPeer(
            id: "lifecycle",
            name: "Lifecycle Mac",
            endpoint: .hostPort(host: "127.0.0.1", port: port),
            fingerprint: await host.fingerprint,
            profile: .localLink
        )
    }

    /// Dials as a paired phone would: same session key, same PSK identity, same
    /// HELLO. Returns the channel so the caller can read what the Mac says back.
    /// Pairing ends with a listener rebuild, which changes the bound port. In
    /// the product the phone re-discovers over Bonjour; here the test has to
    /// wait for the port to settle, or it dials one that is being released.
    private func settledPort(of host: MacSessionHost) async throws -> NWEndpoint.Port {
        var last: NWEndpoint.Port?
        var stableFor = 0
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let port = await host.listeningPort
            if let port, port.rawValue != 0, port == last {
                stableFor += 1
                if stableFor >= 3 { return port }
            } else {
                stableFor = 0
                last = port
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return try #require(await host.listeningPort)
    }

    private func dialAsPairedPhone(
        to host: MacSessionHost,
        phoneIdentity: Curve25519.KeyAgreement.PrivateKey,
        macDevice: PairedDevice
    ) async throws -> NWConnectionChannel {
        let phoneFingerprint = PairedDevice.fingerprint(of: phoneIdentity.publicKey.rawRepresentation)
        let key = try KeySchedule.sessionKey(
            localPrivate: phoneIdentity,
            remotePublic: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: macDevice.publicKey),
            context: Data(phoneFingerprint.utf8)
        )
        let port = try await settledPort(of: host)
        let connection = NWConnection(
            host: "127.0.0.1",
            port: port,
            using: TransportParameters.session(psk: key, identity: phoneFingerprint, profile: .localLink)
        )
        let channel = NWConnectionChannel(connection: connection)
        try await channel.start(on: DispatchQueue(label: "lifecycle.phone"))

        // The phone announces itself; the Mac dispatches on this frame.
        var mux = Multiplexer(role: .responder)
        try await channel.send(FrameEncoder.encode(mux.makeHello(identity: phoneFingerprint)))
        return channel
    }

    /// Reads frames until one of `kind` arrives, or the bound elapses.
    ///
    /// Bounded at every step. The first version of this test used a bare
    /// `receive()` and hung for ten minutes instead of failing — a test that can
    /// hang is worse than no test, because it stops telling you anything at all.
    private func awaitFrame(
        _ kind: Frame.Kind,
        on channel: NWConnectionChannel,
        within seconds: Double = 5
    ) async -> Bool {
        // NOT wrapped in `withTimeout`, and that matters.
        //
        // `withTimeout` awaits its child tasks when the group scope exits, and
        // `channel.receive()` suspends on a continuation only a network callback
        // resumes — so cancelling it does nothing and the group waits forever.
        // The suite hung for ten minutes instead of failing, twice.
        //
        // Closing the channel is what actually ends a blocked read: it cancels
        // the connection, the pending receive resumes with nil, and the loop
        // exits. So the deadline closes the channel rather than trying to
        // cancel the read.
        let reader = Task { () -> Bool in
            var decoder = FrameDecoder()
            while !Task.isCancelled {
                guard let bytes = try? await channel.receive() else { return false }
                decoder.append(bytes)
                while let frame = try? decoder.next() {
                    if frame.kind == kind { return true }
                }
            }
            return false
        }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await channel.close()
        }
        let found = await reader.value
        deadline.cancel()
        return found
    }

    // MARK: The flow the user actually performs

    // Time-limited at the framework level. An earlier version of this file hung
    // for ten minutes instead of failing, which is worse than no test: a hang
    // tells you nothing and blocks everything behind it.
    @Test("Remove a device while it is offline, then pair it again", .timeLimit(.minutes(1)))
    func removeOfflineThenRepair() async throws {
        let (host, store) = try await makeHost()
        defer { Task { await host.stop() } }

        // 1. Pair.
        let phoneIdentity = Curve25519.KeyAgreement.PrivateKey()
        let phoneFingerprint = PairedDevice.fingerprint(of: phoneIdentity.publicKey.rawRepresentation)
        let firstCode = try PairingCode(digits: "111111")
        try await host.setPairingCode(firstCode)
        let macDevice = try await withTimeout(10, "first pairing") {
            try await PairingClient(queue: DispatchQueue(label: "lifecycle.pair"))
                .pair(with: try await self.peer(for: host), code: firstCode, localIdentity: phoneIdentity)
        }
        #expect(
            try store.pairedDevices().map(\.fingerprint) == [phoneFingerprint],
            "the Mac did not record the pairing"
        )

        // 2. Remove it while the phone is NOT connected. This is the case that
        //    never worked: the `unpaired` frame rides on a live session, and
        //    there isn't one.
        let paired = try #require(try store.pairedDevices().first)
        try store.remove(fingerprint: paired.fingerprint)
        await host.revoke(paired)
        #expect(try store.pairedDevices().isEmpty, "the Mac still lists a device it removed")

        // 3. The phone knows nothing yet and dials as usual. It must be told.
        let channel = try await dialAsPairedPhone(
            to: host, phoneIdentity: phoneIdentity, macDevice: macDevice
        )
        let told = await awaitFrame(.unpaired, on: channel)
        await channel.close()
        #expect(
            told,
            "a device removed while offline was never told — it keeps a pairing this Mac has forgotten and re-dials forever"
        )

        // 4. The Mac must still be on the air: delivering a revocation is not a
        //    reason to stop being findable.
        #expect(await host.listeningPort != nil, "the Mac went off the air after delivering the notice")

        // 5. And pairing again works immediately, with no leftover state.
        let secondCode = try PairingCode(digits: "222222")
        try await host.setPairingCode(secondCode)
        _ = try await withTimeout(10, "re-pairing") {
            try await PairingClient(queue: DispatchQueue(label: "lifecycle.repair"))
                .pair(with: try await self.peer(for: host), code: secondCode, localIdentity: phoneIdentity)
        }
        #expect(
            try store.pairedDevices().map(\.fingerprint) == [phoneFingerprint],
            "re-pairing after a removal did not take"
        )
    }

    // Does a Mac that ALREADY holds a session key accept a new pairing?
    //
    // If not, this is far bigger than tombstones: it means any Mac with a phone
    // already paired cannot pair a second one, and cannot re-pair the first
    // after a removal — which is precisely "re-pairing fails and I have to retry
    // several times".
    @Test("A Mac with an existing paired device can still pair another", .timeLimit(.minutes(1)))
    func pairsWhileAlreadyHoldingASessionKey() async throws {
        let (host, store) = try await makeHost()
        defer { Task { await host.stop() } }

        let firstPhone = Curve25519.KeyAgreement.PrivateKey()
        let firstCode = try PairingCode(digits: "555555")
        try await host.setPairingCode(firstCode)
        _ = try await withTimeout(10, "pair phone one") {
            try await PairingClient(queue: DispatchQueue(label: "multi.1"))
                .pair(with: try await self.peer(for: host), code: firstCode, localIdentity: firstPhone)
        }
        #expect(try store.pairedDevices().count == 1)

        // Now a second phone, with the first still paired — so the listener
        // carries a real session PSK AND the pairing PSK.
        let secondPhone = Curve25519.KeyAgreement.PrivateKey()
        let secondCode = try PairingCode(digits: "666666")
        try await host.setPairingCode(secondCode)
        _ = try await withTimeout(10, "pair phone two") {
            try await PairingClient(queue: DispatchQueue(label: "multi.2"))
                .pair(with: try await self.peer(for: host), code: secondCode, localIdentity: secondPhone)
        }

        #expect(
            try store.pairedDevices().count == 2,
            "a Mac that already holds a session key cannot accept a new pairing — every re-pair after the first would fail"
        )
    }

    // THE ONE THAT WOULD BITE HARDEST. A tombstone that outlives the pairing
    // replacing it means the device pairs and is instantly unpaired again — a
    // loop the user cannot break from either device.
    @Test("A re-paired device is not still treated as revoked", .timeLimit(.minutes(1)))
    func repairedDeviceIsNotStillRevoked() async throws {
        let (host, store) = try await makeHost()
        defer { Task { await host.stop() } }

        let phoneIdentity = Curve25519.KeyAgreement.PrivateKey()
        let firstCode = try PairingCode(digits: "333333")
        try await host.setPairingCode(firstCode)
        let macDevice = try await withTimeout(10, "first pairing") {
            try await PairingClient(queue: DispatchQueue(label: "lifecycle.pair2"))
                .pair(with: try await self.peer(for: host), code: firstCode, localIdentity: phoneIdentity)
        }

        // Remove, then pair again immediately — without the phone ever having
        // collected its notice, so the tombstone is still outstanding.
        let paired = try #require(try store.pairedDevices().first)
        try store.remove(fingerprint: paired.fingerprint)
        await host.revoke(paired)

        let secondCode = try PairingCode(digits: "444444")
        try await host.setPairingCode(secondCode)
        _ = try await withTimeout(10, "re-pairing") {
            try await PairingClient(queue: DispatchQueue(label: "lifecycle.repair2"))
                .pair(with: try await self.peer(for: host), code: secondCode, localIdentity: phoneIdentity)
        }

        // Now connect. A stale tombstone answers `unpaired` here, and the phone
        // deletes the pairing it has just made.
        let channel = try await dialAsPairedPhone(
            to: host, phoneIdentity: phoneIdentity, macDevice: macDevice
        )
        let wronglyTold = await awaitFrame(.unpaired, on: channel, within: 2)
        await channel.close()

        #expect(
            wronglyTold == false,
            "a device that was re-paired is still treated as revoked — it pairs and is instantly unpaired again, a loop the user cannot break from either device"
        )
    }
}

import Testing
import Foundation
import Network
import CryptoKit
@testable import UpLinkKit

// REMOVING A DEVICE MUST REGISTER ON BOTH SIDES, so a clean pairing can follow.
//
// Four cases, and the two that matter are the offline ones — a device removed
// while the other end is not connected has no session to carry the notice, and
// "it will find out eventually" is only true if something is actually arranged.
//
//   1. Mac removes phone, CONNECTED     — announce over the live session
//   2. Mac removes phone, DISCONNECTED  — keep the key for one more dial
//   3. Phone removes Mac, CONNECTED     — announce over the live session
//   4. Phone removes Mac, DISCONNECTED  — keep the key on the air for one dial
//
// Case 2 was silent. The Mac forgot the key and stopped dialling, and because
// the phone never dials, it kept a pairing for a Mac that had forgotten it —
// permanently, with its listener still offering that Mac's key and its UI still
// showing a Mac that could never connect. The comment in the code even said the
// phone would "learn on its next dial", which had been true in the AWDL design
// and became false the moment the roles swapped.
//
// A one-sided pairing is worse than no pairing: re-pairing appears to succeed
// and then behaves strangely, which is exactly the "pairing issues" shape.

@Suite("Regression: unpairing must register on both devices")
struct MutualUnpairRegressionTests {

    private struct Pair {
        let phone: PhoneSessionHost
        let phoneStore: InMemoryDeviceDirectory
        let mac: MacSessionClient
        let macStore: InMemoryDeviceDirectory
        let phoneRecord: PairedDevice   // as the Mac knows it
        let macRecord: PairedDevice     // as the phone knows it
        let port: UInt16
    }

    /// Two devices that already know each other, over a real listener.
    private func makePair() async throws -> Pair {
        let phoneKey = Curve25519.KeyAgreement.PrivateKey()
        let macKey = Curve25519.KeyAgreement.PrivateKey()

        let phoneRecord = PairedDevice(
            fingerprint: PairedDevice.fingerprint(of: phoneKey.publicKey.rawRepresentation),
            name: "iPhone",
            publicKey: phoneKey.publicKey.rawRepresentation,
            pairedAt: Date(),
            udid: "TEST-UDID"
        )
        let macRecord = PairedDevice(
            fingerprint: PairedDevice.fingerprint(of: macKey.publicKey.rawRepresentation),
            name: "Mac",
            publicKey: macKey.publicKey.rawRepresentation,
            pairedAt: Date()
        )

        let phoneStore = InMemoryDeviceDirectory(seed: [macRecord])
        let macStore = InMemoryDeviceDirectory(seed: [phoneRecord])
        let port = UInt16.random(in: 41000 ..< 48000)

        let phone = PhoneSessionHost(
            identity: phoneKey,
            deviceName: "iPhone",
            store: phoneStore,
            dialer: RefusingDialer(),
            queue: DispatchQueue(label: "unpair.phone"),
            port: port
        )
        try await phone.start()

        let mac = MacSessionClient(
            identity: macKey,
            deviceName: "Mac",
            store: macStore,
            queue: DispatchQueue(label: "unpair.mac")
        )

        return Pair(
            phone: phone, phoneStore: phoneStore,
            mac: mac, macStore: macStore,
            phoneRecord: phoneRecord, macRecord: macRecord, port: port
        )
    }

    private func settle(
        _ condition: @Sendable () async -> Bool,
        within seconds: Double = 5
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    // MARK: 1 — Mac removes the phone while connected

    @Test("Mac removes a CONNECTED phone: the phone forgets the Mac", .timeLimit(.minutes(1)))
    func macRemovesConnectedPhone() async throws {
        let p = try await makePair()
        defer { Task { await p.phone.stop() } }

        let session = Task { try await p.mac.runSession(relayPort: p.port, with: p.phoneRecord) }
        defer { session.cancel() }
        #expect(await settle { await p.phone.activeFingerprint != nil }, "no session came up")

        try p.macStore.remove(fingerprint: p.phoneRecord.fingerprint)
        await p.mac.announceUnpaired()
        await p.mac.endSession()

        #expect(
            await settle { ((try? p.phoneStore.pairedDevices()) ?? []).isEmpty },
            "the phone still holds a Mac that removed it — a one-sided pairing"
        )
    }

    // MARK: 2 — Mac removes the phone while DISCONNECTED (the silent case)

    @Test("Mac removes a DISCONNECTED phone: it is told on the next cable", .timeLimit(.minutes(1)))
    func macRemovesDisconnectedPhone() async throws {
        let p = try await makePair()
        defer { Task { await p.phone.stop() } }

        // Never connected. The Mac forgets its record but keeps the key just
        // long enough to say so — this is the tombstone, on the Mac side.
        var tombstones = RevocationTombstones()
        tombstones.revoke(p.phoneRecord)
        try p.macStore.remove(fingerprint: p.phoneRecord.fingerprint)
        #expect(((try? p.macStore.pairedDevices()) ?? []).isEmpty)

        // The phone still believes it is paired, which is the whole problem.
        #expect(((try? p.phoneStore.pairedDevices()) ?? []).count == 1)

        // Next time a relay exists, the notice goes out.
        for device in tombstones.devicesToKeepOnAir() {
            let delivered = await p.mac.deliverUnpairNotice(relayPort: p.port, to: device)
            #expect(delivered, "the notice could not be delivered at all")
            tombstones.delivered(device.fingerprint)
        }

        #expect(
            await settle { ((try? p.phoneStore.pairedDevices()) ?? []).isEmpty },
            "a phone removed while unplugged never found out — it keeps a pairing for a Mac that forgot it"
        )
        // And the notice is not owed twice.
        #expect(tombstones.devicesToKeepOnAir().isEmpty)
    }

    // MARK: 3 — Phone removes the Mac while connected

    @Test("Phone removes a CONNECTED Mac: the Mac forgets the phone", .timeLimit(.minutes(1)))
    func phoneRemovesConnectedMac() async throws {
        let p = try await makePair()
        defer { Task { await p.phone.stop() } }

        let session = Task { try await p.mac.runSession(relayPort: p.port, with: p.phoneRecord) }
        defer { session.cancel() }
        #expect(await settle { await p.phone.activeFingerprint != nil }, "no session came up")

        try p.phoneStore.remove(fingerprint: p.macRecord.fingerprint)
        await p.phone.announceUnpaired()

        #expect(
            await settle { ((try? p.macStore.pairedDevices()) ?? []).isEmpty },
            "the Mac still holds a phone that removed it"
        )
    }

    // MARK: 4 — Phone removes the Mac while DISCONNECTED

    @Test("Phone removes a DISCONNECTED Mac: the Mac is told on its next dial", .timeLimit(.minutes(1)))
    func phoneRemovesDisconnectedMac() async throws {
        let p = try await makePair()
        defer { Task { await p.phone.stop() } }

        // The phone forgets the Mac but keeps its key on the air for one dial.
        try p.phoneStore.remove(fingerprint: p.macRecord.fingerprint)
        await p.phone.revoke(p.macRecord)

        // The Mac, still believing it is paired, dials as usual.
        let session = Task { try? await p.mac.runSession(relayPort: p.port, with: p.phoneRecord) }
        defer { session.cancel() }

        #expect(
            await settle { ((try? p.macStore.pairedDevices()) ?? []).isEmpty },
            "the Mac dialled a phone that had revoked it and was never told"
        )
    }

    // MARK: The point of all four

    // A one-sided pairing is worse than none: it looks paired and behaves
    // strangely. After a removal from EITHER side, both stores must agree that
    // nothing is paired, so the next pairing starts from a clean slate.
    @Test("After a removal from either side, both stores agree", .timeLimit(.minutes(1)))
    func bothStoresAgreeAfterRemoval() async throws {
        // Mac-initiated, phone disconnected — the case that was silent.
        let p = try await makePair()
        defer { Task { await p.phone.stop() } }

        var tombstones = RevocationTombstones()
        tombstones.revoke(p.phoneRecord)
        try p.macStore.remove(fingerprint: p.phoneRecord.fingerprint)
        for device in tombstones.devicesToKeepOnAir() {
            _ = await p.mac.deliverUnpairNotice(relayPort: p.port, to: device)
        }

        #expect(await settle { ((try? p.phoneStore.pairedDevices()) ?? []).isEmpty })
        #expect(((try? p.macStore.pairedDevices()) ?? []).isEmpty)
    }
}

/// Nothing in this suite proxies traffic.
private actor RefusingDialer: DestinationDialer {
    func connect(to destination: StreamOpen) async throws -> DestinationConnection {
        throw ChannelError.notConnected
    }
}

import Testing
import Foundation
import Network
import CryptoKit
@testable import UpLinkKit

// REGRESSION: the session lifecycle, which is where every bug in this change
// lived and where the protocol suite reaches nothing.
//
// Three distinct defects, all invisible to a test that only exercises a happy
// connect/disconnect:
//
//   1. A dying session cleared the state of the one that REPLACED it. The tail
//      of a superseded task runs after the new session installs, saw non-nil
//      state, and wiped it — so the new session carried traffic while status
//      reported "disconnected" and `unpair` tombstoned a peer that was bridging
//      right then.
//   2. `sessionTask?.cancel()` was supposed to enforce "only one peer at a
//      time". It cannot: the task is parked in `channel.receive()`, which
//      suspends on a continuation only a network callback resumes. Two peers
//      proxied at once.
//   3. Claiming the slot across an `await` left a window where two concurrent
//      accepts both believed they had it.

@Suite("Regression: superseding a session must not break the one that replaced it")
struct SessionSupersessionRegressionTests {

    private func makeHost(port: UInt16) -> (PhoneSessionHost, Curve25519.KeyAgreement.PrivateKey, InMemoryDeviceDirectory) {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let store = InMemoryDeviceDirectory()
        let host = PhoneSessionHost(
            identity: key,
            deviceName: "Regression iPhone",
            store: store,
            dialer: NeverDialingDialer(),
            queue: DispatchQueue(label: "regression.supersede"),
            port: port
        )
        return (host, key, store)
    }

    /// Dials the listener exactly as a paired Mac does, proof and all.
    private func dial(
        to port: NWEndpoint.Port,
        as macKey: Curve25519.KeyAgreement.PrivateKey,
        phoneFingerprint: String,
        phonePublicKey: Data
    ) async throws -> NWConnectionChannel {
        let macFingerprint = PairedDevice.fingerprint(of: macKey.publicKey.rawRepresentation)
        let key = try KeySchedule.sessionKey(
            localPrivate: macKey,
            remotePublic: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: phonePublicKey),
            context: Data(phoneFingerprint.utf8)
        )
        let channel = NWConnectionChannel(connection: NWConnection(
            host: "127.0.0.1",
            port: port,
            using: TransportParameters.session(psk: key, identity: macFingerprint)
        ))
        try await channel.start(on: DispatchQueue(label: "regression.mac"))

        var mux = Multiplexer(role: .initiator)
        let proof = HelloProof.tag(
            sessionKey: key,
            dialerFingerprint: macFingerprint,
            listenerFingerprint: phoneFingerprint
        )
        try await channel.send(
            FrameEncoder.encode(mux.makeHello(identity: macFingerprint, proof: proof))
        )
        return channel
    }

    private func settledPort(of host: PhoneSessionHost) async throws -> NWEndpoint.Port {
        for _ in 0 ..< 100 {
            if let bound = await host.listeningPort, bound.rawValue != 0 { return bound }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ChannelError.handshakeFailed("listener never bound")
    }

    private func await_(
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

    // The whole regression, in the order it actually happens.
    @Test("A second Mac supersedes the first, and the first's teardown leaves it alone", .timeLimit(.minutes(1)))
    func supersessionKeepsTheNewSession() async throws {
        let (host, phoneKey, store) = makeHost(port: UInt16.random(in: 41000 ..< 48000))
        defer { Task { await host.stop() } }

        let phoneFingerprint = PairedDevice.fingerprint(of: phoneKey.publicKey.rawRepresentation)
        let macA = Curve25519.KeyAgreement.PrivateKey()
        let macB = Curve25519.KeyAgreement.PrivateKey()
        for mac in [macA, macB] {
            try store.save(PairedDevice(
                fingerprint: PairedDevice.fingerprint(of: mac.publicKey.rawRepresentation),
                name: "Mac",
                publicKey: mac.publicKey.rawRepresentation,
                pairedAt: Date()
            ))
        }

        try await host.start()
        let port = try await settledPort(of: host)

        let channelA = try await dial(
            to: port, as: macA,
            phoneFingerprint: phoneFingerprint, phonePublicKey: phoneKey.publicKey.rawRepresentation
        )
        let fingerprintA = PairedDevice.fingerprint(of: macA.publicKey.rawRepresentation)
        #expect(await await_ { await host.activeFingerprint == fingerprintA })

        // B arrives while A is still live.
        let channelB = try await dial(
            to: port, as: macB,
            phoneFingerprint: phoneFingerprint, phonePublicKey: phoneKey.publicKey.rawRepresentation
        )
        let fingerprintB = PairedDevice.fingerprint(of: macB.publicKey.rawRepresentation)

        #expect(
            await await_ { await host.activeFingerprint == fingerprintB },
            "the second Mac never took over"
        )

        // A's channel must actually have been CLOSED, not merely forgotten —
        // cancelling its task cannot end it.
        #expect(
            await await_ { (try? await channelA.receive()) == .some(nil) },
            "the superseded session's channel is still open, so both Macs are proxying"
        )

        // And after A's teardown has had every chance to run, B must still be
        // the live session. This is the assertion the generation stamp exists
        // for: without it, A's tail wipes B.
        try await Task.sleep(for: .milliseconds(300))
        #expect(
            await host.activeFingerprint == fingerprintB,
            "the superseded session's teardown cleared the session that replaced it"
        )
        #expect(await host.responder != nil, "the live session lost its responder")

        await channelB.close()
    }

    // CONCURRENT accepts, not sequential ones.
    //
    // **This test does not prove the fix, and it is worth being clear about
    // that.** The defect it targets — two `handleSession` calls interleaving
    // their `responder`/`sessionStarted`/`sessionTask` writes across a
    // suspension, leaving the live session holding a DEAD responder — is a
    // race, and this was checked by reintroducing the suspension: the test
    // still passed. Real TLS handshakes do not line the timing up reliably.
    //
    // What actually guarantees the property is structural: the install between
    // claiming the slot and setting `sessionTask` contains no `await` at all,
    // so there is no window to interleave in. That is why the superseded
    // channel is closed in a detached task and the unpair handler is passed to
    // `BridgeResponder.init` rather than registered with one.
    //
    // This is kept as a consistency check — several simultaneous dials must
    // still settle on exactly one session whose responder belongs to it — and
    // as the thing that fails loudly if someone reintroduces an `await` there
    // AND the timing happens to cooperate. A test that cannot fail is not a
    // proof, and pretending otherwise is worse than having no test.
    @Test("Simultaneous dials leave exactly one consistent session", .timeLimit(.minutes(1)))
    func concurrentDialsDoNotInterleave() async throws {
        let (host, phoneKey, store) = makeHost(port: UInt16.random(in: 41000 ..< 48000))
        defer { Task { await host.stop() } }

        let phoneFingerprint = PairedDevice.fingerprint(of: phoneKey.publicKey.rawRepresentation)
        let macs = (0 ..< 4).map { _ in Curve25519.KeyAgreement.PrivateKey() }
        for mac in macs {
            try store.save(PairedDevice(
                fingerprint: PairedDevice.fingerprint(of: mac.publicKey.rawRepresentation),
                name: "Mac",
                publicKey: mac.publicKey.rawRepresentation,
                pairedAt: Date()
            ))
        }

        try await host.start()
        let port = try await settledPort(of: host)

        // A prior session, so every concurrent accept has something to
        // supersede — which is what put a suspension in the install path.
        let primer = try await dial(
            to: port, as: macs[0],
            phoneFingerprint: phoneFingerprint, phonePublicKey: phoneKey.publicKey.rawRepresentation
        )
        #expect(await await_ { await host.activeFingerprint != nil })

        // All at once.
        let channels = try await withThrowingTaskGroup(of: NWConnectionChannel.self) { group in
            for mac in macs.dropFirst() {
                group.addTask {
                    try await self.dial(
                        to: port, as: mac,
                        phoneFingerprint: phoneFingerprint,
                        phonePublicKey: phoneKey.publicKey.rawRepresentation
                    )
                }
            }
            var collected: [NWConnectionChannel] = []
            for try await channel in group { collected.append(channel) }
            return collected
        }

        // Let every install and teardown settle.
        try await Task.sleep(for: .milliseconds(600))

        let live = await host.activeFingerprint
        #expect(live != nil, "every concurrent dial was dropped")

        // THE ASSERTION. The live session's responder must belong to the live
        // session — i.e. its channel must still be open. A responder left over
        // from a session whose channel was closed reports a stale egress and
        // cannot deliver an unpair notice.
        let responder = await host.responder
        #expect(responder != nil, "the live session has no responder")
        if let responder {
            #expect(
                await responder.peerFingerprint == live,
                "the live session is holding a responder from a DIFFERENT session"
            )
        }

        await primer.close()
        for channel in channels { await channel.close() }
    }

    // `endSession` must close the socket, or the far side goes on believing it
    // is bridging and the responder keeps dialling destinations for a peer the
    // user has just removed.
    @Test("endSession closes the connection, not just the bookkeeping", .timeLimit(.minutes(1)))
    func endSessionClosesTheChannel() async throws {
        let (host, phoneKey, store) = makeHost(port: UInt16.random(in: 41000 ..< 48000))
        defer { Task { await host.stop() } }

        let phoneFingerprint = PairedDevice.fingerprint(of: phoneKey.publicKey.rawRepresentation)
        let mac = Curve25519.KeyAgreement.PrivateKey()
        try store.save(PairedDevice(
            fingerprint: PairedDevice.fingerprint(of: mac.publicKey.rawRepresentation),
            name: "Mac",
            publicKey: mac.publicKey.rawRepresentation,
            pairedAt: Date()
        ))

        try await host.start()
        let port = try await settledPort(of: host)
        let channel = try await dial(
            to: port, as: mac,
            phoneFingerprint: phoneFingerprint, phonePublicKey: phoneKey.publicKey.rawRepresentation
        )
        #expect(await await_ { await host.activeFingerprint != nil })

        await host.endSession()

        #expect(
            await await_ { (try? await channel.receive()) == .some(nil) },
            "the session ended on this side but the socket stayed open — the peer still thinks it is bridging"
        )
        #expect(await host.activeFingerprint == nil)
    }

    // An unverified peer must not be able to burn a tombstone. Doing so means
    // the notice is marked delivered and the REAL Mac is never told.
    @Test("A peer with no key for the fingerprint it claims is refused outright", .timeLimit(.minutes(1)))
    func forgedFingerprintIsRefused() async throws {
        let (host, phoneKey, store) = makeHost(port: UInt16.random(in: 41000 ..< 48000))
        defer { Task { await host.stop() } }

        let phoneFingerprint = PairedDevice.fingerprint(of: phoneKey.publicKey.rawRepresentation)
        let real = Curve25519.KeyAgreement.PrivateKey()
        let impostor = Curve25519.KeyAgreement.PrivateKey()
        let realFingerprint = PairedDevice.fingerprint(of: real.publicKey.rawRepresentation)
        for mac in [real, impostor] {
            try store.save(PairedDevice(
                fingerprint: PairedDevice.fingerprint(of: mac.publicKey.rawRepresentation),
                name: "Mac",
                publicKey: mac.publicKey.rawRepresentation,
                pairedAt: Date()
            ))
        }

        try await host.start()
        let port = try await settledPort(of: host)

        // The impostor authenticates honestly with its OWN key, then announces
        // the other Mac's fingerprint.
        let impostorFingerprint = PairedDevice.fingerprint(of: impostor.publicKey.rawRepresentation)
        let key = try KeySchedule.sessionKey(
            localPrivate: impostor,
            remotePublic: phoneKey.publicKey,
            context: Data(phoneFingerprint.utf8)
        )
        let channel = NWConnectionChannel(connection: NWConnection(
            host: "127.0.0.1",
            port: port,
            using: TransportParameters.session(psk: key, identity: impostorFingerprint)
        ))
        try await channel.start(on: DispatchQueue(label: "regression.impostor"))

        var mux = Multiplexer(role: .initiator)
        let forged = HelloProof.tag(
            sessionKey: key,
            dialerFingerprint: realFingerprint,   // the claim
            listenerFingerprint: phoneFingerprint
        )
        try await channel.send(
            FrameEncoder.encode(mux.makeHello(identity: realFingerprint, proof: forged))
        )

        #expect(
            await await_ { (try? await channel.receive()) == .some(nil) },
            "the listener did not close a connection announcing a fingerprint it cannot prove"
        )
        #expect(
            await host.activeFingerprint == nil,
            "a forged fingerprint established a session"
        )
    }
}

/// Nothing in this suite proxies traffic; a dial reaching here is a bug.
private actor NeverDialingDialer: DestinationDialer {
    func connect(to destination: StreamOpen) async throws -> DestinationConnection {
        throw ChannelError.notConnected
    }
}

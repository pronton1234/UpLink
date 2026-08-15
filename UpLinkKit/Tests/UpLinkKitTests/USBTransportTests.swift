import Testing
import Foundation
import Network
import CryptoKit
@testable import UpLinkKit

// The whole wired stack in one process: a real phone-side listener, a real
// TLS-PSK handshake, the real HELLO/HELLO_ACK exchange in its NEW direction,
// and a real proxied stream — driven by the real `MacSessionClient`.
//
// What this does NOT include is the cable itself and the app's relay, which is
// pure byte-pumping. Everything above that is byte-for-byte the production
// path, which matters because the transport reversed: the Mac dials and speaks
// first now, and a mistake there is a mutual hang rather than an error.

/// Stands in for "the internet" on the phone's side.
private actor LocalEcho: DestinationDialer, DestinationConnection {

    private var inbox: [Data] = []
    private var waiters: [CheckedContinuation<Data?, Never>] = []
    private var closed = false

    func connect(to destination: StreamOpen) async throws -> DestinationConnection { self }
    func egressInterface() async -> EgressInterface { .cellular }

    func send(_ data: Data) async throws {
        // Echo with a marker, so the test proves the bytes went out to a
        // destination and came back rather than being reflected somewhere in
        // the mux.
        let reply = Data("echo:".utf8) + data
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: reply)
        } else {
            inbox.append(reply)
        }
    }

    func receive() async throws -> Data? {
        if !inbox.isEmpty { return inbox.removeFirst() }
        if closed { return nil }
        return await withCheckedContinuation { waiters.append($0) }
    }

    func close() async {
        guard !closed else { return }
        closed = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(returning: nil) }
    }
}

@Suite("Wired transport end to end")
struct USBTransportTests {

    /// A paired pair of devices, with both sides' records already written.
    private struct Paired {
        let phone: PhoneSessionHost
        let phoneStore: InMemoryDeviceDirectory
        let macClient: MacSessionClient
        let macStore: InMemoryDeviceDirectory
        let phoneRecord: PairedDevice
        let port: UInt16
    }

    private func makePaired() async throws -> Paired {
        let phoneKey = Curve25519.KeyAgreement.PrivateKey()
        let macKey = Curve25519.KeyAgreement.PrivateKey()

        let phoneFingerprint = PairedDevice.fingerprint(of: phoneKey.publicKey.rawRepresentation)
        let macFingerprint = PairedDevice.fingerprint(of: macKey.publicKey.rawRepresentation)

        // The phone knows the Mac; the Mac knows the phone. Written directly
        // rather than by pairing, so a failure here is a transport failure and
        // not a pairing one — `PairingLifecycleTests` covers the other half.
        let phoneRecord = PairedDevice(
            fingerprint: phoneFingerprint,
            name: "Test iPhone",
            publicKey: phoneKey.publicKey.rawRepresentation,
            pairedAt: Date(),
            udid: "TEST-UDID"
        )
        let macRecord = PairedDevice(
            fingerprint: macFingerprint,
            name: "Test Mac",
            publicKey: macKey.publicKey.rawRepresentation,
            pairedAt: Date()
        )

        let phoneStore = InMemoryDeviceDirectory(seed: [macRecord])
        let macStore = InMemoryDeviceDirectory(seed: [phoneRecord])

        let port = UInt16.random(in: 48000 ..< 52000)
        let phone = PhoneSessionHost(
            identity: phoneKey,
            deviceName: "Test iPhone",
            store: phoneStore,
            dialer: LocalEcho(),
            queue: DispatchQueue(label: "usb.phone"),
            port: port
        )
        try await phone.start()

        let macClient = MacSessionClient(
            identity: macKey,
            deviceName: "Test Mac",
            store: macStore,
            queue: DispatchQueue(label: "usb.mac")
        )

        return Paired(
            phone: phone, phoneStore: phoneStore,
            macClient: macClient, macStore: macStore,
            phoneRecord: phoneRecord, port: port
        )
    }

    // THE test. If this fails, nothing works on a phone either.
    @Test("The Mac dials, both sides handshake, and a stream carries bytes", .timeLimit(.minutes(1)))
    func endToEnd() async throws {
        let paired = try await makePaired()
        defer { Task { await paired.phone.stop() } }

        let session = Task {
            try await paired.macClient.runSession(relayPort: paired.port, with: paired.phoneRecord)
        }
        defer { session.cancel() }

        // Wait for the handshake to complete on both ends.
        var initiator: BridgeInitiator?
        for _ in 0 ..< 200 {
            if let live = await paired.macClient.initiator,
               await paired.phone.activeFingerprint != nil {
                initiator = live
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let mux = try #require(initiator, "the session never came up")

        // The phone must have learned WHICH Mac, and proven it.
        let macFingerprint = await paired.macClient.fingerprint
        #expect(await paired.phone.activeFingerprint == macFingerprint)

        // A real proxied stream.
        let stream = try await mux.openStream(
            to: StreamOpen(proto: .tcp, host: "example.com", port: 443)
        )
        try await stream.send(Data("hello".utf8))

        var received = Data()
        for _ in 0 ..< 200 {
            if let chunk = try await stream.receive() {
                received.append(chunk)
                if received.count >= 10 { break }
            }
        }
        #expect(received == Data("echo:hello".utf8))
    }

    // The phone must not believe a fingerprint it cannot verify. This is the
    // same guarantee `HelloBindingRegressionTests` proves in isolation, checked
    // here through the real listener so a wiring mistake cannot make it vacuous.
    @Test("A Mac with no pairing on the phone is refused", .timeLimit(.minutes(1)))
    func unknownMacIsRefused() async throws {
        let paired = try await makePaired()
        defer { Task { await paired.phone.stop() } }

        // A different Mac entirely — the phone holds no key for it, so TLS
        // itself has nothing to select and the handshake cannot complete.
        let stranger = MacSessionClient(
            identity: Curve25519.KeyAgreement.PrivateKey(),
            deviceName: "Someone Else's Mac",
            store: InMemoryDeviceDirectory(seed: [paired.phoneRecord]),
            queue: DispatchQueue(label: "usb.stranger")
        )

        await #expect(throws: (any Error).self) {
            try await stranger.runSession(relayPort: paired.port, with: paired.phoneRecord)
        }
        #expect(await paired.phone.activeFingerprint == nil, "a stranger established a session")
    }

    // Nothing is listening on that port. Over the cable this is the ordinary
    // "UpLink is not running on the phone" case, and it must fail promptly
    // rather than hanging — a dial that never returns is a bridge that never
    // retries.
    @Test("A dial to a port nobody is serving fails rather than hanging", .timeLimit(.minutes(1)))
    func deadPortFailsFast() async throws {
        let paired = try await makePaired()
        defer { Task { await paired.phone.stop() } }

        let dead = UInt16.random(in: 52000 ..< 56000)
        let started = ContinuousClock.now
        await #expect(throws: (any Error).self) {
            try await paired.macClient.runSession(relayPort: dead, with: paired.phoneRecord)
        }
        #expect(
            started.duration(to: .now) < .seconds(NWConnectionChannel.connectTimeout),
            "a refused connection waited for the full connect timeout"
        )
    }

    // Ending the session must be visible on BOTH sides. A phone that thinks it
    // is still bridging keeps a listener busy for a Mac that has moved on, and
    // a Mac that thinks so keeps claiming flows it cannot carry — the shape
    // that once produced 31,034 broken pipes against a session both ends
    // believed was healthy.
    @Test("Ending the session is observed on both sides", .timeLimit(.minutes(1)))
    func teardownIsMutual() async throws {
        let paired = try await makePaired()
        defer { Task { await paired.phone.stop() } }

        let session = Task {
            try? await paired.macClient.runSession(relayPort: paired.port, with: paired.phoneRecord)
        }
        defer { session.cancel() }

        for _ in 0 ..< 200 {
            if await paired.phone.activeFingerprint != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(await paired.phone.activeFingerprint != nil, "the session never came up")

        await paired.macClient.endSession()

        var phoneNoticed = false
        for _ in 0 ..< 200 {
            if await paired.phone.activeFingerprint == nil { phoneNoticed = true; break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(phoneNoticed, "the phone still believes it is bridging for a Mac that has gone")
        #expect(await paired.macClient.initiator == nil)
    }
}

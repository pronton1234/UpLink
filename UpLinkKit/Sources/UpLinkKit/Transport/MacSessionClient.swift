import Foundation
import Network
import CryptoKit
import OSLog

/// The Mac's side of the bridge: dials the phone through the cable.
///
/// **The Mac dials now.** `usbmuxd` only carries Mac→phone connections, so this
/// replaces the old always-listening `MacSessionHost`. It does not speak to
/// `usbmuxd` itself — that lives in the menu-bar app, because this code runs
/// inside the *sandboxed* proxy system extension and the sandbox does not
/// permit opening `/var/run/usbmuxd`. The app pumps the cable onto a loopback
/// port and tells us the number; everything from the TLS handshake up is
/// unchanged and remains end to end with the phone, so the relay carries only
/// ciphertext.
public actor MacSessionClient {

    private let log = Logger(subsystem: UpLinkIdentifiers.logSubsystem, category: "host")

    private let identity: Curve25519.KeyAgreement.PrivateKey
    private let deviceName: String
    private let store: DeviceDirectory
    private let queue: DispatchQueue

    /// The live session, handed to the proxy extension so captured flows have
    /// somewhere to go. Nil whenever no phone is connected.
    public private(set) var initiator: BridgeInitiator?
    public private(set) var peerDescription: String?
    public private(set) var activeFingerprint: String?

    /// The live session's channel, retained so ``endSession()`` can close it.
    ///
    /// **Closing it is not tidiness — it is what makes the PHONE notice.** The
    /// phone's listener learns a session is over when its own receive completes,
    /// which happens when this socket goes away. Ending our side while leaving
    /// the socket open leaves the phone believing it is still bridging for a Mac
    /// that has moved on: it holds the session slot, refuses nothing, and the
    /// two devices disagree about reality until something else times out. The
    /// mirror of this bug was already fixed once on the other side.
    private var activeChannel: FrameChannel?

    /// Bumped per session, for the same reason the phone's listener needs one.
    ///
    /// Two `runSession`s can overlap: `usbmuxd`'s event stream can end and
    /// restart, replaying `.attached`, which makes the relay bind a NEW
    /// ephemeral port with no intervening detach. The redial loop then starts a
    /// second session while the first is still unwinding, and without this the
    /// old one's teardown clears the new one's `initiator` — so the proxy stops
    /// claiming flows while a perfectly good session is running. A dead bridge
    /// until the cable is pulled.
    private var sessionGeneration = 0

    private var sessionTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<SessionHostEvent>.Continuation] = [:]

    public init(
        identity: Curve25519.KeyAgreement.PrivateKey,
        deviceName: String,
        store: DeviceDirectory,
        queue: DispatchQueue
    ) {
        self.identity = identity
        self.deviceName = deviceName
        self.store = store
        self.queue = queue
    }

    public var fingerprint: String {
        PairedDevice.fingerprint(of: identity.publicKey.rawRepresentation)
    }

    public func events() -> AsyncStream<SessionHostEvent> {
        AsyncStream { continuation in
            let token = UUID()
            continuations[token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(token) }
            }
        }
    }

    private func removeObserver(_ token: UUID) {
        continuations.removeValue(forKey: token)
    }

    private func emit(_ event: SessionHostEvent) {
        for (_, continuation) in continuations { continuation.yield(event) }
    }

    // MARK: - Sessions

    /// Dials the relay and runs a session with `device` until it ends.
    ///
    /// Returns once the session is over, so the caller's reconnect loop can
    /// decide whether to try again — the cable may simply have been unplugged,
    /// which is not a failure worth retrying in a tight loop.
    public func runSession(relayPort: UInt16, with device: PairedDevice) async throws {
        let key = try sessionKey(for: device)
        let channel = try await dial(port: relayPort, psk: key, identity: fingerprint)

        // Proves to the phone that we are the Mac we say we are. See
        // ``HelloProof``: TLS establishes that we hold one of the phone's PSKs,
        // not which one, and the phone acts on the fingerprint we announce.
        let proof = HelloProof.tag(
            sessionKey: key,
            dialerFingerprint: fingerprint,
            listenerFingerprint: device.fingerprint
        )

        let initiator = BridgeInitiator(
            channel: channel,
            localFingerprint: fingerprint,
            peerFingerprint: device.fingerprint,
            helloProof: proof
        )
        sessionGeneration += 1
        let generation = sessionGeneration
        self.initiator = initiator
        activeChannel = channel
        let description = "usb:127.0.0.1:\(relayPort) → \(device.name)"
        peerDescription = description
        activeFingerprint = device.fingerprint

        emit(.sessionStarted(fingerprint: device.fingerprint, peerDescription: description))

        let token = await initiator.onEgressChange { [weak self] interface in
            Task { await self?.emit(.egressObserved(interface)) }
        }
        _ = await initiator.onUnpairedByPeer { [weak self] in
            Task {
                await self?.peerUnpaired(fingerprint: device.fingerprint, generation: generation)
            }
        }

        do {
            try await initiator.run()
        } catch {
            emit(.failed(String(describing: error)))
        }
        await initiator.removeEgressObserver(token)
        await sessionFinished(
            fingerprint: device.fingerprint, channel: channel, generation: generation
        )
    }

    /// Ends the live session without tearing anything else down.
    public func endSession() async {
        sessionTask?.cancel()
        sessionTask = nil
        guard let fingerprint = activeFingerprint else { return }
        // The channel, not nil: see ``activeChannel``.
        await sessionFinished(
            fingerprint: fingerprint, channel: activeChannel, generation: sessionGeneration
        )
    }

    private func sessionFinished(
        fingerprint: String,
        channel: FrameChannel?,
        generation: Int
    ) async {
        guard activeFingerprint != nil else { return }        // already ended
        guard generation == sessionGeneration else { return } // superseded
        activeFingerprint = nil
        initiator = nil
        peerDescription = nil
        activeChannel = nil
        await channel?.close()
        emit(.sessionEnded(fingerprint: fingerprint))
    }

    /// The phone has removed this Mac. Drop our half of the pairing.
    private func peerUnpaired(fingerprint: String, generation: Int) async {
        log.error("peer \(fingerprint, privacy: .public) unpaired us — forgetting it")
        try? store.remove(fingerprint: fingerprint)
        emit(.peerUnpaired(fingerprint: fingerprint))
        await sessionFinished(
            fingerprint: fingerprint,
            channel: generation == sessionGeneration ? activeChannel : nil,
            generation: generation
        )
    }

    /// Tells the phone this Mac has forgotten it, before tearing down.
    public func announceUnpaired() async {
        guard let initiator else { return }
        await initiator.announceUnpaired()
    }

    // MARK: - Pairing

    /// Dials the relay with the six-digit code and completes pairing.
    ///
    /// The user reads the code off this Mac and types it into the phone, which
    /// is what arms the phone's listener with the matching PSK. A wrong code
    /// fails inside the TLS handshake — this is the only place a mismatch can
    /// be detected, and it arrives as an opaque transport error, so it is
    /// mapped here to the value the UI can actually explain.
    public func pair(relayPort: UInt16, code: PairingCode, udid: String) async throws -> PairedDevice {
        let channel: FrameChannel
        do {
            channel = try await dial(
                port: relayPort,
                parameters: TransportParameters.pairing(code: code)
            )
        } catch {
            throw PairingError.codeMismatch
        }
        defer { Task { await channel.close() } }

        var device = try await PairingClient(deviceName: deviceName)
            .pair(on: channel, localIdentity: identity)

        // Pin the pairing to the physical device it was made over.
        //
        // The UDID comes from usbmuxd, not from anything the peer said, so it
        // is the one identifier in this exchange that cannot be claimed. It
        // lets the Mac refuse to bridge through a *different* phone that
        // happens to hold a paired key.
        device.udid = udid
        try store.save(device)
        emit(.paired(device))
        return device
    }

    // MARK: - Dialling

    private func sessionKey(for device: PairedDevice) throws -> SymmetricKey {
        let remote = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: device.publicKey)
        // Context is the PHONE's fingerprint on both ends: it is the phone's
        // own identity there, and comes from our paired record here.
        return try KeySchedule.sessionKey(
            localPrivate: identity,
            remotePublic: remote,
            context: Data(device.fingerprint.utf8)
        )
    }

    private func dial(port: UInt16, psk: SymmetricKey, identity: String) async throws -> FrameChannel {
        try await dial(port: port, parameters: TransportParameters.session(psk: psk, identity: identity))
    }

    private func dial(port: UInt16, parameters: NWParameters) async throws -> FrameChannel {
        let endpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!
        )
        let channel = NWConnectionChannel(connection: NWConnection(to: endpoint, using: parameters))
        try await channel.start(on: queue)
        return channel
    }
}

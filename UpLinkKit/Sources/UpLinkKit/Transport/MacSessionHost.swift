import Foundation
import Network
import CryptoKit
import OSLog

public enum SessionHostEvent: Sendable {
    case paired(PairedDevice)
    case sessionStarted(fingerprint: String, peerDescription: String)
    case sessionEnded(fingerprint: String)
    case egressObserved(EgressInterface)
    /// The phone removed this pairing from its side.
    case peerUnpaired(fingerprint: String)
    case failed(String)
}

/// The Mac's always-on side of the bridge.
///
/// Advertises this Mac over Bonjour, accepts whatever the phone dials in, and
/// decides — from the first frame — whether the connection is a pairing attempt
/// or a bridging session. Everything the user sees on the Mac is downstream of
/// this; the Mac itself is never driven by the user.
///
/// One listener serves both purposes. Each paired phone contributes a TLS-PSK
/// keyed by its own fingerprint, and while a pairing code is on screen the code
/// contributes one more. TLS 1.3 picks by the identity the client offers, so
/// there is no second port and no second Bonjour service to keep in sync.
public actor MacSessionHost {

    private let log = Logger(subsystem: UpLinkIdentifiers.logSubsystem, category: "host")

    private let identity: Curve25519.KeyAgreement.PrivateKey
    private let deviceName: String
    private let store: DeviceDirectory
    private let queue: DispatchQueue
    private let profile: TransportProfile

    private var listener: NWListener?
    private var pairingSession: PairingSession?
    private var pairingCode: PairingCode?

    /// The live session's initiator, handed to the proxy extension so captured
    /// flows have somewhere to go. Nil whenever no phone is connected.
    public private(set) var initiator: BridgeInitiator?

    /// Endpoint description of the connected phone, so the proxy extension can
    /// refuse to capture its own traffic to it.
    public private(set) var peerDescription: String?

    private var sessionTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<SessionHostEvent>.Continuation] = [:]

    // MARK: Path awareness
    //
    // THE MISSING SENSOR ON THIS SIDE. `restartListener()` was reachable only
    // from `start()` and `setPairingCode()`, so once the Mac was up it never
    // re-advertised for any reason. A listener that survives a radio change but
    // stops being advertised on the re-derived `awdl0` produces exactly the
    // silence that was measured: the phone browses, finds nothing, and the Mac
    // logs no error because from its point of view nothing went wrong.

    /// Holds a unicast socket to the peer between sessions, so the kernel keeps
    /// scheduling AWDL and Bonjour keeps advertising on it. See ``AWDLPresence``
    /// for the measurement behind this.
    private lazy var presence = AWDLPresence(queue: queue)

    /// Devices unpaired while they were not connected, kept reachable only long
    /// enough to be told. See ``RevocationTombstones``.
    private var tombstones = RevocationTombstones()

    private var pathMonitor: NWPathMonitor?
    private var lastPathSignature: PathSignature?
    private var pathDebounceTask: Task<Void, Never>?
    private let pathDebounce: Duration
    private let monitorsPath: Bool

    /// How many listeners have been built. The only observable proof from
    /// outside that a path change produced a *re-advertisement* rather than
    /// being swallowed — and the guard that stops `restartListener`'s own
    /// `cancel()` from being mistaken for a failure worth rebuilding for.
    public private(set) var listenerGeneration = 0

    public init(
        identity: Curve25519.KeyAgreement.PrivateKey,
        deviceName: String,
        store: DeviceDirectory,
        queue: DispatchQueue,
        profile: TransportProfile = TransportProfile.preferenceOrder.first ?? .localLink,
        // Long enough that one Wi-Fi disconnect — which produces a burst of
        // path updates as the interface is torn down and re-derived — settles
        // into a single rebuild. Short enough that the phone, retrying every
        // half second, does not spend the whole window browsing for a service
        // that is not on the air. Injectable so the debounce can be tested
        // without waiting it out.
        pathDebounce: Duration = .milliseconds(1500),
        // Off only in tests. The real monitor reports the *test machine's*
        // actual network, on its own schedule, which makes any assertion about
        // what a given path change caused a race against the room's Wi-Fi.
        monitorsPath: Bool = true
    ) {
        self.identity = identity
        self.deviceName = deviceName
        self.store = store
        self.queue = queue
        self.profile = profile
        self.pathDebounce = pathDebounce
        self.monitorsPath = monitorsPath
    }

    public var fingerprint: String {
        PairedDevice.fingerprint(of: identity.publicKey.rawRepresentation)
    }

    /// The port the listener bound to, once it is running.
    ///
    /// In the product the phone always arrives via Bonjour and never needs
    /// this. It exists so a test can dial the real listener directly and
    /// exercise the TLS-PSK handshake without a Bonjour round trip, which is
    /// the seam where a pairing failure actually lives.
    public var listeningPort: NWEndpoint.Port? { listener?.port }

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

    // MARK: Listening

    public func start() async throws {
        try restartListener()
        await awaitListening()
        startPathMonitoring()
    }

    public func stop() {
        Task { [presence] in await presence.release() }
        pathDebounceTask?.cancel()
        pathDebounceTask = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        lastPathSignature = nil
        sessionTask?.cancel()
        sessionTask = nil
        listener?.cancel()
        listener = nil
        // Emit the end rather than clearing state silently. Tearing the host
        // down without `.sessionEnded` leaves every consumer — the proxy's
        // `hasSession`, the menu bar, the route tunnel — believing a session is
        // still live, which is the same class of lie this whole change exists
        // to remove.
        if let fingerprint = activeFingerprint {
            Task { await sessionFinished(fingerprint: fingerprint, channel: nil) }
        } else {
            initiator = nil
            peerDescription = nil
        }
    }

    /// Puts a code on the air, or takes it off again.
    ///
    /// Rebuilds the listener because the pairing PSK has to be baked into the
    /// TLS options. Cheap, and it happens at most twice per pairing.
    public func setPairingCode(_ code: PairingCode?, now: Date = Date()) async throws {
        pairingCode = code
        pairingSession = code.map { PairingSession(code: $0, issuedAt: now) }
        try restartListener()
        await awaitListening()
    }

    /// Waits until the new listener has actually bound.
    ///
    /// Rebuilding takes the Mac off the air for a moment, and callers — the
    /// pairing flow above all — must not report success before it is reachable
    /// again. The port itself changes on every rebuild: `NWListener` will not
    /// rebind a port it just released (EADDRINUSE, and `allowLocalEndpointReuse`
    /// does not cover two listeners at once), so the Bonjour re-advertisement is
    /// what carries the new address to the phone.
    private func awaitListening() async {
        // Three seconds, not one. Measured: a rebuild triggered by a path
        // change repeatedly logged "did not bind within 1s" and then bound
        // shortly after — so the old bound was reporting a failure that had not
        // happened, and callers were proceeding as though the Mac were on the
        // air when it was still a moment away. Only the failure path is slow;
        // a healthy bind returns in a few milliseconds.
        for _ in 0 ..< 300 {
            if let port = listener?.port, port.rawValue != 0 { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        log.error("listener did not bind within 3s")
    }

    private func restartListener() throws {
        listener?.cancel()

        let paired = (try? store.pairedDevices()) ?? []

        // Revoked devices keep a PSK so they can connect ONCE and be told. They
        // are refused a session in `handleSession`; without the key they could
        // not reach us at all, and the notice could never be delivered.
        tombstones.expire()
        let reachable = paired + tombstones.devicesToKeepOnAir()

        // One PSK per paired phone, keyed by that phone's own fingerprint so
        // the client's offered identity picks the right one.
        let sessionKeys: [(identity: String, key: SymmetricKey)] = reachable.compactMap { device in
            guard let remote = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: device.publicKey),
                  let key = try? KeySchedule.sessionKey(
                      localPrivate: identity,
                      remotePublic: remote,
                      context: Data(device.fingerprint.utf8)
                  )
            else {
                // Was `compactMap` with no else: a device whose stored public
                // key will not parse became a phone that can never connect,
                // with nothing in the log to say why.
                log.error("paired device \(device.name, privacy: .public) fp=\(device.fingerprint, privacy: .public) has an unusable public key — it cannot connect")
                return nil
            }
            return (device.fingerprint, key)
        }

        var pairingKey: (identity: String, key: SymmetricKey)?
        if let pairingCode {
            // Salted with the FINGERPRINT, not the device name.
            //
            // Both sides must derive the identical salt or the TLS-PSK
            // handshake fails with no usable diagnostic. A display name is a
            // terrible input for that: it travels through DNS-SD, may be
            // renamed for uniqueness, and commonly contains a typographic
            // apostrophe (U+2019) that can round-trip differently. The
            // fingerprint is hex ASCII, is already published in the TXT record,
            // and is byte-identical on both ends by construction.
            let salt = Data(SHA256.hash(data: Data(fingerprint.utf8)))
            pairingKey = (
                TransportParameters.pairingIdentity,
                KeySchedule.pairingKey(code: pairingCode, salt: salt)
            )
        }

        let parameters = TransportParameters.listener(
            sessionKeys: sessionKeys,
            pairingKey: pairingKey,
            profile: profile
        )

        let listener = try NWListener(using: parameters)
        listener.service = NWListener.Service(
            name: deviceName,
            type: UpLinkService.bonjourType,
            domain: nil,
            txtRecord: NWTXTRecord([UpLinkService.fingerprintKey: fingerprint])
        )

        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        // Generation-stamped, because `restartListener` cancels the outgoing
        // listener and that fires `.cancelled` on it. Without the stamp, a
        // rebuild triggers a rebuild triggers a rebuild.
        listenerGeneration += 1
        let generation = listenerGeneration
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case let .failed(error):
                Task { await self?.listenerDied(generation: generation, reason: error.localizedDescription) }
            case .cancelled:
                Task { await self?.listenerDied(generation: generation, reason: "cancelled") }
            case let .waiting(error):
                // Not terminal — the framework retries on its own — but worth
                // recording. A listener that waits forever is indistinguishable
                // from a working one until the phone fails to find it.
                Task { await self?.noteListenerWaiting(generation: generation, reason: error.localizedDescription) }
            default:
                break
            }
        }

        listener.start(queue: queue)
        self.listener = listener
        log.error("listening as '\(self.deviceName, privacy: .public)' sessionKeys=\(sessionKeys.count, privacy: .public) pairingCode=\(pairingKey != nil, privacy: .public)")
    }

    /// A listener reached a terminal state. Rebuild if it was the current one.
    ///
    /// Previously this only emitted `.failed` and nothing acted on the event,
    /// so a dead listener stayed dead until the user restarted the app.
    private func listenerDied(generation: Int, reason: String) async {
        guard generation == listenerGeneration else { return }  // already replaced
        // `stop()` cancels the listener and nils it, and cancelling is exactly
        // what `.cancelled` reports — so without this a deliberate shutdown
        // reads as a death and puts the Mac straight back on the air. The host
        // then cannot be stopped: the advertisement and the bound socket
        // outlive the user quitting.
        guard listener != nil else { return }
        log.error("listener died (\(reason, privacy: .public)) — rebuilding")
        emit(.failed(reason))
        await rebuildAdvertisement(because: "listener \(reason)")
    }

    private func noteListenerWaiting(generation: Int, reason: String) {
        guard generation == listenerGeneration else { return }
        log.error("listener waiting: \(reason, privacy: .public)")
    }

    // MARK: Path awareness

    private func startPathMonitoring() {
        guard monitorsPath, pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let signature = PathSignature(path: path)
            Task { await self?.pathChanged(signature) }
        }
        monitor.start(queue: queue)
        pathMonitor = monitor
    }

    /// Debounced so one Wi-Fi disconnect produces one re-advertisement.
    func pathChanged(_ signature: PathSignature) {
        guard signature != lastPathSignature else { return }
        let previous = lastPathSignature
        lastPathSignature = signature

        // The first observation is what the listener was already built for.
        guard previous != nil else { return }

        log.error("network path changed: \(String(describing: previous), privacy: .public) -> \(signature.description, privacy: .public)")
        pathDebounceTask?.cancel()
        pathDebounceTask = Task { [pathDebounce] in
            try? await Task.sleep(for: pathDebounce)
            guard !Task.isCancelled else { return }
            await self.rebuildAdvertisement(because: "path \(signature.description)")
        }
    }

    /// Puts this Mac back on the air.
    ///
    /// The listener itself may well still be fine; the thing that has to be
    /// re-issued is the Bonjour advertisement, and there is no API to refresh
    /// one in place. `restartListener` already handles the port churn and
    /// `awaitListening` already waits for the rebind.
    ///
    /// Note this does NOT disturb a live session: an accepted `NWConnection` is
    /// independent of the listener that produced it.
    private func rebuildAdvertisement(because reason: String) async {
        do {
            try restartListener()
            await awaitListening()
            log.error("re-advertised after \(reason, privacy: .public)")
        } catch {
            log.error("could not re-advertise after \(reason, privacy: .public): \(String(describing: error), privacy: .public)")
            emit(.failed("re-advertise failed: \(error)"))
        }
    }

    // MARK: Accepting

    private func accept(_ connection: NWConnection) async {
        log.error("accept: inbound connection from \(String(describing: connection.endpoint), privacy: .public)")
        let channel = NWConnectionChannel(connection: connection)
        do {
            // A wrong pairing code, or an unpaired phone, fails the TLS
            // handshake here — before a single byte of ours is exposed.
            try await channel.start(on: queue)

            // The first frame says what this connection is for.
            var decoder = FrameDecoder()
            var first: Frame?
            while first == nil {
                guard let bytes = try await channel.receive() else {
                    throw ChannelError.peerClosed
                }
                decoder.append(bytes)
                first = try decoder.next()
            }
            guard let first else { throw ChannelError.peerClosed }

            log.error("accept: TLS ok, first frame = \(String(describing: first.kind), privacy: .public)")
            switch first.kind {
            case .pairRequest:
                try await handlePairing(first, on: channel)
            case .hello:
                try await handleSession(first, on: channel, decoder: decoder, connection: connection)
            default:
                throw ChannelError.handshakeFailed("unexpected first frame \(first.kind)")
            }
        } catch {
            // Tell the peer WHY, when we are the only side that can know.
            //
            // A wrong code fails earlier, inside TLS, and never reaches here. So
            // a `PairingError` at this point means the code was right and the
            // session refused it — expired, exhausted, or already used. Closing
            // silently, which is all this used to do, left the phone reporting a
            // generic `handshakeFailed`; `.expired`, `.tooManyAttempts` and
            // `.alreadyConsumed` were values nothing could produce, with good
            // messages that could never be shown.
            //
            // Best effort, and deliberately before the close: if the write
            // fails the peer is already gone.
            if let refusal = error as? PairingError {
                try? await channel.send(FrameEncoder.encode(Multiplexer.pairFailureFrame(refusal)))
                log.error("accept: pairing REFUSED — \(String(describing: refusal), privacy: .public)")
            } else {
                log.error("accept: REJECTED \(String(describing: error), privacy: .public)")
            }
            await channel.close()
        }
    }

    private func handlePairing(_ request: Frame, on channel: FrameChannel) async throws {
        // The TLS handshake already proved the peer holds the code, but the
        // attempt still has to be booked against the session so that expiry,
        // the three-attempt limit, and single use all apply.
        guard var session = pairingSession, let code = pairingCode else {
            log.error("pairing: no active code on this Mac — was 'Show Pairing Code' used?")
            throw PairingError.expired
        }
        // On refusal, persist the attempt so the three-guess lockout actually
        // counts. On success, do NOT persist yet — see below.
        do {
            try session.verify(code, at: Date())
        } catch {
            pairingSession = session
            throw error
        }

        // Commit our own side BEFORE telling the phone it is paired, and burn
        // the code only once both have happened.
        //
        // The old order — verify, persist the consumption, answer, then save —
        // failed in two ways at once when the save went wrong: the phone had
        // already been told it was paired and stored the Mac, while the Mac
        // stored nothing; and the code was spent, so the user was sent for a
        // fresh one to fix a one-sided pairing they could not see.
        let responder = PairingResponder(deviceName: deviceName)
        let device = try responder.identify(request)
        try store.save(device)
        try await responder.confirm(on: channel, localIdentity: identity)

        pairingSession = session
        // A device that has just paired is not revoked, whatever its history.
        // Without this it would be told "unpaired" the moment it connects.
        tombstones.reinstated(device.fingerprint)
        log.error("paired with \(device.name, privacy: .public) fp=\(device.fingerprint, privacy: .public)")

        // Consume the code and rebuild the listener so the new phone's session
        // PSK is live and the pairing PSK is gone.
        try await setPairingCode(nil)
        emit(.paired(device))

        await channel.close()
    }

    /// Fingerprint of the session currently believed live, so teardown can
    /// report which one ended and can be made idempotent.
    /// Which phone the live session is with, or nil.
    ///
    /// Readable so a caller can tell "unpair the device I am bridging with"
    /// from "unpair one that is not here" — they need different handling, and
    /// getting it wrong is how a revocation goes undelivered.
    public private(set) var activeFingerprint: String?

    private func handleSession(
        _ hello: Frame,
        on channel: FrameChannel,
        decoder: FrameDecoder,
        connection: NWConnection
    ) async throws {
        // Only one phone bridges at a time; a second would be ambiguous about
        // whose cellular plan the Mac is using.
        sessionTask?.cancel()

        let initiator = BridgeInitiator(channel: channel)
        self.initiator = initiator

        let description = Self.describe(connection.currentPath?.remoteEndpoint ?? connection.endpoint)
        self.peerDescription = description

        // Which phone this is, taken from the identity it announced in HELLO
        // rather than guessed from the paired list — several phones may be
        // paired with this Mac.
        let fingerprint = Self.identity(inHello: hello) ?? "unknown"

        // A tombstone's ONE job, and it must happen before anything else: this
        // device was unpaired while it was not connected, so it has never been
        // told. Tell it now and close. Deliberately ahead of
        // `emit(.sessionStarted)` and of every piece of session state — a
        // tombstone that could carry traffic would be a revoked device still
        // bridging, which is the opposite of what revoking it meant.
        if tombstones.isRevoked(fingerprint) {
            log.error("revoked device \(fingerprint, privacy: .public) connected — delivering the unpair notice and closing")
            try? await channel.send(FrameEncoder.encode(Multiplexer.unpairedFrame()))
            tombstones.delivered(fingerprint)
            await channel.close()
            try? restartListener()
            await awaitListening()
            return
        }

        activeFingerprint = fingerprint
        // The session's own socket now keeps AWDL scheduled; ours would be
        // redundant airtime.
        await presence.release()
        emit(.sessionStarted(fingerprint: fingerprint, peerDescription: description))

        let token = await initiator.onEgressChange { [weak self] interface in
            Task { await self?.emit(.egressObserved(interface)) }
        }

        // The phone forgetting this Mac has to be acted on, not just noticed.
        // Keeping the record would leave the Mac advertising a PSK for a device
        // that has revoked it, and showing a paired phone the user removed.
        _ = await initiator.onUnpairedByPeer { [weak self] in
            Task { await self?.peerUnpaired(fingerprint: fingerprint) }
        }

        sessionTask = Task { [weak self] in
            do {
                try await initiator.run(resuming: hello, decoder: decoder)
            } catch {
                await self?.emit(.failed(String(describing: error)))
            }
            await initiator.removeEgressObserver(token)
            await self?.sessionFinished(fingerprint: fingerprint, channel: channel)
        }
    }

    /// Ends a session and releases the connection behind it.
    ///
    /// Closing the channel is not tidiness. A live session's `NWConnection` was
    /// never cancelled — `close()` is called on the accept-error and pairing
    /// paths only — so a session that ended left the socket open. Cancelling it
    /// is also what makes the PHONE notice: its `ReconnectPolicy` loop in
    /// `PacketTunnelProvider.runSession` turns on `connectOnce` returning, which
    /// happens when its own receive completes. Without this the phone can sit
    /// believing it is still bridging for a Mac that has moved on.
    private func sessionFinished(fingerprint: String, channel: FrameChannel?) async {
        guard activeFingerprint != nil else { return }   // already ended
        activeFingerprint = nil
        initiator = nil
        let lastPeer = peerDescription
        peerDescription = nil
        await channel?.close()

        // Take the hold BEFORE announcing the end, so there is no window in
        // which nothing is keeping AWDL scheduled. Without it the kernel drops
        // to Low Power, mDNS stops transmitting on awdl0 — measured silence of
        // 102 seconds — and the phone cannot find the Mac to dial it, which is
        // what kept the schedule down in the first place.
        if let lastPeer {
            await presence.hold(peerDescription: lastPeer)
        }
        emit(.sessionEnded(fingerprint: fingerprint))
    }

    /// Ends the live session without taking the Mac off the air.
    ///
    /// `stop()` cancels the listener and the path monitor, so using it to end a
    /// session left the Mac unable to re-advertise — and re-pairing then needed
    /// an app restart.
    public func endSession() async {
        guard let fingerprint = activeFingerprint else { return }
        await sessionFinished(fingerprint: fingerprint, channel: nil)
    }

    /// Records a device unpaired while it was not connected, so it is told the
    /// next time it appears.
    public func revoke(_ device: PairedDevice) async {
        tombstones.revoke(device)
        log.error("tombstoned \(device.name, privacy: .public) — will tell it when it next connects")
        try? restartListener()
        await awaitListening()
    }

    /// A device that has paired again is no longer revoked.
    public func reinstate(_ fingerprint: String) {
        tombstones.reinstated(fingerprint)
    }

    /// Seeds tombstones recorded before this process started.
    public func restoreTombstones(_ restored: RevocationTombstones) {
        tombstones = restored
        tombstones.expire()
    }

    public var currentTombstones: RevocationTombstones { tombstones }

    /// The phone has removed this Mac. Drop our half of the pairing.
    private func peerUnpaired(fingerprint: String) async {
        log.error("peer \(fingerprint, privacy: .public) unpaired us — forgetting it")
        try? store.remove(fingerprint: fingerprint)
        emit(.peerUnpaired(fingerprint: fingerprint))
        // Rebuild so the listener stops offering the revoked key, and do not
        // hold AWDL open for a device that has gone.
        await presence.release()
        await sessionFinished(fingerprint: fingerprint, channel: nil)
        try? restartListener()
        await awaitListening()
    }

    /// Pulls the sender's fingerprint out of a HELLO payload.
    private static func identity(inHello frame: Frame) -> String? {
        let payload = frame.payload
        guard payload.count >= 3 else { return nil }
        let base = payload.startIndex
        let length = Int(payload[base + 2])
        guard payload.count >= 3 + length, length > 0 else { return nil }
        return String(bytes: payload[(base + 3) ..< (base + 3 + length)], encoding: .utf8)
    }

    private static func describe(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case let .hostPort(host, port): "\(host):\(port)"
        default: "\(endpoint)"
        }
    }
}

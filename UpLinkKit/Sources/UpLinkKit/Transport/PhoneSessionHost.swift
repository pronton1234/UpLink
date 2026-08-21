import Foundation
import Network
import CryptoKit
import OSLog

public enum SessionHostEvent: Sendable {
    case paired(PairedDevice)
    case sessionStarted(fingerprint: String, peerDescription: String)
    case sessionEnded(fingerprint: String)
    case egressObserved(EgressInterface)
    /// The Mac removed this pairing from its side.
    case peerUnpaired(fingerprint: String)
    case failed(String)
}

/// The phone's always-on side of the bridge.
///
/// **The phone listens now.** `usbmuxd` carries connections in one direction
/// only — the Mac dials a port on the device — so the roles that held over AWDL
/// are reversed: the phone binds a loopback port, and the Mac's menu-bar app
/// pumps the cable into it. Everything above the byte pipe is unchanged.
///
/// One listener serves both purposes. Each paired Mac contributes a TLS-PSK
/// keyed by that Mac's fingerprint, and while the user has typed a pairing code
/// the code contributes one more. TLS selects by the identity the client
/// offers, so there is no second port to keep in sync.
///
/// This runs inside the packet-tunnel extension rather than the app, so it
/// survives the phone being locked and the app being backgrounded — the whole
/// reason that extension exists, since it routes nothing itself.
public actor PhoneSessionHost {

    private let log = Logger(subsystem: UpLinkIdentifiers.logSubsystem, category: "host")

    private let identity: Curve25519.KeyAgreement.PrivateKey
    private let deviceName: String
    private let store: DeviceDirectory
    private let queue: DispatchQueue
    private let dialer: DestinationDialer
    private let port: UInt16
    /// Which link the Mac will reach this listener over. Decides whether the
    /// bind is pinned to loopback; see ``TransportParameters/listener(sessionKeys:pairingKey:port:bearer:)``.
    private let bearer: WirelessBearer
    /// Durable home for tombstones. Nil in tests, which have no app group.
    private let tombstoneStore: TombstoneStore?

    private var listener: NWListener?
    private var pairingSession: PairingSession?
    private var pairingCode: PairingCode?

    /// The live session's responder. Nil whenever no Mac is connected.
    public private(set) var responder: BridgeResponder?

    public private(set) var peerDescription: String?

    /// The live session's channel, retained so it can actually be closed.
    ///
    /// Cancelling `sessionTask` does not end a session: it is parked in
    /// `channel.receive()`, which suspends on a continuation only a network
    /// callback resumes. Closing the channel is the only thing that ends it.
    private var activeChannel: FrameChannel?

    /// Bumped per accepted session, so a dying one cannot clear the state of
    /// the one that replaced it.
    private var sessionGeneration = 0

    private var sessionTask: Task<Void, Never>?
    /// Retries a listener rebuild that threw. See ``rebuildListener``.
    private var rebuildTask: Task<Void, Never>?
    /// Identifies the retry that owns ``rebuildTask``.
    private var rebuildToken: UUID?
    private var continuations: [UUID: AsyncStream<SessionHostEvent>.Continuation] = [:]

    /// Macs unpaired while they were not connected, kept reachable only long
    /// enough to be told. See ``RevocationTombstones``.
    private var tombstones = RevocationTombstones()

    /// How many listeners have been built. The only observable proof from
    /// outside that a rebuild happened rather than being swallowed — and the
    /// guard that stops `restartListener`'s own `cancel()` from being mistaken
    /// for a failure worth rebuilding for.
    public private(set) var listenerGeneration = 0

    public init(
        identity: Curve25519.KeyAgreement.PrivateKey,
        deviceName: String,
        store: DeviceDirectory,
        dialer: DestinationDialer,
        queue: DispatchQueue,
        port: UInt16 = UpLinkUSB.extensionPort,
        tombstoneStore: TombstoneStore? = nil,
        bearer: WirelessBearer = .usbmux
    ) {
        self.identity = identity
        self.deviceName = deviceName
        self.store = store
        self.dialer = dialer
        self.queue = queue
        self.port = port
        self.tombstoneStore = tombstoneStore
        self.bearer = bearer
        if let tombstoneStore {
            tombstones = tombstoneStore.load()
        }
    }

    public var fingerprint: String {
        PairedDevice.fingerprint(of: identity.publicKey.rawRepresentation)
    }

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
    }

    public func stop() {
        rebuildTask?.cancel()
        rebuildTask = nil
        rebuildToken = nil
        sessionTask?.cancel()
        sessionTask = nil
        listener?.cancel()
        listener = nil
        // Emit the end rather than clearing state silently. Tearing the host
        // down without `.sessionEnded` leaves every consumer believing a
        // session is still live, which is the same class of lie this whole
        // change exists to remove.
        if let fingerprint = activeFingerprint {
            let channel = activeChannel
            let generation = sessionGeneration
            Task {
                await sessionFinished(
                    fingerprint: fingerprint, channel: channel, generation: generation
                )
            }
        } else {
            responder = nil
            peerDescription = nil
            activeChannel = nil
        }
    }

    /// Arms the listener with a pairing code, or disarms it.
    ///
    /// The user reads the six digits off the Mac and types them here; that is
    /// what puts the pairing PSK into the TLS options, so the Mac's dial can
    /// succeed. Rebuilds the listener, which is cheap and happens at most twice
    /// per pairing.
    public func setPairingCode(_ code: PairingCode?, now: Date = Date()) async throws {
        pairingCode = code
        pairingSession = code.map { PairingSession(code: $0, issuedAt: now) }
        try restartListener()
        await awaitListening()
    }

    /// Waits until the new listener has actually bound.
    ///
    /// Unlike the old Bonjour listener, the port is FIXED — the Mac has to know
    /// where to dial — so a rebuild must genuinely rebind the same number
    /// rather than drifting to a fresh ephemeral one. `allowLocalEndpointReuse`
    /// is what makes that possible while the previous socket drains.
    private func awaitListening() async {
        for _ in 0 ..< 300 {
            if let bound = listener?.port, bound.rawValue != 0 { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        log.error("listener did not bind port \(self.port, privacy: .public) within 3s")
    }

    private func restartListener() throws {
        // Generation bumped and the reference cleared BEFORE the old listener
        // is cancelled, not after the new one is built.
        //
        // The old order had a trap: if `NWListener(using:)` threw, the cancelled
        // listener's `.cancelled` fired while `listenerGeneration` still matched
        // and `self.listener` still pointed at it — so `listenerDied` tried a
        // rebuild, which threw again, and the catch only logged. Nothing
        // retried, `self.listener` was a corpse, and `listeningPort` reported a
        // port nothing was bound to. The phone was off the air for good, with
        // no error anywhere saying so.
        listenerGeneration += 1
        let generation = listenerGeneration
        let outgoing = listener
        listener = nil
        outgoing?.cancel()

        let paired = (try? store.pairedDevices()) ?? []

        // Revoked Macs keep a PSK so they can connect ONCE and be told. They
        // are refused a session in `handleSession`; without the key they could
        // not reach us at all, and the notice could never be delivered.
        tombstones.expire()
        let reachable = paired + tombstones.devicesToKeepOnAir()

        let sessionKeys: [(identity: String, key: SymmetricKey)] = reachable.compactMap { device in
            guard let key = try? self.sessionKey(for: device) else {
                // A device whose stored public key will not parse becomes a Mac
                // that can never connect. Silently dropping it is how that
                // turns into an unexplainable failure on the other end.
                log.error("paired Mac \(device.name, privacy: .public) fp=\(device.fingerprint, privacy: .public) has an unusable public key — it cannot connect")
                return nil
            }
            return (device.fingerprint, key)
        }

        var pairingKey: (identity: String, key: SymmetricKey)?
        if let pairingCode {
            pairingKey = (
                TransportParameters.pairingIdentity,
                KeySchedule.pairingKey(code: pairingCode, salt: UpLinkPairing.salt)
            )
        }

        let parameters = TransportParameters.listener(
            sessionKeys: sessionKeys,
            pairingKey: pairingKey,
            port: port,
            bearer: bearer
        )

        // THE PORT HAS TO BE SAID OUT LOUD HERE.
        //
        // Over the cable it arrived inside `requiredLocalEndpoint`, which
        // carried two things at once: bind to loopback, and bind to THIS port.
        // Dropping that endpoint for the wireless bearer — which was right, it
        // is what made the listener unreachable from the network the Mac hosts
        // — took the port with it, and `NWListener(using:)` with no port picks
        // an ephemeral one.
        //
        // The result was a listener that came up perfectly, on a port nobody
        // was dialling: the Mac dialled 50505 and got "no connection within
        // 12s" for as long as anyone cared to watch, with both sides healthy.
        let listener = try bearer == .usbmux
            ? NWListener(using: parameters)
            : NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)

        // The phone announces itself and the Mac browses. Over the cable this
        // was usbmuxd's job — the Mac dialled a fixed loopback port and the
        // daemon did the finding. On a shared link the phone holds a DHCP
        // address nothing else knows, so nothing can find it unless it says so.
        //
        // A mismatch in the service type is silent on both sides: the Mac
        // simply never finds a phone that is advertising perfectly happily,
        // which is why the name is a single constant in UpLinkIdentifiers.
        if bearer != .usbmux {
            listener.service = NWListener.Service(
                name: deviceName, type: UpLinkIdentifiers.bonjourServiceType
            )
        }

        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        // Generation-stamped, because `restartListener` cancels the outgoing
        // listener and that fires `.cancelled` on it. Without the stamp, a
        // rebuild triggers a rebuild triggers a rebuild.
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case let .failed(error):
                Task { await self?.listenerDied(generation: generation, reason: error.localizedDescription) }
            case .cancelled:
                Task { await self?.listenerDied(generation: generation, reason: "cancelled") }
            case let .waiting(error):
                Task { await self?.noteListenerWaiting(generation: generation, reason: error.localizedDescription) }
            default:
                break
            }
        }

        listener.start(queue: queue)
        self.listener = listener
        log.error("listening on 127.0.0.1:\(self.port, privacy: .public) as '\(self.deviceName, privacy: .public)' sessionKeys=\(sessionKeys.count, privacy: .public) pairingCode=\(pairingKey != nil, privacy: .public)")
    }

    /// The long-term key shared with one paired Mac.
    ///
    /// Context is this phone's own fingerprint on both ends — the Mac passes
    /// the same string from its paired record — so the derivation is identical
    /// without either side having to learn anything new at connect time.
    private func sessionKey(for device: PairedDevice) throws -> SymmetricKey {
        let remote = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: device.publicKey)
        return try KeySchedule.sessionKey(
            localPrivate: identity,
            remotePublic: remote,
            context: Data(fingerprint.utf8)
        )
    }

    private func listenerDied(generation: Int, reason: String) async {
        guard generation == listenerGeneration else { return }  // already replaced
        // `stop()` cancels the listener and nils it, and cancelling is exactly
        // what `.cancelled` reports — so without this a deliberate shutdown
        // reads as a death and puts the phone straight back on the air.
        guard listener != nil else { return }
        log.error("listener died (\(reason, privacy: .public)) — rebuilding")
        emit(.failed(reason))
        await rebuildListener(because: "listener \(reason)")
    }

    private func noteListenerWaiting(generation: Int, reason: String) {
        guard generation == listenerGeneration else { return }
        log.error("listener waiting: \(reason, privacy: .public)")
    }

    /// Rebuilds, and keeps trying if it cannot.
    ///
    /// The `catch` used to only log. A rebuild is triggered from `revoke`,
    /// `rebuildAfterRemoval`, `peerUnpaired` and the end of pairing, so a throw
    /// on any of those paths left `listener == nil` with nothing scheduled to
    /// try again — the phone silently off the air for good, which is the worst
    /// failure this type has because every symptom points at the Mac.
    private func rebuildListener(because reason: String) async {
        rebuildTask?.cancel()
        rebuildToken = nil
        do {
            try restartListener()
            await awaitListening()
            log.error("rebuilt listener after \(reason, privacy: .public)")
        } catch {
            log.error("could not rebuild listener after \(reason, privacy: .public): \(String(describing: error), privacy: .public)")
            emit(.failed("listener rebuild failed: \(error)"))
            scheduleRebuildRetry(because: reason)
        }
    }

    /// - Note: stamped with the retry's own token.
    ///
    ///   Cancellation cannot interrupt `retryRestart` once it is past the
    ///   sleep — `restartListener` is synchronous and `awaitListening`'s
    ///   `try? await Task.sleep` degrades under cancellation to a fast spin
    ///   rather than returning. So a cancelled retry still runs to completion
    ///   and still clears `rebuildTask`. If a concurrent `rebuildListener` had
    ///   installed a NEW retry in that property, the stale one nilled it: the
    ///   new task kept running with nobody holding it, `stop()` could no longer
    ///   cancel it, and it rebuilt the listener every ten seconds for the life
    ///   of the process. The token is what makes "still mine?" answerable.
    private func scheduleRebuildRetry(because reason: String) {
        let token = UUID()
        rebuildToken = token
        rebuildTask = Task { [weak self] in
            var policy = ReconnectPolicy(baseDelay: 0.5, maxDelay: 10)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(policy.recordFailure()))
                guard !Task.isCancelled, let self else { return }
                if await self.retryRestart(because: reason, token: token) { return }
                guard await self.ownsRebuild(token) else { return }
            }
        }
    }

    private func ownsRebuild(_ token: UUID) -> Bool { rebuildToken == token }

    /// One retry. Returns whether the listener is back.
    private func retryRestart(because reason: String, token: UUID) async -> Bool {
        // Superseded while we were asleep: leave the current owner alone.
        guard rebuildToken == token else { return true }
        do {
            try restartListener()
            await awaitListening()
            log.error("listener recovered after \(reason, privacy: .public)")
            // Only if it is still ours.
            if rebuildToken == token {
                rebuildTask = nil
                rebuildToken = nil
            }
            return true
        } catch {
            log.error("listener still down after \(reason, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
    }

    // MARK: Accepting

    private func accept(_ connection: NWConnection) async {
        log.error("accept: inbound connection from \(String(describing: connection.endpoint), privacy: .public)")
        let channel = NWConnectionChannel(connection: connection)
        do {
            // A wrong pairing code, or an unpaired Mac, fails the TLS handshake
            // here — before a single byte of ours is exposed.
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
            // session refused it — expired, exhausted, or already used.
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
            log.error("pairing: no code armed on this phone — was the code typed in?")
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

        // Commit our own side BEFORE telling the Mac it is paired, and burn the
        // code only once both have happened. The old order left the peer
        // believing it was paired while this side had stored nothing, and spent
        // the code fixing a one-sided pairing the user could not see.
        let responder = PairingResponder(deviceName: deviceName)
        let device = try responder.identify(request)
        try store.save(device)

        // A device that has just paired is not revoked, whatever its history.
        // Without this it would be told "unpaired" the moment it connects, and
        // a re-pair could never stick.
        tombstones.reinstated(device.fingerprint)
        persistTombstones()

        // Confirm BEFORE rebuilding, and the order is not free to change:
        // `restartListener` cancels the listener this connection was accepted
        // from, so rebuilding first means the confirmation can never be
        // written. That was measured as a test that hung rather than failed.
        try await responder.confirm(on: channel, localIdentity: identity)

        pairingSession = session
        log.error("paired with \(device.name, privacy: .public) fp=\(device.fingerprint, privacy: .public)")

        // Rebuild so the new Mac's session PSK is live and the pairing PSK is
        // gone. The Mac redials on the same fixed port.
        try await setPairingCode(nil)
        emit(.paired(device))

        await channel.close()
    }

    /// Which Mac the live session is with, or nil.
    public private(set) var activeFingerprint: String?

    private func handleSession(
        _ hello: Frame,
        on channel: FrameChannel,
        decoder: FrameDecoder,
        connection: NWConnection
    ) async throws {
        let description = Self.describe(connection.currentPath?.remoteEndpoint ?? connection.endpoint)

        // Which Mac this is, taken from the identity it announced in HELLO.
        // The claim is verified against the session key below, so by the time
        // anything acts on it, it has been proven rather than believed.
        guard let fingerprint = Self.identity(inHello: hello) else {
            log.error("session REFUSED: HELLO carried no usable fingerprint")
            await channel.close()
            return
        }

        // Includes revoked devices, whose records are gone from the store but
        // whose keys are still on the air so they can be told. The proof below
        // has to be checkable against them too, or the tombstone branch acts on
        // an unverified claim — and burning a notice on a forged fingerprint
        // means the real Mac is never told at all.
        let known = ((try? store.pairedDevices()) ?? []) + tombstones.devicesToKeepOnAir()
        let device = known.first { $0.fingerprint == fingerprint }
        guard device != nil else {
            log.error("session REFUSED: peer claims fp=\(fingerprint, privacy: .public), which this phone holds no key for")
            await channel.close()
            return
        }

        // A tombstone's ONE job, and it must happen before anything else: this
        // Mac was unpaired while it was not connected, so it has never been
        // told. Tell it now and close. Deliberately ahead of every piece of
        // session state — a tombstone that could carry traffic would be a
        // revoked device still bridging.
        // Verified BEFORE the tombstone branch, not just before a session.
        let ourFingerprint = PairedDevice.fingerprint(of: identity.publicKey.rawRepresentation)
        let helloProof = Self.proof(inHello: hello)
        guard verifyHelloSynchronously(
            claimed: fingerprint, proof: helloProof, among: known, listener: ourFingerprint
        ) else {
            log.error("session REFUSED: peer announced fp=\(fingerprint, privacy: .public) without holding that identity's key")
            await channel.close()
            return
        }

        if tombstones.isRevoked(fingerprint) {
            log.error("revoked Mac \(fingerprint, privacy: .public) connected — delivering the unpair notice and closing")
            try? await channel.send(FrameEncoder.encode(Multiplexer.unpairedFrame()))
            tombstones.delivered(fingerprint)
            persistTombstones()
            await channel.close()
            await rebuildListener(because: "tombstone delivered to \(fingerprint)")
            return
        }

        // Bind the announced identity to the key it claims to hold.
        //
        // TLS proved the peer holds SOME PSK this phone offered; it did not
        // prove WHICH, and nothing else cross-checks the two. Without this a
        // paired Mac could announce another paired Mac's fingerprint and have
        // an `unpair` sent over the session applied to that other Mac. See
        // ``HelloProof`` for why this is done here rather than in the TLS layer.
        // CLAIM THE SLOT SYNCHRONOUSLY, THEN CLOSE THE OLD ONE.
        //
        // `accept` runs one task per connection, so two `handleSession` calls
        // can be in flight at once. Awaiting the supersede first left a window:
        // A clears the state and suspends closing its channel; B finds
        // `activeFingerprint` already nil, returns from supersede without
        // awaiting, installs itself; A resumes and overwrites B. B's channel is
        // then orphaned — never closed, responder still pumping, invisible to
        // `endSession` — which is two Macs proxying at once, the exact thing
        // superseding exists to prevent.
        //
        // Taking the generation and the state first makes the claim atomic
        // within the actor: there is no suspension between reading the old
        // session and owning the new one.
        let superseded = (fingerprint: activeFingerprint, channel: activeChannel)
        sessionGeneration += 1
        let generation = sessionGeneration
        self.activeChannel = channel
        self.peerDescription = description
        activeFingerprint = fingerprint

        // Cancelled here, not before the checks above: a refused connection
        // would otherwise have torn down the live session's task on its way out.
        sessionTask?.cancel()

        if let previous = superseded.fingerprint {
            log.error("superseding the live session with \(previous, privacy: .public)")
            emit(.sessionEnded(fingerprint: previous))
            // Closed WITHOUT awaiting, in a detached task.
            //
            // Awaiting here suspended the install, and a suspension in the
            // middle of installing a session is the whole problem: two
            // concurrent accepts both got past the claim and then interleaved
            // their `responder`, `sessionStarted` and `sessionTask` writes, so
            // the live session ended up holding a DEAD responder. Everything
            // below this point must run in one go.
            if let channel = superseded.channel {
                Task { await channel.close() }
            }
        }

        let responder = BridgeResponder(
            channel: channel,
            dialer: dialer,
            localFingerprint: ourFingerprint,
            // Re-checked in the frame loop too. Cheap, and it keeps the
            // guarantee local to the mux rather than resting on a caller
            // having done it first.
            verifyHello: { [weak self] claimed, proof in
                guard let self else { return false }
                return self.verifyHelloSynchronously(
                    claimed: claimed, proof: proof, among: known, listener: ourFingerprint
                )
            },
            // The Mac forgetting this phone has to be acted on, not just
            // noticed. Passed at construction rather than registered after,
            // because registering costs an `await` — see above.
            //
            // The generation travels with it: the observer belongs to THIS
            // session and fires through an unstructured Task, so it can land
            // after a later session has installed, and "whatever is current"
            // would tear down the wrong one.
            onUnpaired: { [weak self] in
                Task { await self?.peerUnpaired(fingerprint: fingerprint, generation: generation) }
            }
        )

        self.responder = responder
        emit(.sessionStarted(fingerprint: fingerprint, peerDescription: description))

        sessionTask = Task { [weak self] in
            do {
                try await responder.run(resuming: hello, decoder: decoder)
            } catch {
                await self?.emit(.failed(String(describing: error)))
            }
            await self?.sessionFinished(
                fingerprint: fingerprint, channel: channel, generation: generation
            )
        }
    }

    /// Pulls the proof out of a HELLO payload: everything after the identity.
    private static func proof(inHello frame: Frame) -> Data {
        let payload = frame.payload
        guard payload.count >= 3 else { return Data() }
        let base = payload.startIndex
        let length = Int(payload[base + 2])
        guard payload.count >= 3 + length else { return Data() }
        return Data(payload[(base + 3 + length)...])
    }

    /// Derives the peer's session key and checks the proof.
    ///
    /// `nonisolated` and synchronous because it is called from inside the
    /// responder's frame loop, which must not re-enter this actor mid-handshake.
    /// Everything it needs is passed in.
    private nonisolated func verifyHelloSynchronously(
        claimed: String,
        proof: Data,
        among known: [PairedDevice],
        listener: String
    ) -> Bool {
        guard let device = known.first(where: { $0.fingerprint == claimed }),
              let remote = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: device.publicKey),
              let key = try? KeySchedule.sessionKey(
                  localPrivate: identity, remotePublic: remote, context: Data(listener.utf8)
              )
        else { return false }
        return HelloProof.verify(
            proof, sessionKey: key, dialerFingerprint: claimed, listenerFingerprint: listener
        )
    }


    /// Ends a session and releases the connection behind it.
    ///
    /// Closing the channel is not tidiness: it is what makes the MAC notice.
    /// Its reconnect loop turns on the dial returning, which happens when its
    /// own receive completes. Without this the Mac can sit believing it is
    /// still bridging through a phone that has moved on.
    /// - Parameter generation: which session this call belongs to. A dying
    ///   session must not clear the state of the one that replaced it — and it
    ///   would, without this: the old task's tail runs after the new session
    ///   has installed itself, sees a non-nil `activeFingerprint`, and wipes
    ///   it. The new session then keeps carrying traffic while `status()`
    ///   reports "disconnected" and `unpair` tombstones a Mac that is bridging
    ///   right now.
    private func sessionFinished(
        fingerprint: String,
        channel: FrameChannel?,
        generation: Int
    ) async {
        guard activeFingerprint != nil else { return }        // already ended
        guard generation == sessionGeneration else { return } // superseded
        activeFingerprint = nil
        responder = nil
        peerDescription = nil
        activeChannel = nil
        await channel?.close()
        emit(.sessionEnded(fingerprint: fingerprint))
    }

    /// Ends the live session without taking the phone off the air.
    public func endSession() async {
        guard let fingerprint = activeFingerprint else { return }
        // The channel, NOT nil. Clearing this side's state while leaving the
        // socket open leaves `BridgeResponder` pumping: it goes on dialling
        // destinations and proxying for a Mac the user has just removed.
        await sessionFinished(
            fingerprint: fingerprint, channel: activeChannel, generation: sessionGeneration
        )
    }

    public func revoke(_ device: PairedDevice) async {
        tombstones.revoke(device)
        persistTombstones()
        log.error("tombstoned \(device.name, privacy: .public) — will tell it when it next connects")
        await rebuildListener(because: "revoked \(device.fingerprint)")
    }

    /// Stops offering a removed Mac's key.
    ///
    /// The key set is read once, when the listener is built, so removing a
    /// device from the store is not enough on its own — without a rebuild the
    /// listener goes on completing TLS for a pairing the user has deleted.
    public func rebuildAfterRemoval(of fingerprint: String) async {
        await rebuildListener(because: "removed \(fingerprint)")
    }

    /// Written on every change, because a restart is exactly when a revoked
    /// Mac would otherwise come back to life: the set is in memory, and the
    /// extension is relaunched far more often than the pairing changes.
    private func persistTombstones() {
        tombstoneStore?.save(tombstones)
    }

    /// Announces that this phone has forgotten the connected Mac, then ends
    /// the session.
    public func announceUnpaired() async {
        guard let responder else { return }
        await responder.announceUnpaired()
    }

    /// The Mac has removed this phone. Drop our half of the pairing.
    private func peerUnpaired(fingerprint: String, generation: Int) async {
        // Forgetting the pairing is unconditional — the peer said so, and that
        // is true whichever session is live now.
        log.error("peer \(fingerprint, privacy: .public) unpaired us — forgetting it")
        try? store.remove(fingerprint: fingerprint)
        emit(.peerUnpaired(fingerprint: fingerprint))
        // Tearing down is NOT. This can land after a later session installed,
        // and `sessionFinished` refuses a stale generation rather than closing
        // the new session's channel.
        await sessionFinished(
            fingerprint: fingerprint,
            channel: generation == sessionGeneration ? activeChannel : nil,
            generation: generation
        )
        await rebuildListener(because: "peer \(fingerprint) unpaired us")
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

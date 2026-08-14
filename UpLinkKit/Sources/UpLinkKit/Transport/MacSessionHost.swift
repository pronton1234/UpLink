import Foundation
import Network
import CryptoKit
import OSLog

public enum SessionHostEvent: Sendable {
    case paired(PairedDevice)
    case sessionStarted(fingerprint: String, peerDescription: String)
    case sessionEnded(fingerprint: String)
    case egressObserved(EgressInterface)
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

    public init(
        identity: Curve25519.KeyAgreement.PrivateKey,
        deviceName: String,
        store: DeviceDirectory,
        queue: DispatchQueue,
        profile: TransportProfile = TransportProfile.preferenceOrder.first ?? .localLink
    ) {
        self.identity = identity
        self.deviceName = deviceName
        self.store = store
        self.queue = queue
        self.profile = profile
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
    }

    public func stop() {
        sessionTask?.cancel()
        sessionTask = nil
        listener?.cancel()
        listener = nil
        initiator = nil
        peerDescription = nil
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
        for _ in 0 ..< 100 {
            if let port = listener?.port, port.rawValue != 0 { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        log.error("listener did not bind within 1s")
    }

    private func restartListener() throws {
        listener?.cancel()

        let paired = (try? store.pairedDevices()) ?? []

        // One PSK per paired phone, keyed by that phone's own fingerprint so
        // the client's offered identity picks the right one.
        let sessionKeys: [(identity: String, key: SymmetricKey)] = paired.compactMap { device in
            guard let remote = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: device.publicKey),
                  let key = try? KeySchedule.sessionKey(
                      localPrivate: identity,
                      remotePublic: remote,
                      context: Data(device.fingerprint.utf8)
                  )
            else { return nil }
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
        listener.stateUpdateHandler = { [weak self] state in
            if case let .failed(error) = state {
                Task { await self?.emit(.failed(error.localizedDescription)) }
            }
        }

        listener.start(queue: queue)
        self.listener = listener
        log.error("listening as '\(self.deviceName, privacy: .public)' sessionKeys=\(sessionKeys.count, privacy: .public) pairingCode=\(pairingKey != nil, privacy: .public)")
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
            // A wrong code fails in the TLS handshake, so this is where a bad
            // pairing lands — and the error is generic, hence the explicit note.
            log.error("accept: REJECTED \(String(describing: error), privacy: .public) (a TLS failure here usually means the code did not match)")
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
        try session.verify(code, at: Date())
        pairingSession = session

        let responder = PairingResponder(deviceName: deviceName)
        let device = try await responder.respond(to: request, on: channel, localIdentity: identity)

        try store.save(device)
        log.error("paired with \(device.name, privacy: .public) fp=\(device.fingerprint, privacy: .public)")

        // Consume the code and rebuild the listener so the new phone's session
        // PSK is live and the pairing PSK is gone.
        try await setPairingCode(nil)
        emit(.paired(device))

        await channel.close()
    }

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

        emit(.sessionStarted(fingerprint: fingerprint, peerDescription: description))

        let token = await initiator.onEgressChange { [weak self] interface in
            Task { await self?.emit(.egressObserved(interface)) }
        }

        sessionTask = Task { [weak self] in
            do {
                try await initiator.run(resuming: hello, decoder: decoder)
            } catch {
                await self?.emit(.failed(String(describing: error)))
            }
            await initiator.removeEgressObserver(token)
            await self?.sessionFinished(fingerprint: fingerprint)
        }
    }

    private func sessionFinished(fingerprint: String) {
        initiator = nil
        peerDescription = nil
        emit(.sessionEnded(fingerprint: fingerprint))
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

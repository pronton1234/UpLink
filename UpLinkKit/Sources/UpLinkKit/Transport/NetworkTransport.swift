import Foundation
import Network
import CryptoKit
import OSLog

/// The resolvers the Mac uses while the bridge is running.
///
/// **Why the bridge must supply DNS at all.** A Mac using nothing but the phone
/// has no DHCP lease and therefore no nameserver: its configured resolvers are
/// whatever the last real network handed it, typically the home router, which
/// is unreachable the moment that network goes away. Name resolution then fails
/// before a single packet is sent, so every connection dies at the first step
/// and the bridge looks completely dead while working perfectly — there is
/// simply nothing for it to carry.
///
/// Public anycast resolvers are the answer because they are reachable *through*
/// the bridge: a query to 1.1.1.1 is an ordinary public destination, so the
/// capture policy carries it to the phone, which resolves it over cellular.
/// That also puts DNS resolution on the carrier's network rather than the
/// Mac's, which is what makes CDN answers match the address traffic will
/// actually arrive from.
///
/// **These cannot be installed as the Mac's resolvers.** Setting `DNSSettings`
/// on `NETransparentProxyNetworkSettings` is accepted without error and has no
/// effect — a transparent proxy has no virtual interface to attach them to, and
/// the system resolver list is left unchanged (verified against
/// `scutil --dns`). So the Mac keeps whatever resolver it was given, and the
/// proxy rewrites the *destination* of each DNS query instead: the query goes
/// to ``primary`` across the bridge, and the reply is handed back to the client
/// addressed as though it came from the resolver the client asked.
///
/// Cloudflare rather than Google: both work, and 1.1.1.1 publishes a
/// no-logging policy, which matters more here than it usually would because
/// every name the user resolves crosses this path.
public enum UpLinkDNS {
    public static let servers = [
        "1.1.1.1",
        "1.0.0.1",
        "2606:4700:4700::1111",
        "2606:4700:4700::1001",
    ]

    /// Where redirected queries are actually sent. IPv4, because it is the
    /// family guaranteed to work over the bridge regardless of what the client
    /// originally asked.
    public static let primary = "1.1.1.1"

    /// The well-known DNS port. Traffic to it is redirected rather than sent
    /// to a resolver the Mac may no longer be able to reach.
    public static let port: UInt16 = 53
}

/// Constants shared by both ends of pairing.
public enum UpLinkPairing {

    /// Salt for the pairing PSK.
    ///
    /// **Why this is now a constant.** It used to be `SHA256(macFingerprint)`,
    /// which both sides could derive because the Mac published its fingerprint
    /// in a Bonjour TXT record. Over the cable there is no discovery and no TXT
    /// record, so at the moment the code is typed the phone does not yet know
    /// which Mac is about to dial it — and both sides must derive an identical
    /// salt or the handshake fails with no usable diagnostic.
    ///
    /// This costs less than it looks. The salt was never secret; it provided
    /// domain separation, not entropy, and the 10^6 bound on guessing the code
    /// is unchanged. What is lost is that a dictionary could be precomputed
    /// once rather than per-Mac — and mounting that requires already being root
    /// on the Mac with the cable attached, at the moment the user pairs. The
    /// real remedy for a weak code remains a PAKE; see ``KeySchedule``.
    public static let salt = Data("uplink-pairing-v2".utf8)
}

/// Builds the `NWParameters` for the peer link.
public enum TransportParameters {

    /// Adds one pre-shared key to a TLS options object.
    ///
    /// See ``applyPSKCiphersuite`` for the ciphersuite that must accompany it.
    private static func applyPSK(_ tls: NWProtocolTLS.Options, psk: SymmetricKey, identity: String) {
        let keyData = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityData = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }

        sec_protocol_options_add_pre_shared_key(
            tls.securityProtocolOptions,
            keyData as __DispatchData,
            identityData as __DispatchData
        )
    }

    /// The ciphersuite every PSK connection here negotiates. Applied once per
    /// options object, after every PSK has been added.
    ///
    /// **This is not a free choice — TLS 1.3 does not work.** An external PSK
    /// added with `sec_protocol_options_add_pre_shared_key` is never offered
    /// under TLS 1.3 in Network.framework: the handshake fails with -9858, and
    /// because the failure surfaces as `.waiting` rather than `.failed` it
    /// presents as a connection that hangs forever with no error. Every
    /// configuration with a 1.3 floor was measured to fail. The harness that
    /// established it (`spike/pair-probe --tls`) is gone with the AWDL
    /// transport; the finding outlived it, which is why it is written here.
    ///
    /// Among the suites that do work, this one is chosen for two properties:
    /// ChaCha20-Poly1305 is AEAD, and the ECDHE half provides **forward
    /// secrecy** — a plain `TLS_PSK_*` suite does not, so a leaked long-term
    /// key would expose every past session. Our session PSK is derived from
    /// static X25519 identities and never rotates, which makes that the
    /// difference between one compromise and total retroactive compromise.
    ///
    /// The version is pinned to 1.2 because that is where ECDHE-PSK lives, so
    /// negotiation is deterministic rather than drifting into a 1.3 attempt
    /// that would silently hang. Revisit if Apple ever supports 1.3 external
    /// PSKs — re-run the probe rather than assuming.
    private static func applyPSKCiphersuite(_ tls: NWProtocolTLS.Options) {
        sec_protocol_options_append_tls_ciphersuite(
            tls.securityProtocolOptions,
            tls_ciphersuite_t(rawValue: UInt16(TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256))!
        )
        sec_protocol_options_set_max_tls_protocol_version(
            tls.securityProtocolOptions, .TLSv12
        )
    }

    /// Parameters for the Mac's dial to the local relay.
    ///
    /// The original spec called for "no authentication handshake, for latency"
    /// — that would leave an open proxy for anyone who can reach the port. A
    /// PSK handshake costs one round trip on a loopback link, which is not a
    /// latency budget worth an open relay.
    ///
    /// The peer link is now a loopback TCP connection to the menu-bar app,
    /// which pumps it down the cable through `usbmuxd`. So none of the
    /// interface steering the AWDL era needed applies: there is no radio to
    /// pin, no address family to force, and no cellular interface for
    /// Network.framework to wander onto. What remains is the TLS-PSK, which is
    /// still end to end between this process and the phone — the relay carries
    /// ciphertext it has no key for.
    public static func session(psk: SymmetricKey, identity: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()

        applyPSK(tls, psk: psk, identity: identity)
        applyPSKCiphersuite(tls)

        let parameters = NWParameters(tls: tls, tcp: Self.tcpOptions())
        parameters.preferNoProxies = true
        return parameters
    }

    private static func tcpOptions() -> NWProtocolTCP.Options {
        let tcp = NWProtocolTCP.Options()
        // The bridge multiplexes many logical streams over this one connection,
        // so Nagle would add delay to every small interactive stream while a
        // bulk stream is in flight.
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        return tcp
    }

    /// Parameters for the phone's listener.
    ///
    /// Every paired Mac contributes one PSK keyed by that Mac's fingerprint,
    /// and an armed pairing code contributes one more. TLS selects by the
    /// identity the client offers, so a single listener serves both an
    /// already-paired Mac and one pairing for the first time — one port, one
    /// accept path.
    ///
    /// **Bound to loopback.** `usbmuxd`'s device side dials `127.0.0.1` on the
    /// phone, so binding loopback-only is both sufficient and the safest
    /// choice: the port is unreachable from Wi-Fi or cellular, and cannot be
    /// probed by anything off the device. If a device run ever shows the muxer
    /// dialling a non-loopback address instead, this is the one line to change
    /// — and the trade being made is stated here so that change is a decision
    /// rather than a shrug.
    public static func listener(
        sessionKeys: [(identity: String, key: SymmetricKey)],
        pairingKey: (identity: String, key: SymmetricKey)?,
        port: UInt16
    ) -> NWParameters {
        let tls = NWProtocolTLS.Options()

        for entry in listenerKeySet(sessionKeys: sessionKeys, pairingKey: pairingKey) {
            applyPSK(tls, psk: entry.key, identity: entry.identity)
        }
        // Once, after all the keys: see ``applyPSKCiphersuite`` for why this
        // line is what makes PSK work at all.
        applyPSKCiphersuite(tls)

        let parameters = NWParameters(tls: tls, tcp: Self.tcpOptions())
        // BOTH lines are required, and that is measured, not assumed.
        //
        // `requiredLocalEndpoint` pins the bind to loopback and the fixed port.
        // `acceptLocalOnly` reads like it means the same thing and its
        // documented wording suggests something wider ("the local network"),
        // so it was removed as redundant — and the end-to-end test immediately
        // stopped establishing a session at all. Whatever it does here, the
        // listener does not accept the loopback connection without it.
        //
        // Left in with the evidence attached rather than reasoned away again.
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!
        )
        parameters.acceptLocalOnly = true
        // The extension can be restarted while the old socket is still in
        // TIME_WAIT, and a fixed port cannot simply move to another number the
        // way the old ephemeral listener did.
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    /// Identity used for the pairing PSK. Fixed, because at pairing time the
    /// two devices do not yet know each other's fingerprints.
    public static let pairingIdentity = "uplink-pairing"

    /// Identity of the placeholder key described in ``listenerKeySet``.
    public static let placeholderIdentity = "uplink-unpairable"

    /// The pre-shared keys a listener should offer, never empty.
    ///
    /// On a fresh install there are no paired devices and no pairing code, so
    /// the natural key set is empty — and a TLS listener with no key material
    /// cannot start. That would leave the phone with nothing bound on the
    /// pairing port, so `usbmux Connect` would be refused and the Mac would
    /// report "iPhone connected, not answering" for a phone that is running
    /// perfectly well and simply has nothing to say yet.
    ///
    /// A random placeholder key nobody holds keeps the listener startable while
    /// refusing every handshake, which is exactly the desired behaviour for an
    /// unpaired phone.
    public static func listenerKeySet(
        sessionKeys: [(identity: String, key: SymmetricKey)],
        pairingKey: (identity: String, key: SymmetricKey)?
    ) -> [(identity: String, key: SymmetricKey)] {
        var keys = sessionKeys
        if let pairingKey { keys.append(pairingKey) }
        guard keys.isEmpty else { return keys }
        return [(placeholderIdentity, SymmetricKey(size: .bits256))]
    }

    /// Parameters for the one-time pairing handshake, keyed by the six-digit
    /// code rather than a long-term secret.
    public static func pairing(code: PairingCode, salt: Data = UpLinkPairing.salt) -> NWParameters {
        session(
            psk: KeySchedule.pairingKey(code: code, salt: salt),
            identity: Self.pairingIdentity
        )
    }
}

/// A `FrameChannel` backed by a real `NWConnection`.
public actor NWConnectionChannel: FrameChannel {

    private let connection: NWConnection
    /// Retained from `start(on:)` so timeouts can be scheduled without a
    /// second queue.
    private var queue: DispatchQueue?
    private var receiveContinuations: [CheckedContinuation<Data?, Error>] = []
    private var pending: [Data] = []
    private var pendingBytes = 0
    private var isPaused = false
    private var isClosed = false

    /// Whether this channel has been closed, from outside.
    ///
    /// Exposed so a caller holding a channel can tell a live one from a spent
    /// one. `PhoneSessionState` needs exactly this: "do I have a channel" is not
    /// the same question as "am I connected", and answering the first while
    /// meaning the second is what made the phone claim a session that had
    /// already ended.
    public var isFinished: Bool { isClosed }
    private var isStarted = false

    /// How many undelivered bytes may pile up before this stops reading the
    /// socket.
    ///
    /// An iOS Network Extension is killed if it exceeds the system's memory
    /// limit (50 MB on iOS 15 and later, 15 MB before that — and Apple's
    /// guidance is not to hard-code either). Without this, a peer that sends
    /// faster than the frame loop drains grows `pending` without bound, and the
    /// first symptom is the extension disappearing mid-download. Ceasing to
    /// re-arm the read applies real backpressure: TCP stops acknowledging, and
    /// the peer slows down.
    public static let receiveHighWater = 4 * 1024 * 1024

    public init(connection: NWConnection) {
        self.connection = connection
    }

    /// How long a connection may sit in `.waiting` before it is called a
    /// failure.
    ///
    /// `.waiting` is not always fatal — Network.framework retries on its own —
    /// so it cannot be treated as an error immediately. But it is also where a
    /// **failed TLS handshake** lands, and waiting forever on one is
    /// indistinguishable from a hang.
    ///
    /// Twelve seconds is now generous rather than tight: the peer link is a
    /// loopback connection to the app's relay, so there is no radio to come up
    /// and nothing to discover. Anything not ready in this window is not going
    /// to be, and the honest answer is to fail so the redial loop can try
    /// again.
    public static let connectTimeout: TimeInterval = 12

    /// Starts the connection and waits until it is ready or has failed.
    ///
    /// Every terminal state must resume the continuation. An earlier version
    /// handled only `.ready`, `.failed` and `.cancelled`, so a rejected
    /// handshake — which Network.framework reports as `.waiting`, not
    /// `.failed` — left this awaiting forever. Pairing did not fail; it hung,
    /// which is a far harder thing to diagnose from a phone.
    /// Whether a send error means the connection itself is finished.
    ///
    /// These are the errors where retrying on the same socket cannot help, so
    /// the honest response is to end the session and let the phone redial —
    /// rather than let every subsequent flow rediscover the same corpse.
    static func isTerminal(_ error: NWError) -> Bool {
        guard case let .posix(code) = error else { return false }
        return code == .EPIPE || code == .ECONNRESET || code == .ENOTCONN
            || code == .ENETDOWN || code == .EHOSTUNREACH || code == .ENETUNREACH
    }

    public func start(on queue: DispatchQueue) async throws {
        guard !isStarted else { return }
        isStarted = true
        self.queue = queue

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OneShot<Void>(continuation)

            // No cancellation needed: OneShot resumes at most once, so this
            // fires harmlessly if the connection already succeeded or failed.
            queue.asyncAfter(deadline: .now() + Self.connectTimeout) {
                once.resume(throwing: ChannelError.handshakeFailed(
                    "no connection within \(Int(Self.connectTimeout))s"
                ))
            }

            // NOT torn down after `.ready`, and that is the whole point.
            //
            // `OneShot` resumes at most once, so this handler used to become
            // inert the moment the connection came up: every later state,
            // INCLUDING `.failed` and `.cancelled`, was silently discarded. The
            // channel's only remaining liveness sensor was an outstanding
            // `connection.receive` callback, so a connection that died while no
            // read was armed became a zombie — `isClosed == false`, `receive()`
            // suspended on a continuation nobody would ever resume, and
            // `MacSessionHost.sessionFinished` never called.
            //
            // Measured 2026-08-14: the pipe broke 13 seconds into a session and
            // nothing noticed. `hasSession` stayed true, so `handleNewFlow`
            // kept claiming every flow on the machine and every one died in the
            // write — 31,034 `Broken pipe` against 30 successful opens, with
            // **zero** `session ENDED`. Every browser tab failed while both ends
            // reported a healthy bridge.
            //
            // Resuming the OneShot still reports the *connect* result exactly as
            // before; what is new is that the handler keeps running afterwards
            // and turns a terminal state into `receive() -> nil`, which the
            // existing plumbing already converts into `.sessionEnded`.
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    once.resume(returning: ())
                case let .failed(error):
                    once.resume(throwing: error)
                    Logger(subsystem: UpLinkIdentifiers.logSubsystem, category: "channel")
                        .error("connection failed: \(String(describing: error), privacy: .public) — ending the session")
                    Task { await self?.finish() }
                case .cancelled:
                    once.resume(throwing: ChannelError.peerClosed)
                    Task { await self?.finish() }
                case let .waiting(error):
                    Logger(subsystem: UpLinkIdentifiers.logSubsystem, category: "channel")
                        .error("connection waiting: \(String(describing: error), privacy: .public)")
                    // Two errors in `.waiting` are not something waiting fixes.
                    //
                    // A TLS error means the peer rejected the handshake, which
                    // for us means the pairing code was wrong or the device is
                    // not paired.
                    //
                    // ECONNREFUSED means nothing is listening on that port.
                    // Over the cable that is the ORDINARY case — it is what
                    // "UpLink is not running on the phone" looks like — and
                    // riding the 12-second timeout for it makes the redial loop
                    // take twelve seconds to notice something the kernel
                    // answered instantly. Network.framework reports a refused
                    // connection as `.waiting` rather than `.failed` because it
                    // intends to retry; for a loopback port that will not help.
                    //
                    // Anything else — the relay's listener not bound yet, the
                    // extension still starting — is genuinely transient, so it
                    // keeps waiting until the timeout.
                    switch error {
                    case .tls:
                        once.resume(throwing: ChannelError.handshakeFailed(
                            "TLS rejected: \(error)"
                        ))
                    case let .posix(code) where code == .ECONNREFUSED:
                        once.resume(throwing: ChannelError.handshakeFailed(
                            "connection refused — nothing is listening there"
                        ))
                    default:
                        break
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }

        pump()
    }

    /// Continuously drains the socket into this actor.
    ///
    /// Bytes go straight from the socket buffer to the frame decoder. Nothing
    /// is written to disk at any point on this path.
    private nonisolated func pump() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            Task { [weak self] in
                guard let self else { return }
                var keepReading = true
                if let data, !data.isEmpty {
                    keepReading = await self.deliver(data)
                }
                if isComplete || error != nil {
                    await self.finish()
                } else if keepReading {
                    self.pump()
                }
                // When `keepReading` is false the read is not re-armed here;
                // `receive()` restarts it once the backlog has drained.
            }
        }
    }

    /// Queues or hands off one chunk. Returns whether reading should continue.
    private func deliver(_ data: Data) -> Bool {
        if receiveContinuations.isEmpty {
            pending.append(data)
            pendingBytes += data.count
        } else {
            receiveContinuations.removeFirst().resume(returning: data)
        }
        if pendingBytes >= Self.receiveHighWater {
            isPaused = true
            return false
        }
        return true
    }

    private func finish() {
        guard !isClosed else { return }
        isClosed = true
        let waiting = receiveContinuations
        receiveContinuations.removeAll()
        for continuation in waiting { continuation.resume(returning: nil) }
    }

    /// How long a single write may sit unacknowledged before the link is
    /// declared dead.
    ///
    /// Receives were bounded (``receiveHighWater``) while sends were not, and
    /// that asymmetry is a hang waiting to happen: if the peer stops draining,
    /// TCP backpressure means `.contentProcessed` is never called and **every**
    /// caller blocks forever — including the one writing the OPEN frame for a
    /// newly captured flow. The observed signature was `tcp claim` with no
    /// matching `tcp open`, four seconds after the session was demonstrably
    /// healthy: flows owned by us and serviced by nobody.
    public static let sendTimeout: TimeInterval = 10

    public func send(_ data: Data) async throws {
        let queue = self.queue
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OneShot<Void>(continuation)

            // Failing the write is what lets the session be torn down and
            // rebuilt. Blocking here just moves the stall somewhere harder to
            // see.
            queue?.asyncAfter(deadline: .now() + Self.sendTimeout) {
                once.resume(throwing: ChannelError.handshakeFailed(
                    "write not acknowledged within \(Int(Self.sendTimeout))s — peer stopped reading"
                ))
            }

            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error {
                    // A hard error is a property of the CONNECTION, not of this
                    // write, and rediscovering it per flow is how one dead pipe
                    // produced 31,034 identical failures while the session went
                    // on claiming every flow on the machine.
                    //
                    // Deliberately narrow. The `sendTimeout` above and any
                    // transient error keep today's behaviour — failing one write
                    // — because tearing a session down over a single slow write
                    // would be its own outage, and `stalledPeerFailsTheWrite`
                    // exists to keep that path honest.
                    if Self.isTerminal(error) { Task { await self?.finish() } }
                    once.resume(throwing: error)
                } else {
                    once.resume(returning: ())
                }
            })
        }
    }

    public func receive() async throws -> Data? {
        if !pending.isEmpty {
            let next = pending.removeFirst()
            pendingBytes -= next.count
            // Resume at half the high-water mark rather than at zero, so a
            // busy link does not stop and start on every chunk.
            if isPaused, pendingBytes < Self.receiveHighWater / 2 {
                isPaused = false
                pump()
            }
            return next
        }
        if isClosed { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            receiveContinuations.append(continuation)
        }
    }

    public func close() async {
        finish()
        connection.cancel()
    }
}

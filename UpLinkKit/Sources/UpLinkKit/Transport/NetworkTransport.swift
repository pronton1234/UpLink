import Foundation
import Network
import CryptoKit
import OSLog

/// How the two devices reach each other.
///
/// Ordered by preference. `peerToPeer` needs no Wi-Fi network at all — AWDL
/// brings up a direct radio link — but whether it survives inside an iOS
/// Network Extension is the open question Phase 0 exists to answer. `localLink`
/// works over the phone's Personal Hotspot or a shared Wi-Fi network and is
/// known to work from an extension, so it is the guaranteed fallback.
public enum TransportProfile: String, Sendable, CaseIterable {
    case peerToPeer
    case localLink

    /// Try AWDL first, fall back to plain IP. Once the Phase 0 spike reports,
    /// this list is the single place that changes.
    public static var preferenceOrder: [TransportProfile] { [.peerToPeer, .localLink] }

    var includesPeerToPeer: Bool { self == .peerToPeer }
}

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

public enum UpLinkService {
    /// Bonjour service type. AWDL **requires** Bonjour — a direct IP endpoint
    /// will not traverse a peer-to-peer link — so discovery is mandatory rather
    /// than a convenience.
    public static let bonjourType = "_uplink._tcp"
    public static let bonjourDomain = "local."

    /// TXT record key carrying the Mac's long-term public key fingerprint, so
    /// the phone can recognise a known Mac before connecting.
    public static let fingerprintKey = "fp"
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
    /// configuration with a 1.3 floor was measured to fail; see
    /// `spike/pair-probe --tls`, which is the harness that established this.
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

    /// Parameters for an authenticated session with an already-paired device.
    ///
    /// The original spec called for "no authentication handshake, for latency"
    /// — that would leave an open proxy on the local network for anyone to
    /// use. A PSK handshake costs one round trip on a link whose RTT is under a
    /// millisecond, which is not a latency budget worth an open relay.
    public static func session(psk: SymmetricKey, identity: String, profile: TransportProfile) -> NWParameters {
        let tls = NWProtocolTLS.Options()

        applyPSK(tls, psk: psk, identity: identity)
        applyPSKCiphersuite(tls)

        let tcp = NWProtocolTCP.Options()
        // The bridge multiplexes many logical streams over this one connection,
        // so Nagle would add delay to every small interactive stream while a
        // bulk stream is in flight.
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10

        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = profile.includesPeerToPeer
        parameters.prohibitedInterfaceTypes = Self.peerLinkProhibitedInterfaces
        return parameters
    }

    /// The peer link is a *local* link by definition — AWDL, a shared Wi-Fi
    /// network, the phone's own hotspot, or USB. The Mac is never reachable
    /// through the carrier, so cellular is not a fallback for it; it is a dead
    /// end that Network.framework will nonetheless select.
    ///
    /// Left unconstrained, a phone with an active radio pins the connection to
    /// `pdp_ip0` and then *suppresses* the link-local AWDL path that is the only
    /// one able to carry data:
    ///
    ///     [C1 … ready parent-flow (satisfied, interface: pdp_ip0[endc_sub6],
    ///      scoped, uses cell, …)] suppressing better path notification
    ///      (comparing …_uplink._tcp.local. to 169.254.135.159:59175)
    ///
    /// The connection reports `.ready` and carries nothing, so the failure looks
    /// like a hang rather than an error. That is the difference between the
    /// bridge working with no Wi-Fi anywhere and the Mac simply being offline.
    ///
    /// This costs nothing on the paths that already worked: over USB or a shared
    /// network the peer link was never on cellular to begin with.
    private static let peerLinkProhibitedInterfaces: [NWInterface.InterfaceType] = [.cellular]

    /// Parameters for the Mac's listener.
    ///
    /// Every paired phone contributes one PSK keyed by its own fingerprint, and
    /// an active pairing code contributes one more. TLS selects by the identity
    /// the client offers, so a single listener serves both already-paired
    /// phones and a phone pairing for the first time — no second port, no
    /// second Bonjour service.
    public static func listener(
        sessionKeys: [(identity: String, key: SymmetricKey)],
        pairingKey: (identity: String, key: SymmetricKey)?,
        profile: TransportProfile
    ) -> NWParameters {
        let tls = NWProtocolTLS.Options()

        for entry in listenerKeySet(sessionKeys: sessionKeys, pairingKey: pairingKey) {
            applyPSK(tls, psk: entry.key, identity: entry.identity)
        }
        // Once, after all the keys: see ``applyPSKCiphersuite`` for why this
        // line is what makes PSK work at all.
        applyPSKCiphersuite(tls)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10

        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = profile.includesPeerToPeer
        parameters.prohibitedInterfaceTypes = Self.peerLinkProhibitedInterfaces
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
    /// cannot start. That would leave the Mac unable to advertise over Bonjour,
    /// so the phone could never see it *in order to start pairing*: a
    /// chicken-and-egg deadlock on the very first run.
    ///
    /// A random placeholder key nobody holds keeps the listener startable and
    /// advertising while refusing every handshake, which is exactly the desired
    /// behaviour for an unpaired Mac.
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
    public static func pairing(code: PairingCode, salt: Data, profile: TransportProfile) -> NWParameters {
        session(
            psk: KeySchedule.pairingKey(code: code, salt: salt),
            identity: Self.pairingIdentity,
            profile: profile
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
    /// `.waiting` is not always fatal — an AWDL link takes a moment to come up,
    /// and Network.framework retries on its own — so it cannot be treated as an
    /// error immediately. But it is also where a **failed TLS handshake**
    /// lands, and waiting forever on one is indistinguishable from a hang. A
    /// local-link peer that is not ready within this window is not going to be.
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
                    // A TLS error in `.waiting` is not something waiting fixes:
                    // the peer rejected the handshake, which for us means the
                    // pairing code was wrong or the device is not paired.
                    // Failing now turns a 12-second stall into an immediate,
                    // accurate message. Anything else — no route yet, AWDL
                    // still coming up — is genuinely transient, so it keeps
                    // waiting until the timeout.
                    if case .tls = error {
                        once.resume(throwing: ChannelError.handshakeFailed(
                            "TLS rejected: \(error)"
                        ))
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

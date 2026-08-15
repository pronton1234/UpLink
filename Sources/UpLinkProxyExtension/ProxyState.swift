import Foundation
import Network
import NetworkExtension
import CryptoKit
import OSLog
import UpLinkKit

/// Everything mutable about the proxy, and the bridge to ``MacSessionHost``.
///
/// The extension hosts the listener rather than the containing app, because it
/// owns the captured flows and an established TLS session cannot be handed
/// across an XPC boundary.
enum ProxyStartupError: LocalizedError {
    case missingIdentity

    var errorDescription: String? {
        switch self {
        case .missingIdentity:
            // Worth spelling out: the obvious guess is a keychain problem, and
            // the actual cause is that a system extension cannot reach the
            // keychain at all.
            "The app did not supply a device identity. A system extension runs "
            + "as root outside the login session and cannot read the user "
            + "keychain, so the identity must arrive via providerConfiguration."
        }
    }
}

actor ProxyState {

    private var host: MacSessionHost?
    private(set) var initiator: BridgeInitiator?
    private var eventTask: Task<Void, Never>?
    private var log: Logger?

    /// Read synchronously from `handleNewFlow`, which cannot await.
    ///
    /// A cached snapshot rather than actor state, because the capture decision
    /// has to be made on the spot: `handleNewFlow` returns a `Bool` and the
    /// system will not wait for an actor hop. Refreshed whenever the session
    /// changes.
    nonisolated(unsafe) private(set) var currentPolicy = CapturePolicy()

    /// Whether a phone is connected, readable synchronously from
    /// `handleNewFlow`.
    ///
    /// Load-bearing for the machine's basic usability. `handleNewFlow` must
    /// answer `true`/`false` immediately, and answering `true` means "I own
    /// this connection". If no phone is connected there is nowhere to send it,
    /// so claiming it kills it — and claiming EVERY flow kills all networking
    /// on the Mac until the extension is torn down. Never claim what cannot be
    /// serviced.
    nonisolated(unsafe) private(set) var hasSession = false

    /// Flows currently held, by signing identifier.
    ///
    /// **Locked, not `nonisolated(unsafe)`.** The first version of this was an
    /// unguarded dictionary, by analogy with `hasSession` and `currentPolicy`
    /// above — and the analogy is false. Those are written only from the actor
    /// and read from `handleNewFlow`; this is WRITTEN from two contexts: the
    /// increment happens on NetworkExtension's thread inside `handleNewFlow`,
    /// and the decrement in a `defer` inside a detached `Task`.
    ///
    /// Two threads mutating a Swift `Dictionary` is heap corruption, not a stale
    /// read. Under real flow load the extension took a SIGSEGV about two seconds
    /// after a session came up, every time:
    ///
    ///     exited due to SIGSEGV | sent by exc handler, ran for 70426ms
    ///     service has crashed 1 times in a row
    ///
    /// which presented as the bridge simply not working — the extension
    /// restarted, the session was gone, and nothing said why.
    private let flowCounts = FlowCounts()

    nonisolated var flowsPerApp: [String: Int] { flowCounts.snapshot() }
    nonisolated func flowStarted(_ app: String?) { flowCounts.increment(app) }
    nonisolated func flowFinished(_ app: String?) { flowCounts.decrement(app) }

    /// Seeded from providerConfiguration at startup; the app owns durable
    /// storage. See ``InMemoryDeviceDirectory`` for why this process cannot.
    private var store = InMemoryDeviceDirectory()
    /// Set when a phone says it has forgotten this Mac, cleared once the app has
    /// been told. The app owns the keychain; this process cannot reach it.
    private var unpairedByPeer: String?

    /// Apps whose traffic must never be bridged, from `providerConfiguration`.
    ///
    /// Held across sessions because the policy is rebuilt from scratch on every
    /// `sessionStarted`, and an escape hatch that silently lapses on reconnect
    /// is worse than none — it works while you are watching and fails later.
    private var directApps: Set<String> = []

    func startHosting(
        queue: DispatchQueue,
        log: Logger,
        configuration: [String: Any]?
    ) async throws {
        self.log = log

        guard let raw = configuration?["identity"] as? Data,
              let identity = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
        else {
            throw ProxyStartupError.missingIdentity
        }

        // Paired devices arrive as JSON alongside the identity.
        let seed: [PairedDevice] = (configuration?["pairedDevices"] as? Data)
            .flatMap { try? JSONDecoder().decode([PairedDevice].self, from: $0) } ?? []
        store = InMemoryDeviceDirectory(seed: seed)
        log.info("seeded with \(seed.count, privacy: .public) paired device(s)")

        directApps = Set((configuration?["directApps"] as? [String]) ?? [])
        // Logged unconditionally, including when empty. Logging only the
        // non-empty case made a misconfigured escape hatch indistinguishable
        // from a build without the feature — which is exactly what happened:
        // a stale sandbox container for com.uplink.app meant `defaults write
        // com.uplink.app` landed in ~/Library/Containers/…, while this app is
        // deliberately NOT sandboxed and reads ~/Library/Preferences/. The
        // value was written, read back correctly by `defaults read`, and never
        // seen by the app. Silence is not evidence of absence.
        log.error("never bridging: [\(self.directApps.sorted().joined(separator: ","), privacy: .public)]")

        let host = MacSessionHost(
            identity: identity,
            deviceName: (configuration?["deviceName"] as? String) ?? "Mac",
            store: store,
            queue: queue
        )
        self.host = host

        // Tombstones must outlive this process, because an extension restart is
        // exactly when a revoked device would otherwise come back to life — the
        // directory is in memory and rebuilt from this same snapshot. Restored
        // BEFORE `start()`, so the first listener already carries the keys those
        // revoked devices need in order to be told.
        if let data = configuration?["revokedDevices"] as? Data,
           let restored = try? JSONDecoder().decode(RevocationTombstones.self, from: data) {
            await host.restoreTombstones(restored)
            log.error("restored \(restored.all.count, privacy: .public) revocation tombstone(s)")
        }

        let events = await host.events()
        eventTask = Task { [weak self] in
            for await event in events {
                await self?.handle(event: event, host: host)
            }
        }

        try await host.start()
    }

    func stopHosting() async {
        // Cleared first: from this instant handleNewFlow stops claiming flows,
        // so traffic returns to normal even while teardown is still running.
        hasSession = false
        eventTask?.cancel()
        eventTask = nil
        await host?.stop()
        host = nil
        initiator = nil
        currentPolicy = CapturePolicy()
    }

    private func handle(event: SessionHostEvent, host: MacSessionHost) async {
        switch event {
        case let .sessionStarted(fingerprint, peerDescription):
            // Record the phone's address BEFORE exposing the initiator, or the
            // very first captured flow could be our own connection to it —
            // the self-capture loop.
            // Resolvers are read at session start rather than once at launch:
            // the Mac may have joined a different network since, and a stale
            // resolver list means DNS gets bridged to a router that cannot be
            // reached, which stalls every lookup.
            // Subtracting our own resolvers is load-bearing, not tidiness.
            // While the proxy is running, the system's resolver list IS
            // `UpLinkDNS.servers`, so without this they would be marked
            // "reach directly" — sent out an interface that, in the case this
            // whole mechanism exists for, does not exist. DNS would break in
            // exactly the way the DNS settings were added to prevent.
            let resolvers = SystemResolvers.current()
                .subtracting(UpLinkDNS.servers.map { $0.lowercased() })
            // Read here, not at launch, for the same reason as the resolvers:
            // the Mac may have joined a different network since.
            let attached = LocalNetworks.current()
            currentPolicy = CapturePolicy(
                peerEndpoints: [peerDescription],
                directHosts: resolvers,
                directApps: directApps,
                localNetworks: attached
            )
            let networks = attached
                .map { "\($0.network.count == 16 ? "v6" : "v4")/\($0.prefixLength)" }
                .joined(separator: ",")
            log?.error("capture policy: peer=\(peerDescription, privacy: .public) resolvers=\(resolvers.sorted().joined(separator: ","), privacy: .public) on-link=[\(networks, privacy: .public)]")
            initiator = await host.initiator
            hasSession = true
            // Error level so it survives in `log show`: info-level messages
            // live only in the memory ring buffer and are the first thing
            // evicted by a burst of errors — exactly when they are needed.
            log?.error("session started with \(fingerprint, privacy: .public)")

        case let .sessionEnded(fingerprint):
            hasSession = false
            initiator = nil
            currentPolicy = CapturePolicy()
            flowCounts.removeAll()
            // Logged because a session that quietly dies looks exactly like a
            // session that is up and carrying nothing. Both ends keep saying
            // "connected" — the phone because its tunnel is still running, the
            // Mac because nothing told it otherwise — while every flow the
            // proxy claims has nowhere to go.
            log?.error("session ENDED with \(fingerprint, privacy: .public)")

        case let .paired(device):
            log?.info("paired with \(device.name, privacy: .public)")

        case let .egressObserved(interface):
            log?.error("egress: \(interface.displayName, privacy: .public)")

        case let .peerUnpaired(fingerprint):
            // Sticky, and read by the "status" reply below. Without it the app
            // was never told, so `MenuBarModel.refreshStatus`'s `.unpaired`
            // case was dead code, the keychain kept the phone, and the next
            // re-seed handed the revoked device straight back to the listener.
            unpairedByPeer = fingerprint
            // The app owns durable storage — this process cannot reach the
            // keychain — so it has to be told, or the pairing comes straight
            // back the next time the app re-seeds the extension.
            log?.error("peer unpaired us: \(fingerprint, privacy: .public)")
            hasSession = false
            initiator = nil
            currentPolicy = CapturePolicy()
            flowCounts.removeAll()

        case let .failed(message):
            log?.error("host FAILED: \(message, privacy: .public)")
        }
    }

    /// Handles a message from the containing app.
    ///
    /// Text rather than a plist because the vocabulary is three verbs and a
    /// six-digit code; a schema would be more ceremony than the traffic
    /// deserves.
    func handle(message: String) async -> String {
        // Logged because a pairing code that never reaches the extension looks
        // exactly like one the phone typed wrongly.
        log?.error("ipc: received \(message.prefix(5), privacy: .public)…")
        guard let host else {
            log?.error("ipc: no host yet — message dropped")
            return "unavailable"
        }

        if message == "status" {
            // Checked before anything else, and cleared by the read: this is the
            // only chance to tell the app, and the app is the only side that can
            // update durable storage.
            if let fingerprint = unpairedByPeer {
                unpairedByPeer = nil
                return "unpaired|\(fingerprint)"
            }
            guard let initiator else { return "waiting" }
            let egress = await initiator.observedEgress ?? .unknown
            let peer = await host.peerDescription ?? ""
            return "connected|\(peer)|\(egress.rawValue)"
        }

        // The Disconnect button did nothing. `MenuBarModel.disconnect()` has
        // always sent this string; with no case for it, it fell through to
        // "unknown" and the only thing that changed was the menu bar label. The
        // session stayed up, the proxy went on claiming every flow, and the
        // user's one obvious way to stop bridging was a lie.
        if message == "disconnect" {
            log?.error("ipc: disconnect requested")
            // `endSession`, NOT `stop()`.
            //
            // `stop()` cancels the listener and the path monitor as well as the
            // session, and nothing restarted them — so after a Disconnect the
            // Mac was off the air entirely and an already-paired phone could
            // never reconnect. The only ways back were "Show Pairing Code",
            // which rebuilds the listener as a side effect, or relaunching the
            // app. Disconnecting one session is not a reason to stop being
            // findable.
            //
            // This still emits `.sessionEnded`, which is what clears
            // `hasSession`, releases the claim path, and lets the app drop the
            // route tunnel.
            await host.endSession()
            return "ok"
        }

        if message.hasPrefix("pair:") {
            let digits = String(message.dropFirst("pair:".count))
            do {
                if digits == "off" {
                    try await host.setPairingCode(nil)
                } else {
                    try await host.setPairingCode(try PairingCode(digits: digits))
                }
                log?.error("ipc: pairing code set")
                return "ok"
            } catch {
                log?.error("ipc: pairing code FAILED \(String(describing: error), privacy: .public)")
                return "error|\(error)"
            }
        }

        // Forgetting a phone must reach the phone.
        //
        // The app removes the device from its own store and rebuilds the
        // listener with `sessionKeys=0`. Without this, the phone still holds
        // the pairing and keeps dialling, failing the TLS-PSK handshake against
        // an identity that no longer exists — on every retry, with nothing to
        // distinguish it from any other failure. The user sees a Mac that will
        // not accept a phone that is plainly trying.
        //
        // Announce first, tear down second: the notice travels on the session
        // being ended, so the other order guarantees it is never delivered.
        if message.hasPrefix("unpair:") {
            let fingerprint = String(message.dropFirst("unpair:".count))
            log?.error("ipc: unpair \(fingerprint, privacy: .public)")

            // Captured before the removal: the tombstone needs the public key,
            // which is the only way the phone can still reach us to be told.
            let removed = (try? store.pairedDevices())?.first { $0.fingerprint == fingerprint }
            try? store.remove(fingerprint: fingerprint)

            if let initiator, await host.activeFingerprint == fingerprint {
                // Connected right now: say it directly, no tombstone needed.
                await initiator.announceUnpaired()
                await host.endSession()
            } else if let removed {
                // Not connected, so there is no session to carry the notice.
                // Without a tombstone the phone never finds out and re-dials
                // forever holding a pairing this Mac has forgotten.
                await host.revoke(removed)
            }
            return "ok|\(await host.currentTombstones.all.count)"
        }

        // Handed back so the app can persist them into the next seed.
        if message == "tombstones" {
            guard let json = try? JSONEncoder().encode(await host.currentTombstones) else { return "" }
            return json.base64EncodedString()
        }

        if message == "devices" {
            // Full records, base64 JSON, not a display summary.
            //
            // Pairing happens HERE, in the extension, because the extension
            // owns the listener. But the extension cannot reach the keychain —
            // it runs as root outside the login session — so its store is in
            // memory and dies with the process. Without handing the whole
            // record back (public key included, which the old
            // "fingerprint:name" summary omitted) the app cannot re-seed the
            // extension next time, and every launch starts unpaired. That is
            // why the Mac kept reporting sessionKeys=0 and the phone kept
            // being rejected with "unknown PSK identity".
            let devices = (try? store.pairedDevices()) ?? []
            guard let json = try? JSONEncoder().encode(devices) else { return "" }
            return json.base64EncodedString()
        }

        return "unknown"
    }
}

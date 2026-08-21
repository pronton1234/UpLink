import Foundation
import Network
import NetworkExtension
import CryptoKit
import OSLog
import UpLinkKit

/// Everything mutable about the proxy, and the bridge to ``MacSessionClient``.
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

    /// The Mac's side of the bridge. It DIALS now: `usbmuxd` only carries
    /// Mac→phone connections, so the phone is the listener and this extension
    /// connects out to a loopback port the menu-bar app relays onto the cable.
    /// This process cannot reach `usbmuxd` itself — it is sandboxed.
    private var client: MacSessionClient?

    /// The loopback port the app's relay is currently serving, and the device
    /// behind it. Nil whenever no cable is attached.
    private var relayPort: UInt16?
    /// Where the phone is. Loopback means the cable's relay; anything else
    /// is the phone's own address on the network the Mac hosts.
    private var relayHost: String = "127.0.0.1"
    private var dialingHost: String?
    private var relayUDID: String?

    /// Redials the phone while the cable is attached.
    private var sessionTask: Task<Void, Never>?
    /// Retries a pairing dial for the life of the six-digit code.
    private var pairingTask: Task<Void, Never>?

    /// Phones unpaired while they were not connected, kept only long enough to
    /// be told once. See ``MacSessionClient/deliverUnpairNotice(relayPort:to:)``.
    private var tombstones = RevocationTombstones()
    private let tombstoneStore = TombstoneStore()

    /// What ``sessionTask`` is actually dialling right now.
    ///
    /// Distinct from `relayPort`/`relayUDID`, which record the most recent
    /// announcement. Conflating the two is what let the extension keep dialling
    /// a port that no longer existed.
    private var dialingPort: UInt16?
    private var dialingUDID: String?

    /// Set by an explicit Disconnect, cleared by anything the user does that
    /// means "bridge again". Without it the app's relay re-announcement would
    /// immediately undo the Disconnect, since from the app's side nothing about
    /// the cable has changed.
    private var disconnectedByUser = false

    /// The last device a relay was announced for, kept across a Disconnect so
    /// "is this the same cable?" can still be answered. See the `usbrelay:`
    /// handler.
    private var lastRelayUDID: String?
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

        let client = MacSessionClient(
            identity: identity,
            deviceName: (configuration?["deviceName"] as? String) ?? "Mac",
            store: store,
            queue: queue
        )
        self.client = client
        self.queue = queue
        // A restart is exactly when an undelivered notice would be lost, and
        // the phone would keep a pairing nobody remembers.
        tombstones = tombstoneStore.load()

        // Tombstones are the PHONE's business now: it owns the listener, so it
        // is the side that must keep a revoked Mac's key on the air long enough
        // to tell it. Nothing to restore here.

        let events = await client.events()
        eventTask = Task { [weak self] in
            for await event in events {
                await self?.handle(event: event, client: client)
            }
        }
        // Nothing to start. The session begins when the app reports a cable.
    }

    /// The queue sessions are dialled on, kept from `startHosting`.
    private var queue: DispatchQueue?

    /// Attempts pairing until the user has typed the code, or it expires.
    ///
    /// See the `pair:` handler for why this is a loop rather than one dial.
    private func startPairing(
        client: MacSessionClient,
        code: PairingCode,
        port: UInt16,
        udid: String
    ) {
        let log = self.log
        pairingTask = Task { [weak self] in
            let deadline = ContinuousClock.now + .seconds(Int(PairingSession.validity))
            while !Task.isCancelled, ContinuousClock.now < deadline {
                do {
                    let device = try await client.pair(relayPort: port, code: code, udid: udid)
                    log?.error("ipc: paired \(device.fingerprint, privacy: .public)")
                    guard let self else { return }
                    // A fresh pairing clears any "the phone refuses us" count,
                    // or the UI would go on telling the user to pair after they
                    // just did.
                    await self.noteHandshakeAccepted()
                    // Straight into a session, so the user does not have to do
                    // anything else to start bridging.
                    await self.beginSession(client: client, port: port, udid: udid)
                    return
                } catch {
                    // Expected until the phone is armed. Only logged once a
                    // second at most, and only at this level, because the
                    // common case is "the user is still walking to the phone".
                    try? await Task.sleep(for: .milliseconds(1500))
                }
            }
            log?.error("ipc: pairing window closed without the phone answering")
        }
    }

    private func beginSession(client: MacSessionClient, port: UInt16, udid: String) {
        // Whatever host is current — loopback for the cable, the phone's own
        // address on the hosted network otherwise.
        startRedialing(client: client, host: relayHost, port: port, udid: udid)
    }

    /// Keeps a session up for as long as the cable is attached.
    ///
    /// The Mac dials, so something has to decide when to dial again. Ending a
    /// session is normal — the phone's extension restarts, the screen locks and
    /// the listener rebuilds — and the cable being physically present is the
    /// signal that trying again is worthwhile. Detachment cancels this, so the
    /// loop never spins against a device that has gone.
    private func startRedialing(client: MacSessionClient, host: String, port: UInt16, udid: String) {
        // Idempotent, and it must compare against what the RUNNING LOOP is
        // dialling — not against `relayPort`.
        //
        // FOUND ON HARDWARE. The caller assigns `relayPort = port` before
        // calling this, so `relayPort == port` was always true: the guard
        // returned whenever any loop existed, and a genuinely NEW port could
        // never take effect. Quitting and relaunching the menu-bar app binds a
        // fresh ephemeral relay port, so the extension went on dialling the
        // dead one — "connection refused — nothing is listening there", every
        // five seconds, forever, while a perfectly good listener sat on the new
        // port. The bridge could not recover from an app restart.
        //
        // No test caught this because it needs two successive relay ports, and
        // every test dials one.
        // `isCancelled` is NOT "finished" — a task that returned normally
        // reports false forever. Relying on it meant a redial loop that had
        // exited still looked alive, so nothing could ever restart it.
        //
        // Observed: the loop ended at 16:54:51 with "no pairing", the user
        // paired at 16:55:14, and no session ever came up because this guard
        // kept refusing to start one. `dialingPort` is cleared by the loop on
        // its way out, so a nil there is the honest signal that nothing is
        // running. (Third time this idiom has bitten; see `USBRelay.pumps`.)
        // The host is part of the identity of "what is being dialled". Without
        // it, moving from the cable's loopback to the phone's address on the
        // hosted network would be indistinguishable from a repeat announcement
        // and the loop would go on dialling the old one.
        if dialingHost == host, dialingPort == port, dialingUDID == udid {
            return
        }
        sessionTask?.cancel()
        dialingHost = host
        dialingPort = port
        dialingUDID = udid
        // Captured up front: the task body is not isolated to this actor, so
        // reaching back for `self.log` on every line would mean an await per
        // log statement.
        let log = self.log
        sessionTask = Task { [weak self] in
            var policy = ReconnectPolicy(baseDelay: 0.5, maxDelay: 5)
            var saidUnpaired = false
            // Every exit clears the "I am dialling" marker, or the guard above
            // locks out every future attempt — a loop that ended looks exactly
            // like one that is running unless it says otherwise.
            while !Task.isCancelled {
                guard let self else { return }

                // Anything owed to a phone we unpaired while it was unplugged
                // gets said first: it has no other way to find out.
                await self.deliverPendingUnpairNotices(client: client, port: port)

                guard let device = await self.pairedDevice(matching: udid) else {
                    // Attached but not paired YET. WAITING, not returning.
                    //
                    // A pairing is someone typing six digits — it can arrive at
                    // any moment. Returning meant the session depended on an
                    // external event to restart this loop, and when the user
                    // paired at 16:55:14 nothing did: the pairing succeeded
                    // into a bridge that stayed dead.
                    if !saidUnpaired {
                        log?.error("no pairing for \(udid, privacy: .public) yet — waiting for one")
                        saidUnpaired = true
                    }
                    try? await Task.sleep(for: .seconds(2))
                    continue
                }
                saidUnpaired = false
                // Pin a legacy record to the device it just worked with.
                //
                // Records written before the wired transport carry no UDID, so
                // `pairedDevice(matching:)` lets one match any device. Leaving
                // it that way would mean a pairing that never becomes specific
                // — the UDID is the one identifier the peer cannot claim, and
                // its whole purpose is to stop a different handset bridging on
                // a key it somehow holds. Adopting it here, on the first
                // successful dial, is the migration.
                if device.udid == nil {
                    await self.adoptUDID(udid, for: device)
                }
                do {
                    try await client.runSession(
                        endpoint: NWEndpoint.hostPort(
                            host: NWEndpoint.Host(host),
                            port: NWEndpoint.Port(rawValue: port) ?? .any
                        ),
                        with: device
                    )
                    // A session that ran and ended is not a failure: the phone
                    // restarted its extension, or the screen locked. Reset, so
                    // the next drop is retried promptly rather than inheriting
                    // backoff from an unrelated earlier one.
                    policy.recordSuccess()
                    await self.noteHandshakeAccepted()
                } catch {
                    log?.error("dial failed: \(String(describing: error), privacy: .public)")
                    // A REJECTED handshake is not a transient failure.
                    //
                    // Retrying it cannot help: the phone answered and refused
                    // the identity we offered, which over the cable means its
                    // side of the pairing is gone — most often because the iOS
                    // app was reinstalled, and iOS deletes an app's keychain
                    // items with the app. The Mac keeps its half, so the two
                    // disagree and every dial fails identically.
                    //
                    // Without this the UI said "Connecting…" forever and the
                    // user had no way to learn that re-pairing was the fix.
                    if case ChannelError.handshakeFailed = error {
                        await self.noteHandshakeRejected()
                    } else {
                        await self.noteHandshakeAccepted()
                    }
                }
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(policy.recordFailure()))
            }
            await self?.clearDialing(port: port, udid: udid)
        }
    }

    /// Records the UDID a legacy pairing turned out to belong to.
    ///
    /// Only the app can write durable storage — this process cannot reach the
    /// keychain — so the in-memory copy is updated and the app picks it up on
    /// its next `devices` poll, which is the same route a fresh pairing takes.
    /// Tells any phone we unpaired while it was disconnected.
    ///
    /// Best effort and self-clearing: a notice that lands is dropped, and one
    /// that cannot be delivered expires on its own rather than making this Mac
    /// dial a phone forever.
    private func deliverPendingUnpairNotices(client: MacSessionClient, port: UInt16) async {
        tombstones.expire()
        let owed = tombstones.devicesToKeepOnAir()
        guard !owed.isEmpty else { return }
        for device in owed {
            if await client.deliverUnpairNotice(relayPort: port, to: device) {
                tombstones.delivered(device.fingerprint)
            }
        }
        tombstoneStore.save(tombstones)
    }

    /// Marks the redial loop as no longer running, so it can be restarted.
    private func clearDialing(port: UInt16, udid: String) {
        guard dialingPort == port, dialingUDID == udid else { return }
        dialingHost = nil
        dialingPort = nil
        dialingUDID = nil
    }

    private func adoptUDID(_ udid: String, for device: PairedDevice) {
        var updated = device
        updated.udid = udid
        try? store.save(updated)
        log?.error("pinned \(device.fingerprint, privacy: .public) to device \(udid, privacy: .public)")
    }

    /// Consecutive dials the phone answered and refused.
    ///
    /// Counted rather than acted on immediately: one rejection can be a race
    /// with the phone's listener rebuilding after a pairing change, and
    /// declaring "not paired" on that would be its own false alarm.
    private var consecutiveRejections = 0
    /// Rejections before the Mac stops calling it "connecting" and says the
    /// pairing is gone.
    private static let rejectionsBeforeReportingUnpaired = 3

    private func noteHandshakeRejected() {
        consecutiveRejections += 1
        if consecutiveRejections == Self.rejectionsBeforeReportingUnpaired {
            log?.error("the phone has refused \(self.consecutiveRejections, privacy: .public) handshakes — its side of the pairing is gone")
        }
    }

    private func noteHandshakeAccepted() {
        consecutiveRejections = 0
    }

    /// Whether the phone is answering but refusing this Mac's key.
    var pairingLooksGone: Bool {
        consecutiveRejections >= Self.rejectionsBeforeReportingUnpaired
    }

    /// The paired phone this UDID belongs to.
    ///
    /// Records made before the wired transport carry no UDID; such a record
    /// adopts the first device it successfully sessions with. A record that
    /// HAS a UDID must match exactly — that is the point of storing it, and it
    /// is the one identifier in the exchange the peer cannot claim for itself.
    private func pairedDevice(matching udid: String) -> PairedDevice? {
        let paired = (try? store.pairedDevices()) ?? []
        if let exact = paired.first(where: { $0.udid == udid }) { return exact }
        return paired.first { $0.udid == nil }
    }


    func stopHosting() async {
        // Cleared first: from this instant handleNewFlow stops claiming flows,
        // so traffic returns to normal even while teardown is still running.
        hasSession = false
        eventTask?.cancel()
        eventTask = nil
        sessionTask?.cancel()
        sessionTask = nil
        pairingTask?.cancel()
        pairingTask = nil
        await client?.endSession()
        client = nil
        relayPort = nil
        relayUDID = nil
        initiator = nil
        currentPolicy = CapturePolicy()
    }

    private func handle(event: SessionHostEvent, client: MacSessionClient) async {
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
            initiator = await client.initiator
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
        guard let client else {
            log?.error("ipc: no client yet — message dropped")
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
            guard let initiator else {
                // The app knows about the cable; the extension only knows
                // whether it has a session. Reporting "waiting" and letting the
                // app decide WHICH waiting it is keeps one source of truth for
                // each fact.
                if pairingLooksGone { return "refused" }
                return relayPort == nil ? "waiting" : "connecting"
            }
            let egress = await initiator.observedEgress ?? .unknown
            let peer = await client.peerDescription ?? ""
            return "connected|\(peer)|\(egress.rawValue)"
        }

        // The Disconnect button did nothing. `MenuBarModel.disconnect()` has
        // always sent this string; with no case for it, it fell through to
        // "unknown" and the only thing that changed was the menu bar label. The
        // session stayed up, the proxy went on claiming every flow, and the
        // user's one obvious way to stop bridging was a lie.
        // Undoes a Disconnect. Its own verb, because nothing else can:
        // `lastRelayUDID` deliberately survives a Disconnect so a re-announced
        // relay for the SAME cable cannot silently restart the bridge — which
        // also meant `reconnect()` could not restart it either. The Reconnect
        // menu item existed and did nothing.
        if message == "reconnect" {
            log?.error("ipc: reconnect requested")
            disconnectedByUser = false
            return "ok"
        }

        // The cable came up. Everything the extension needs to reach the phone
        // arrives in this one message: the loopback port the app is relaying,
        // and which physical device is on the other end of it.
        // THE WIRELESS BEARER. Same shape as `usbrelay:` and the same meaning —
        // everything the extension needs to reach the phone in one message —
        // except the phone is not on loopback. Over the cable the app relayed
        // usbmuxd onto a local port; over the hosted network the phone has its
        // own address and the extension dials it directly, so there is no relay
        // in the path at all.
        if message.hasPrefix("peer:") {
            let parts = message.dropFirst("peer:".count).split(separator: ":", maxSplits: 2)
            guard parts.count == 3, let port = UInt16(parts[1]) else {
                return "error|malformed peer"
            }
            let host = String(parts[0])
            let udid = String(parts[2])
            if lastRelayUDID != udid { disconnectedByUser = false }
            lastRelayUDID = udid
            guard !disconnectedByUser else {
                log?.error("ipc: peer offered but the user disconnected — not dialling")
                return "ok|disconnected"
            }
            log?.error("ipc: peer at \(host, privacy: .public):\(port, privacy: .public)")
            relayHost = host
            relayPort = port
            relayUDID = udid
            startRedialing(client: client, host: host, port: port, udid: udid)
            return "ok"
        }

        if message.hasPrefix("usbrelay:") {
            let parts = message.dropFirst("usbrelay:".count).split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let port = UInt16(parts[0]) else {
                return "error|malformed usbrelay"
            }
            let udid = String(parts[1])
            // A relay announcement for a DIFFERENT device is a new cable, which
            // is the user plainly asking to bridge again.
            //
            // Compared against `lastRelayUDID`, NOT `relayUDID`: Disconnect
            // clears `relayUDID`, so comparing that made this test always true
            // and cleared the flag before the guard below could ever see it —
            // the whole extension-side half of Disconnect was dead code, and
            // the only thing holding it was a check in the app that a
            // concurrent status poll could race past.
            if lastRelayUDID != udid { disconnectedByUser = false }
            lastRelayUDID = udid
            guard !disconnectedByUser else {
                log?.error("ipc: relay offered but the user disconnected — not dialling")
                return "ok|disconnected"
            }
            log?.error("ipc: relay on 127.0.0.1:\(port, privacy: .public) for \(udid, privacy: .public)")
            relayPort = port
            relayUDID = udid
            relayHost = "127.0.0.1"
            startRedialing(client: client, host: "127.0.0.1", port: port, udid: udid)
            return "ok"
        }

        // The cable went away. Ending the session promptly is what stops the
        // proxy claiming flows it can no longer carry — the failure mode that
        // once produced 31,034 broken pipes against a session both ends still
        // believed was healthy.
        if message == "usbgone" {
            log?.error("ipc: cable detached")
            // A physical detach clears an explicit Disconnect: replugging is
            // unambiguously "bridge again".
            disconnectedByUser = false
            relayPort = nil
            relayUDID = nil
            sessionTask?.cancel()
            sessionTask = nil
            dialingHost = nil
            dialingPort = nil
            dialingUDID = nil
            await client.endSession()
            return "ok"
        }

        if message == "disconnect" {
            log?.error("ipc: disconnect requested")
            // Cancel the redial loop as well as the session. Without that,
            // Disconnect ends one session and the loop immediately opens
            // another — the button would flicker and change nothing, which is
            // the same lie it used to tell for a different reason.
            sessionTask?.cancel()
            sessionTask = nil
            await client.endSession()
            // Deliberately switched OFF rather than merely stopped.
            //
            // Leaving `relayPort` set made `status` keep answering "connecting"
            // — so the menu bar read "Connecting…" forever, and because the
            // app only re-announces the relay when the extension reports
            // "disconnected", nothing could ever restart the loop. The only way
            // back to a working bridge was to physically unplug the cable.
            // Clearing it makes the next status poll say "disconnected", which
            // is both true and what triggers the app to hand the relay back.
            disconnectedByUser = true
            relayPort = nil
            relayUDID = nil
            dialingHost = nil
            dialingPort = nil
            dialingUDID = nil
            return "ok"
        }

        // PAIRING DIALS NOW, AND THAT CHANGES ITS SHAPE.
        //
        // The Mac shows six digits and the user walks to their phone and types
        // them. Only when they do does the phone arm its listener with the
        // matching PSK — so a single dial at the moment the code appears would
        // always fail, because the phone cannot possibly be ready yet.
        //
        // So this starts a RETRY LOOP for the life of the code. Each attempt is
        // cheap and, importantly, harmless: with no code armed the phone's
        // listener holds no pairing PSK, so the attempt dies in the TLS
        // handshake and never reaches the phone's `handlePairing`. Nothing is
        // booked against the three-guess lockout until a code genuinely matches.
        if message.hasPrefix("pair:") {
            let digits = String(message.dropFirst("pair:".count))
            pairingTask?.cancel()
            pairingTask = nil
            guard digits != "off" else { return "ok" }
            disconnectedByUser = false
            guard let port = relayPort, let udid = relayUDID else {
                log?.error("ipc: pairing attempted with no cable")
                return "error|nocable"
            }
            guard let code = try? PairingCode(digits: digits) else {
                return "error|pairing|\(PairingError.invalidCodeFormat.wireCode)"
            }
            startPairing(client: client, code: code, port: port, udid: udid)
            return "ok"
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

            if initiator != nil, await client.activeFingerprint == fingerprint {
                // Connected right now: say it directly.
                await client.announceUnpaired()
                sessionTask?.cancel()
                sessionTask = nil
                await client.endSession()
            } else if let removed {
                // NOT CONNECTED, and this is the case that used to be silent.
                //
                // The old comment here said the phone "learns on its next
                // dial". It does not: the phone never dials — this Mac does.
                // So forgetting the key and walking away left the phone holding
                // a pairing for a Mac that had forgotten it, permanently, with
                // its listener still offering that Mac's key and its UI still
                // showing a Mac that could never connect.
                //
                // The key is therefore kept just long enough for one more dial,
                // which is the exact mirror of what the phone does for a
                // revoked Mac. Delivered by `startRedialing` the next time a
                // relay is available.
                tombstones.revoke(removed)
                tombstoneStore.save(tombstones)
                log?.error("ipc: \(fingerprint, privacy: .public) removed while not connected — will tell it on the next cable")
                // If a relay is already up, tell it now rather than waiting.
                if let port = relayPort, let udid = relayUDID {
                    startRedialing(client: client, host: relayHost, port: port, udid: udid)
                }
            }
            return "ok"
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

import Foundation
import NetworkExtension
import Network
import CryptoKit
import Observation
import OSLog
import UpLinkKit

/// What the user is currently looking at.
enum BridgeState: Equatable {
    case needsPermission
    case idle
    case searching
    case connecting(String)
    case connected(peer: String, egress: EgressInterface)
    case failed(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// Drives the tunnel on the user's behalf.
///
/// The phone owns the session: the user opens the app, picks a Mac, and taps
/// Connect. The Mac is entirely passive throughout. Stopping is equally
/// explicit — there is no on-demand rule, because a bridge that turned itself
/// back on would spend the user's cellular data without being asked.
@MainActor
@Observable
final class BridgeController {

    private(set) var state: BridgeState = .idle
    private(set) var peers: [DiscoveredPeer] = []
    private(set) var pairedDevices: [PairedDevice] = []

    /// Non-nil while a pairing is in progress and the user must type a code.
    var pendingPairingPeer: DiscoveredPeer?

    /// The phone drives every session, and until now it did so in total
    /// silence: 370 lines with not one log call. When autoconnect failed the
    /// only trace was a `state` change nobody could see from a script, so a
    /// harness run that never connected looked identical to one where the Mac
    /// was at fault — and the Mac's log, which does say plenty, was searched
    /// for an answer it could not contain.
    ///
    /// Error level throughout, deliberately: info and debug live only in the
    /// memory ring buffer and are the first thing evicted by a burst, which is
    /// exactly when they are needed.
    private let log = Logger(subsystem: UpLinkIdentifiers.logSubsystem, category: "bridge")

    private var manager: NETunnelProviderManager?
    private let store = PairedDeviceStore()
    private let queue = DispatchQueue(label: "com.uplink.app")
    private var discovery: PeerDiscovery?
    private var discoveryTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var missedStatusReplies = 0
    /// The device the live session is using, so forgetting it can end it.
    private var activePeerFingerprint: String?

    init() {
        reloadPairedDevices()

        // Kicked off here rather than from the view's `.task`. A background
        // launch (`devicectl process launch`, which is how the harness drives
        // this) never presents a scene, so the view task never runs and the
        // bridge silently never starts — which cost several rounds of testing
        // that looked like connection failures and were really the harness
        // never firing. The controller is constructed at process launch, so
        // this runs either way. No-op unless UPLINK_AUTOCONNECT is set.
        if ProcessInfo.processInfo.environment["UPLINK_AUTOCONNECT"] != nil {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.startDiscovery()
                await self.autoConnectIfRequested()
            }
        }
    }

    // MARK: Permission

    /// Loads or creates the VPN configuration.
    ///
    /// Per the HIG, this is called when the user first asks to connect rather
    /// than at launch, so the system prompt arrives with obvious context
    /// instead of ambushing them on the splash screen.
    func prepare() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = managers.first ?? NETunnelProviderManager()
            if state == .needsPermission { state = .idle }
        } catch {
            state = .failed("Couldn't load VPN configuration: \(error.localizedDescription)")
        }
    }

    // MARK: Discovery

    func startDiscovery() {
        guard discovery == nil else { return }
        state = .searching

        // AWDL first when available, falling back to the local link. Which one
        // wins is decided by the Phase 0 spike; this ordering is the only place
        // that has to change.
        let discovery = PeerDiscovery(profile: TransportProfile.preferenceOrder.first ?? .localLink)
        self.discovery = discovery

        discoveryTask = Task { [weak self] in
            await discovery.start(on: self?.queue ?? .main)
            for await found in await discovery.peers() {
                await MainActor.run { self?.peers = found }
            }
        }
    }

    /// Connects without a tap, when and only when the harness asks for it.
    ///
    /// Gated behind an environment variable the app is never launched with in
    /// normal use — `devicectl … --environment-variables '{"UPLINK_AUTOCONNECT":"1"}'`.
    /// This deliberately does **not** become an on-demand rule: the product's
    /// position is that a bridge which turns itself back on spends the user's
    /// cellular data without being asked. This is a test affordance, so that
    /// "does the bridge actually carry traffic over the radio" can be answered
    /// by a script rather than by a human holding a phone.
    ///
    /// Only ever connects to an already-paired Mac; it cannot initiate pairing,
    /// which still requires a person and a code.
    func autoConnectIfRequested() async {
        let request = ProcessInfo.processInfo.environment["UPLINK_AUTOCONNECT"]

        // "stop" exists so a script can take the bridge down. Notarizing a new
        // Mac build needs working DNS, and a broken bridge is precisely what
        // breaks DNS — without this the only way out of that deadlock is to
        // pick the phone up.
        if request == "stop" {
            await prepare()
            disconnect()
            return
        }
        guard request == "1" else { return }
        log.error("autoconnect: requested, \(self.pairedDevices.count, privacy: .public) paired device(s) known")

        // Tear down any tunnel that is already running before starting a new
        // one. Reinstalling the app replaces the extension *binary*, but iOS
        // keeps the existing extension process alive and `startVPNTunnel()` on
        // an already-connected tunnel is a no-op — so a freshly deployed fix
        // silently does not run, and the harness measures the previous build
        // while reporting success. Costs a few seconds; buys a truthful test.
        await prepare()
        if let connection = manager?.connection, connection.status != .disconnected {
            connection.stopVPNTunnel()
            for _ in 0 ..< 40 {
                if connection.status == .disconnected { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        // Discovery needs a moment to populate before there is anything to pick.
        for _ in 0 ..< 60 {
            if let peer = peers.first(where: { peer in
                guard let fingerprint = peer.fingerprint else { return false }
                return pairedDevices.contains { $0.fingerprint == fingerprint }
            }) {
                log.error("autoconnect: connecting to \(peer.name, privacy: .public)")
                await connect(to: peer)
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }

        // Both counts, because they fail differently and the difference decides
        // what to do next. Nothing discovered means the Mac is not advertising
        // or is unreachable on this link; peers discovered but none of them
        // paired means the phone has lost its half of the pairing — which is
        // what reinstalling the app does — and someone has to enter a code.
        // Reporting only "no paired Mac appeared" conflates the two.
        let seen = peers.map { "\($0.name)/\($0.fingerprint ?? "no-fp")" }.joined(separator: ",")
        log.error("""
            autoconnect FAILED after 30s: \
            \(self.peers.count, privacy: .public) peer(s) discovered [\(seen, privacy: .public)], \
            \(self.pairedDevices.count, privacy: .public) paired
            """)
        state = .failed("autoconnect: no paired Mac appeared within 30s")
    }

    func stopDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = nil
        Task { [discovery] in await discovery?.stop() }
        discovery = nil
    }

    // MARK: Connect / disconnect

    func connect(to peer: DiscoveredPeer) async {
        guard let fingerprint = peer.fingerprint,
              let paired = pairedDevices.first(where: { $0.fingerprint == fingerprint })
        else {
            // Unknown Mac — the user must pair before any traffic flows.
            pendingPairingPeer = peer
            return
        }

        state = .connecting(peer.name)
        await start(with: paired, profile: peer.profile)
    }

    private func start(with device: PairedDevice, profile: TransportProfile) async {
        do {
            await prepare()
            guard let manager else { throw BridgeError.noManager }

            let identity = try store.loadOrCreateIdentity()
            let remoteKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: device.publicKey)

            // Keyed by THIS phone's fingerprint, not the Mac's. The Mac may
            // have several phones paired and offers one PSK per phone; the
            // identity we present is what selects ours.
            let localFingerprint = PairedDevice.fingerprint(of: identity.publicKey.rawRepresentation)
            let psk = try KeySchedule.sessionKey(
                localPrivate: identity,
                remotePublic: remoteKey,
                context: Data(localFingerprint.utf8)
            )

            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = "com.uplink.app.tunnel"
            // Required by NetworkExtension but unused: there is no remote
            // server, only a Mac on the local link.
            proto.serverAddress = device.name
            proto.providerConfiguration = [
                "macFingerprint": device.fingerprint,
                "localFingerprint": localFingerprint,
                "preSharedKey": psk.withUnsafeBytes { Data($0) },
                "profile": profile.rawValue,
            ]

            manager.protocolConfiguration = proto
            manager.localizedDescription = "UpLink — \(device.name)"
            manager.isEnabled = true
            // Deliberately no on-demand rules.
            manager.onDemandRules = []
            manager.isOnDemandEnabled = false

            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            try manager.connection.startVPNTunnel()

            // Egress starts unknown and is corrected by the status poll below.
            // It must never be left at the placeholder: the dial reads the
            // interface the connection actually used, and that observation is
            // the user's only evidence that they are bypassing anything. An
            // earlier version set this once and never updated it, so the phone
            // permanently warned "not going over cellular" while the Mac was
            // correctly reporting Cellular.
            // Deliberately NOT `.connected` yet. `startVPNTunnel()` only means
            // the request was accepted; the tunnel still has to come up, find
            // the Mac and complete a handshake, any of which can fail. Claiming
            // success here is what let the UI show "connected" while nothing
            // was connected — and an unreliable indicator makes every test
            // afterwards meaningless.
            state = .connecting(device.name)
            activePeerFingerprint = device.fingerprint
            startStatusPolling(peer: device.name)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func disconnect() {
        statusTask?.cancel()
        statusTask = nil
        missedStatusReplies = 0
        activePeerFingerprint = nil
        manager?.connection.stopVPNTunnel()
        state = .idle
    }

    /// Asks the extension what it is actually observing.
    ///
    /// Provider messages are request/response only — the extension cannot push
    /// — so the app polls, exactly as the Mac's menu bar does. Once a second is
    /// imperceptible and keeps the warning honest.
    private func startStatusPolling(peer: String) {
        statusTask?.cancel()
        statusTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refreshStatus(peer: peer)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// The extension's own account of what it has been doing.
    ///
    /// This exists because every cable-free failure so far has been diagnosed by
    /// inference from the Mac's silence. The file the extension writes needs a
    /// cable to retrieve, and `log collect` needs root AND fights devicectl for
    /// the device ("Device not configured"), so on the one configuration this
    /// product exists for there was no way to read the phone's side at all.
    /// Reading it on the phone itself needs neither.
    func fetchDiagnostics() async -> String {
        guard let session = manager?.connection as? NETunnelProviderSession else {
            return "The tunnel is not running, so it has nothing to report.\n\nConnect first, then come back."
        }
        let reply: String? = await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(Data("diagnostics".utf8)) { data in
                    continuation.resume(returning: data.flatMap { String(data: $0, encoding: .utf8) })
                }
            } catch {
                continuation.resume(returning: "Could not ask the extension: \(error)")
            }
        }
        return reply ?? "The extension did not answer."
    }

    private func refreshStatus(peer: String) async {
        guard let session = manager?.connection as? NETunnelProviderSession else { return }

        let response: String? = await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(Data("status".utf8)) { data in
                    continuation.resume(returning: data.flatMap { String(data: $0, encoding: .utf8) })
                }
            } catch {
                continuation.resume(returning: nil)
            }
        }

        // A missing reply is not proof of anything on its own — the extension
        // may simply be busy — but several in a row means it is gone.
        guard let response else {
            missedStatusReplies += 1
            if missedStatusReplies >= 3, state.isConnected {
                state = .connecting(peer)
            }
            return
        }
        missedStatusReplies = 0

        // Shared parser: this used to `return` on anything but "connected",
        // so a "disconnected" reply left the UI showing a connection that had
        // already ended. Believing the extension in both directions is the
        // whole point of asking it.
        switch BridgeStatusReply.parse(response) {
        case let .connected(_, egress):
            let updated = BridgeState.connected(peer: peer, egress: egress)
            if state != updated { state = updated }
        case .disconnected:
            if state.isConnected { state = .connecting(peer) }
        case .unpaired:
            // The Mac has removed this phone. Retrying is pointless — its
            // listener no longer holds our key — and without acting on it the
            // phone dials forever into a refused handshake, which is exactly
            // what made the two devices disagree about whether they were
            // connected.
            await forgetPeerAfterRemoteUnpair()
        case .unintelligible:
            break  // ask again rather than act on noise
        }
    }

    /// Drops our half of a pairing the Mac has already dropped.
    private func forgetPeerAfterRemoteUnpair() async {
        guard let fingerprint = activePeerFingerprint else {
            disconnect()
            return
        }
        try? store.remove(fingerprint: fingerprint)
        reloadPairedDevices()
        disconnect()
        state = .failed("This Mac removed this iPhone. Pair again to reconnect.")
    }

    // MARK: Pairing

    /// Completes pairing with the code the user typed.
    func completePairing(peer: DiscoveredPeer, code: String) async {
        do {
            let parsed = try PairingCode(digits: code)
            let identity = try store.loadOrCreateIdentity()

            // The pairing session authenticates with the code, and its only
            // job is to carry the long-term key exchange. Everything after
            // this uses the 256-bit derived key.
            let device = try await PairingClient(queue: queue).pair(
                with: peer,
                code: parsed,
                localIdentity: identity
            )

            try store.save(device)
            reloadPairedDevices()
            pendingPairingPeer = nil

            await connect(to: peer)
        } catch {
            state = .failed(pairingMessage(for: error))
        }
    }

    private func pairingMessage(for error: Error) -> String {
        switch error {
        case PairingError.invalidCodeFormat:
            "That code doesn't look right — it should be six digits."
        case PairingError.codeMismatch:
            "That code didn't match. Check your Mac and try again."
        case PairingError.expired:
            "That code expired. Ask your Mac for a new one."
        case PairingError.tooManyAttempts:
            "Too many attempts. Generate a fresh code on your Mac."
        default:
            error.localizedDescription
        }
    }

    /// Forgetting a device must also stop using it.
    ///
    /// Removing it from the store alone left the tunnel running on keys the
    /// user had just revoked, and the UI kept saying "connected" — so the state
    /// on screen no longer described anything real.
    func unpair(_ device: PairedDevice) {
        // Tell the Mac FIRST, while a session still exists to carry the notice.
        // Stopping first — which is what this used to do — guarantees it is
        // never delivered, so the Mac keeps the phone in its paired list and
        // keeps advertising a key the user has just revoked.
        Task { [weak self] in
            if self?.activePeerFingerprint == device.fingerprint || self?.state.isConnected == true {
                _ = await self?.sendProviderMessage("unpair")
            }
            await MainActor.run {
                guard let self else { return }
                if self.activePeerFingerprint == device.fingerprint || self.state.isConnected {
                    self.disconnect()
                }
                try? self.store.remove(fingerprint: device.fingerprint)
                self.reloadPairedDevices()
            }
        }
    }

    /// One-shot provider message, for verbs whose reply is only an ack.
    private func sendProviderMessage(_ message: String) async -> String? {
        guard let session = manager?.connection as? NETunnelProviderSession else { return nil }
        return await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(Data(message.utf8)) { data in
                    continuation.resume(returning: data.flatMap { String(data: $0, encoding: .utf8) })
                }
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    private func reloadPairedDevices() {
        pairedDevices = (try? store.pairedDevices()) ?? []
    }
}

enum BridgeError: Error {
    case noManager
}

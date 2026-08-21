import Foundation
import NetworkExtension
import Network
import CryptoKit
import Observation
import OSLog
import UpLinkKit

/// What the user is currently looking at.
///
/// **The phone is passive now.** `usbmuxd` carries connections one way only, so
/// the Mac dials and this phone listens. There is nothing to search for and
/// nothing to pick: either a Mac is bridging through us or one is not, and the
/// only thing the user can influence is whether the listener is up.
enum BridgeState: Equatable {
    case needsPermission
    /// The bridge is switched off. Nothing is listening.
    case idle
    /// Listening, with no Mac connected. Start the network on the Mac.
    case waitingForMac
    case connected(peer: String, egress: EgressInterface)
    case failed(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// Drives the tunnel on the user's behalf.
///
/// The user switches the bridge on, and the extension then listens on a
/// loopback port that `usbmuxd` exposes to whatever Mac is plugged in. Starting
/// is explicit — there is no on-demand rule, because a bridge that turned
/// itself back on would spend the user's cellular data without being asked —
/// but nothing else is: once it is on, plugging in the cable is the whole
/// interaction.
@MainActor
@Observable
final class BridgeController {

    private(set) var state: BridgeState = .idle
    private(set) var pairedDevices: [PairedDevice] = []

    /// True while the pairing sheet is up and the user is typing the code they
    /// read off the Mac.
    var isPairing = false

    /// Set when the bridge cannot start because nobody has told this phone the
    /// Mac network's password yet. Asked once; every start after that is a tap.
    var needsNetworkPassword = false

    private static let passwordKey = "UpLinkNetworkPassword"
    private static let turnedOffKey = "UpLinkUserTurnedOff"

    /// Whether the user's last deliberate act was to switch the bridge off.
    ///
    /// Remembered so that reconnecting can be automatic without ever overriding
    /// a choice: an app that switches itself back on after being switched off
    /// is not convenient, it is disobedient.
    private var userTurnedOff: Bool {
        get { UserDefaults.standard.bool(forKey: Self.turnedOffKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.turnedOffKey) }
    }

    /// Brings the bridge up on launch, without being asked.
    ///
    /// The product's whole claim is a Mac in the back of a car and no
    /// interaction beyond picking up the phone. Two taps was already close;
    /// this makes it none — open the app and it connects, because there is
    /// nothing else the user could plausibly want when they open it with a
    /// paired Mac and a stored password.
    ///
    /// Deliberately silent about failure. If the Mac is not there, the ordinary
    /// waiting state says so, and an alert on launch would be noise every time
    /// the app is opened out of range.
    func connectIfReady() async {
        guard !userTurnedOff else { return }
        guard !pairedDevices.isEmpty, networkPassword != nil else { return }
        guard case .idle = state else { return }
        diagnostics.write("auto-connect: paired Mac and password present")
        await startBridge()
    }

    /// The Mac network's password, as the user typed it once.
    ///
    /// It has to be asked for rather than discovered. macOS keeps the hosted
    /// network's password where SIP forbids reading it even as root, so the Mac
    /// cannot look it up to send here — see AccessPointJoin.
    var networkPassword: String? {
        get { UserDefaults.standard.string(forKey: Self.passwordKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.passwordKey) }
    }

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
    /// The same shared-container log the extension writes to.
    ///
    /// The app's own os.Logger lines cannot be read back off the device without
    /// a cable, which is exactly what this bearer removes — so anything worth
    /// knowing after the fact has to go here instead.
    private let diagnostics = PhoneDiagnosticLog.shared
    /// The Bluetooth doorbell. See ``AccessPointRemote``.
    private let remote = AccessPointRemote()

    private var manager: NETunnelProviderManager?
    private let store = PairedDeviceStore()
    private let queue = DispatchQueue(label: "com.uplink.app")
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
        let environment = ProcessInfo.processInfo.environment
        if environment["UPLINK_AUTOCONNECT"] != nil
            || environment["UPLINK_AUTOPAIR"] != nil
            || environment["UPLINK_AUTOUNPAIR"] != nil {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.runPairingHarnessIfRequested()
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

    // MARK: Headless harness
    //
    // The pairing lifecycle — pair, remove on both devices, pair again — is the
    // flow that has actually been broken, and the only way to exercise it used
    // to be a person holding a phone and reading a code off a Mac screen. That
    // made every check a one-off, which is how a half-removed pairing kept
    // poisoning later measurements.
    //
    // Neither hook can run without someone having put a code on the Mac's
    // screen, so this is not a way to pair without consent — it is a way to
    // type the code without a human thumb.

    /// `UPLINK_AUTOUNPAIR=1` forgets every paired Mac.
    /// `UPLINK_AUTOPAIR=<six digits>` arms the listener with that code.
    func runPairingHarnessIfRequested() async {
        let environment = ProcessInfo.processInfo.environment

        if environment["UPLINK_AUTOUNPAIR"] == "1" {
            log.error("harness: unpairing \(self.pairedDevices.count, privacy: .public) device(s)")
            for device in pairedDevices { unpair(device) }
            // `unpair` hops through a Task to message the extension first.
            try? await Task.sleep(for: .seconds(2))
            reloadPairedDevices()
            log.error("harness: \(self.pairedDevices.count, privacy: .public) device(s) remain")
        }

        guard let digits = environment["UPLINK_AUTOPAIR"] else { return }
        log.error("harness: arming pairing with code \(digits, privacy: .public)")

        // The listener has to be up before a code can be armed, and the Mac has
        // to be able to dial it. Starting the bridge is part of the harness's
        // job for the same reason it is part of the user's.
        if !isRunning { await startBridge() }
        for _ in 0 ..< 40 {
            if isRunning { break }
            try? await Task.sleep(for: .milliseconds(250))
        }

        if let message = await completePairing(code: digits) {
            log.error("harness: PAIRING FAILED — \(message, privacy: .public)")
            return
        }
        // Armed is not paired. The Mac still has to dial, so the harness waits
        // for the record to appear rather than declaring success on the arming.
        for _ in 0 ..< 60 {
            try? await Task.sleep(for: .seconds(1))
            reloadPairedDevices()
            if let device = pairedDevices.first {
                log.error("harness: PAIRED with \(device.name, privacy: .public); now \(self.pairedDevices.count, privacy: .public) device(s)")
                return
            }
        }
        log.error("harness: PAIRING FAILED — code armed but no Mac dialled within 60s")
    }

    /// `UPLINK_AUTOCONNECT=1` switches the bridge on; `stop` switches it off.
    ///
    /// Gated behind an environment variable the app is never launched with in
    /// normal use. This deliberately does **not** become an on-demand rule: a
    /// bridge that turns itself back on spends the user's cellular data without
    /// being asked.
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

        await startBridge()

        // The phone is passive, so "connected" is not something it can bring
        // about — it can only be listening and wait for the Mac to dial. Report
        // both facts, because they fail differently: no listener is a phone
        // problem, a listener with no session is a cable or Mac problem.
        for _ in 0 ..< 60 {
            if state.isConnected {
                log.error("autoconnect: a Mac is bridging")
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        log.error("""
            autoconnect: listening but no Mac dialled within 30s — \
            \(self.pairedDevices.count, privacy: .public) paired device(s); \
            check the UpLink network is started and UpLink is running on the Mac
            """)
    }

    /// Whether the user has UpLink switched on.
    ///
    /// **Intent, not machinery, and that distinction was the bug.** The one
    /// button on this screen used to be driven by `state` for its first branch
    /// and by the tunnel's `NEVPNStatus` for its second, so a single tap walked
    /// it through three different words: "Stop Bridging" became "Turn Off"
    /// — because `disconnect()` sets `state` immediately while the tunnel takes
    /// a moment to actually stop — and only then "Turn On". It read as though
    /// switching UpLink off took two presses and two different verbs.
    ///
    /// There is only one switch here, so it is derived from one thing. Whether
    /// a Mac happens to be connected right now is status, and belongs on the
    /// dial above; it is not a different mode with a different verb.
    var isOn: Bool { condition != .off && condition != .needsPermission }

    /// The phone's state as the switch sees it — coarser than ``BridgeState``,
    /// because the switch does not care which Mac is on the other end.
    ///
    /// The decision itself lives in ``PhoneControlResolver``, in the kit, so it
    /// is provable without a device. It used to be inline in the SwiftUI view,
    /// where nothing could reach it.
    var condition: PhoneBridgeCondition {
        switch state {
        case .needsPermission: .needsPermission
        case .idle: .off
        case .waitingForMac: .listening
        case .connected: .bridging
        case .failed: .failed
        }
    }

    /// What the one control on the screen should offer.
    var control: PhoneControl { PhoneControlResolver.control(for: condition) }

    /// Whether the tunnel is up, which is what puts the listener on the air.
    ///
    /// Machinery, for the pairing and autoconnect paths. **Not for the button**
    /// — see ``isOn``.
    var isRunning: Bool {
        switch manager?.connection.status {
        case .connected, .connecting: true
        default: false
        }
    }

    // MARK: Switching the bridge on

    /// Starts the tunnel, which is what puts the listener on the air.
    ///
    /// No peer is chosen and none is configured: the extension binds a loopback
    /// port and waits for whatever Mac is plugged in to dial it. That is also
    /// what makes a FIRST pairing possible — the Mac has to be able to reach
    /// something before any pairing exists, so the listener must come up
    /// unpaired and refuse every handshake until a code is typed.
    func startBridge() async {
        userTurnedOff = false
        do {
            await prepare()
            guard let manager else { throw BridgeError.noManager }

            // JOIN FIRST, THEN TUNNEL. The Mac is only reachable over the
            // network it hosts, so starting the tunnel before joining gives the
            // extension a listener nothing can dial — which looks exactly like
            // a Mac that is not running.
            //
            // This is the step that makes the whole thing one tap. Without it
            // the user joins the network by hand in Settings first, which is
            // the friction the product exists to remove.
            // RING THE DOORBELL FIRST. The Mac may not be hosting yet, and if it
            // is not, no amount of joining will find a network. This is the one
            // request that cannot travel over the access point, because the
            // access point is what it is asking for.
            let delivered = await remote.send(.raiseAccessPoint)
            diagnostics.write(delivered
                ? "remote: asked the Mac to start its network"
                : "remote: no Mac answered over Bluetooth — trying the network anyway")

            if let password = networkPassword {
                do {
                    // Retried, because raising takes several seconds: measured
                    // 2026-08-20, bridge100 appeared about ten seconds after the
                    // helper was asked. A single attempt lands in that gap and
                    // fails with "no network name matched", which reads as a
                    // wrong password and is not one.
                    try await joinWithRetry(passphrase: password, attempts: delivered ? 8 : 2)
                    diagnostics.write("join: OK (prefix \(AccessPointCredentials.ssidPrefix))")
                } catch {
                    // Written where it can be read back. A join that fails
                    // silently leaves the phone off the network entirely while
                    // the Mac goes on dialling the address in a DHCP lease that
                    // outlived the association — which reads as a listener
                    // problem and is not one.
                    diagnostics.write("join FAILED: \(error)")
                    log.error("join: \(String(describing: error), privacy: .public)")
                }
            } else {
                diagnostics.write("join SKIPPED: no network password stored yet")
                needsNetworkPassword = true
            }

            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = "com.uplink.app.tunnel"
            // Required by NetworkExtension but meaningless here: there is no
            // remote server, only a Mac on the other end of a cable.
            proto.serverAddress = "UpLink"
            // Deliberately EMPTY. The extension reads its identity and its
            // paired Macs straight from the keychain — on iOS an app extension
            // shares the app's access group — so there is nothing to seed and
            // no snapshot to go stale.
            proto.providerConfiguration = [:]

            manager.protocolConfiguration = proto
            manager.localizedDescription = "UpLink"
            manager.isEnabled = true
            // Deliberately no on-demand rules.
            manager.onDemandRules = []
            manager.isOnDemandEnabled = false

            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            try manager.connection.startVPNTunnel()

            // Deliberately NOT `.connected`. `startVPNTunnel()` only means the
            // request was accepted; the listener still has to bind, and a Mac
            // still has to dial it. Claiming success here is what let the UI
            // show a connection that did not exist.
            state = .waitingForMac
            startStatusPolling()
            watchTunnelComesUp()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: Connect / disconnect



    func disconnect() {
        userTurnedOff = true
        statusTask?.cancel()
        statusTask = nil
        missedStatusReplies = 0
        activePeerFingerprint = nil
        manager?.connection.stopVPNTunnel()
        state = .idle

        // Give the Mac its own Wi-Fi back.
        //
        // Sent over Bluetooth rather than the bridge, deliberately: the bridge
        // is being torn down as this runs, so a message down it would race the
        // teardown and lose. The doorbell is still there either way.
        //
        // Fire and forget. If the Mac does not hear it the worst case is an
        // access point left running, which is the state it is designed to sit
        // in anyway — never a failure the user has to act on.
        Task { [remote] in
            _ = await remote.send(.lowerAccessPoint)
        }
    }

    /// Asks the extension what it is actually observing.
    ///
    /// Provider messages are request/response only — the extension cannot push
    /// — so the app polls, exactly as the Mac's menu bar does. Once a second is
    /// imperceptible and keeps the warning honest.
    /// Reports a tunnel that was accepted and never actually came up.
    ///
    /// `startVPNTunnel()` returning means the REQUEST was accepted, nothing
    /// more — so the UI has always said "waiting for the Mac" from that moment.
    /// When the extension then never launches, that sentence is wrong and never
    /// changes, and the screen sits there indefinitely with no way to tell that
    /// anything is wrong. Observed on hardware 2026-08-20: the Mac dialled
    /// 192.168.2.2 and timed out every 12 seconds against a phone whose
    /// listener had never started.
    ///
    /// **iOS runs one packet tunnel at a time.** Another VPN holding it is the
    /// most common reason this happens, and it is invisible from inside this
    /// app — we can see that ours did not start, not who has it. So the message
    /// names the likely cause rather than asserting it.
    private func watchTunnelComesUp() {
        tunnelWatchTask?.cancel()
        tunnelWatchTask = Task { [weak self] in
            for _ in 0 ..< 15 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                guard case .waitingForMac = state else { return }
                switch manager?.connection.status {
                case .connected, .connecting, .reasserting:
                    return
                default:
                    continue
                }
            }
            guard let self, case .waitingForMac = state else { return }
            guard manager?.connection.status != .connected else { return }
            log.error("tunnel never came up; status \(String(describing: self.manager?.connection.status), privacy: .public)")
            state = .failed(
                "UpLink could not start its network extension. iOS runs one VPN "
                + "at a time — if another VPN is on, turn it off and try again."
            )
        }
    }

    private var tunnelWatchTaskStorage: Task<Void, Never>?
    private var tunnelWatchTask: Task<Void, Never>? {
        get { tunnelWatchTaskStorage }
        set { tunnelWatchTaskStorage?.cancel(); tunnelWatchTaskStorage = newValue }
    }

    /// Joins, retrying while the Mac's network is still coming up.
    private func joinWithRetry(passphrase: String, attempts: Int) async throws {
        var lastError: Error?
        for attempt in 1 ... max(1, attempts) {
            do {
                try await AccessPointJoin.join(passphrase: passphrase)
                return
            } catch {
                lastError = error
                // Only worth retrying while the network might still be
                // appearing. A refused password will never become a right one.
                if case AccessPointJoin.Failure.denied = error { throw error }
                diagnostics.write("join attempt \(attempt) failed: \(error)")
                try? await Task.sleep(for: .seconds(2))
            }
        }
        throw lastError ?? AccessPointJoin.Failure.failed("join did not succeed")
    }

    private func startStatusPolling() {
        statusTask?.cancel()
        statusTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refreshStatus()
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
    ///
    /// **No longer a screen.** It was a stethoscope button in the toolbar, which
    /// put a wall of extension log in front of a user who has no use for it. The
    /// report is still fetched — it just informs the app instead of the user,
    /// which is the only thing it was ever good for. See ``diagnoseSilence()``.
    private func fetchDiagnostics() async -> String? {
        guard let session = manager?.connection as? NETunnelProviderSession else { return nil }
        return await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(Data("diagnostics".utf8)) { data in
                    continuation.resume(returning: data.flatMap { String(data: $0, encoding: .utf8) })
                }
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    /// Works out what the extension going quiet actually means, by asking it.
    ///
    /// **Two very different faults look identical from here.** The extension not
    /// answering `status` can mean it is healthy and simply has no session to
    /// report — a cable or Mac problem, nothing for this phone to do — or that
    /// the extension is wedged or gone, which is a phone problem and the user's
    /// to act on. Guessing between them is what produced "Waiting for your Mac"
    /// at a user whose phone was the thing at fault.
    ///
    /// `diagnostics` is answered synchronously from a file read rather than from
    /// the session machinery, precisely so it still comes back when `status`
    /// does not. That is what makes it able to tell these apart.
    private func diagnoseSilence() async {
        guard !hasDiagnosedSilence else { return }
        hasDiagnosedSilence = true

        guard let report = await fetchDiagnostics() else {
            log.error("status has gone quiet AND diagnostics did not answer — the extension is not running")
            state = .failed("UpLink's background service stopped. Turn it off and on again.")
            return
        }

        // Logged whole, at error level, because this is the report that used to
        // require a cable and root to obtain.
        log.error("status quiet; phone-side report follows:\n\(report, privacy: .public)")

        if report.contains("extension running"), report.contains("listening on") {
            // The phone is fine and on the air. The gap is on the other side of
            // the cable, so say the true thing rather than blaming this device.
            log.error("the extension is up and listening — treating this as a cable or Mac problem")
            if state.isConnected { state = .waitingForMac }
        } else {
            state = .failed("UpLink's background service is not listening. Turn it off and on again.")
        }
    }

    /// Set while an outage is being explained, so the report is fetched once per
    /// outage rather than once a second for the length of it.
    private var hasDiagnosedSilence = false

    private func refreshStatus() async {
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
        // may simply be busy — but several in a row means something is wrong.
        //
        // WHICH thing is wrong is not guessable from here, and this used to
        // guess: it assumed a healthy extension with no session and showed
        // "Waiting for your Mac", which is a lie when the extension is the thing
        // that died. `diagnoseSilence()` asks the extension directly, on the
        // path that still answers when this one does not.
        guard let response else {
            missedStatusReplies += 1
            // ONLY ONCE THE TUNNEL IS FULLY UP. While it is `.connecting` the
            // extension legitimately has not started answering yet, and three
            // seconds of that is normal startup — the old code was accidentally
            // safe here because it only acted when a session was already live,
            // and moving the decision without moving that guard would turn every
            // launch into a reported failure.
            if missedStatusReplies >= 3, manager?.connection.status == .connected {
                await diagnoseSilence()
            }
            return
        }
        missedStatusReplies = 0
        hasDiagnosedSilence = false

        // Shared parser: this used to `return` on anything but "connected",
        // so a "disconnected" reply left the UI showing a connection that had
        // already ended. Believing the extension in both directions is the
        // whole point of asking it.
        switch BridgeStatusReply.parse(response) {
        case let .connected(fingerprint, egress):
            // The name comes from our own paired record, not from the wire: the
            // extension reports a fingerprint, which is the thing it can prove.
            let name = pairedDevices.first { $0.fingerprint == fingerprint }?.name ?? "Mac"
            let updated = BridgeState.connected(peer: name, egress: egress)
            if state != updated { state = updated }
            activePeerFingerprint = fingerprint
        case .disconnected:
            if state != .idle { state = .waitingForMac }
            activePeerFingerprint = nil
        case let .unpaired(fingerprint):
            // ADDRESSED. The reply names WHICH Mac forgot us, and the phone
            // must act on that one — it used to ignore the field entirely and
            // remove `activePeerFingerprint` instead, so a notice about Mac A
            // arriving while Mac B was bridging deleted **B's** pairing and
            // then stopped the whole tunnel, taking the listener off the air
            // for every other paired Mac. The Mac's own side bound the
            // fingerprint correctly all along; this was a one-sided asymmetry.
            await forgetPeerAfterRemoteUnpair(fingerprint: fingerprint)
        case .connecting:
            // The Mac's vocabulary, not the phone's. Handled so the switch
            // stays exhaustive and a future sender is not silently ignored.
            break

        case .refused:
            // The phone listens now, so a refusal is the MAC's to report, not
            // ours. Kept so the switch stays exhaustive and a future sender is
            // not silently ignored.
            break
        case .unintelligible:
            break  // ask again rather than act on noise
        }
    }

    /// Re-reads durable storage.
    ///
    /// The store is read once at process launch, and keychain items use
    /// `kSecAttrAccessibleAfterFirstUnlock` — so a launch before the first
    /// unlock returns nothing, `(try? …) ?? []` turns that into "no paired
    /// Macs", and nothing ever looked again. The phone then treated a Mac it
    /// was genuinely paired with as a stranger and offered to pair afresh.
    func refreshFromStore() {
        reloadPairedDevices()
    }

    /// Drops our half of a pairing the named Mac has already dropped.
    ///
    /// - Parameter fingerprint: which Mac. Nil only from an older extension
    ///   that sent a bare "unpaired"; in that case there is nothing safe to
    ///   remove, so the notice is logged and dropped rather than guessed at.
    private func forgetPeerAfterRemoteUnpair(fingerprint: String?) async {
        guard let fingerprint, !fingerprint.isEmpty else {
            log.error("unpaired notice with no fingerprint — ignoring rather than guessing")
            return
        }
        do {
            try store.remove(fingerprint: fingerprint)
        } catch {
            // Otherwise the phone says it has forgotten a Mac it still holds
            // the key for, and the row reappears with no explanation.
            state = .failed(error.localizedDescription)
            return
        }
        reloadPairedDevices()

        // Only if it was THIS Mac bridging. Stopping the tunnel outright took
        // the listener off the air for every other paired Mac — one Mac
        // forgetting us is not a reason to stop being reachable by the rest.
        if activePeerFingerprint == fingerprint {
            activePeerFingerprint = nil
            state = .waitingForMac
        }
        // Deliberately no message: the device simply disappears from both
        // lists, which is the agreed behaviour.
    }

    // MARK: Pairing

    /// Completes pairing with the code the user typed.
    /// Returns nil on success, or the message to show IN the sheet.
    ///
    /// It used to return nothing and set `state = .failed(...)`, while
    /// `pendingPairingPeer` was cleared only on the success path — so the sheet
    /// stayed presented on top of the message it had just written. The user
    /// typed a code, the spinner stopped, and nothing appeared to happen. The
    /// only rational response is to try again, which is exactly what was
    /// reported: "re-pairing fails and I have to retry several times."
    /// Arms the listener with the code the user read off the Mac.
    ///
    /// **The phone no longer runs the handshake.** The Mac dials, so typing the
    /// code here does one thing: it puts the matching PSK into the extension's
    /// TLS options so the Mac's dial can succeed. The pairing itself completes
    /// a moment later, on the Mac's side, and arrives back here as a new record
    /// in the shared keychain.
    ///
    /// Returns nil once the code is armed, or the message to show IN the sheet.
    /// Deliberately not `state = .failed(...)`: the sheet is still up and would
    /// hide it, which is what made a failed pairing look like nothing happening
    /// at all — and the only rational response to that is to try again, which
    /// is exactly what was reported.
    @discardableResult
    func completePairing(code: String) async -> String? {
        do {
            // Parsed here so a malformed code is rejected before the tunnel is
            // involved, and the message names the actual problem.
            _ = try PairingCode(digits: code)
        } catch {
            return pairingMessage(for: error)
        }

        guard let session = manager?.connection as? NETunnelProviderSession,
              manager?.connection.status == .connected || manager?.connection.status == .connecting
        else {
            return "Turn UpLink on first, then enter the code."
        }

        let reply: String? = await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(Data("pair:\(code)".utf8)) { data in
                    continuation.resume(returning: data.flatMap { String(data: $0, encoding: .utf8) })
                }
            } catch {
                continuation.resume(returning: "error|\(error)")
            }
        }

        guard reply == "ok" else {
            return "Couldn't get ready to pair. \(reply ?? "The bridge didn't answer.")"
        }

        // Armed. The Mac has 60 seconds to dial; the sheet closes and the
        // paired list fills in when it does.
        isPairing = false
        // Pick up the new record as soon as the Mac writes it.
        Task { [weak self] in
            for _ in 0 ..< 60 {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.reloadPairedDevices()
                if !self.pairedDevices.isEmpty { return }
            }
        }
        return nil
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
            // ADDRESSED, and sent ALWAYS — not only when this Mac is the live
            // session.
            //
            // The address matters: a bare "unpair" made the extension act on
            // whichever session was live, so deleting Mac B while bridging Mac
            // A told A it had been unpaired. But gating the message on the
            // device being live was the opposite mistake, and it made the whole
            // tombstone path dead code. Removing a Mac that is NOT connected is
            // precisely the case that needs the extension: it is the side that
            // holds the listener, so it is the only thing that can keep that
            // Mac's key on the air long enough to tell it, and the only thing
            // that can rebuild the listener so the key stops being offered.
            // Without this the removed Mac is never told and redials forever
            // into a refusal nothing explains.
            _ = await self?.sendProviderMessage("unpair:\(device.fingerprint)")

            await MainActor.run {
                guard let self else { return }
                // Only if it was THIS device bridging. `state.isConnected` is
                // true whenever any Mac is connected, so testing it here tore
                // down a healthy bridge with Mac A because the user removed
                // Mac B — the exact cross-talk the addressing above prevents.
                if self.activePeerFingerprint == device.fingerprint {
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

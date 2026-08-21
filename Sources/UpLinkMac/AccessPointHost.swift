import Foundation
import ServiceManagement
import UpLinkKit
import OSLog

/// The app's side of the privileged helper.
///
/// Registration is one call and is idempotent, so it is safe on every launch —
/// the user approves it once, in the same System Settings panel that already
/// approves the network extension.
@MainActor
final class AccessPointHost {

    private let log = Logger(subsystem: UpLinkIdentifiers.logSubsystem, category: "ap")
    private static let plistName = "com.uplink.app.helper.plist"

    private var connection: NSXPCConnection?

    private static let ssidKey = "UpLinkAccessPointSSID"
    private static let passphraseKey = "UpLinkAccessPointPassphrase"
    private static let identityKey = "UpLinkAccessPointIdentity"

    /// The network this Mac hosts. Generated once and then stable forever.
    ///
    /// Stability is the whole point rather than tidiness: iOS keys a saved
    /// hotspot configuration by SSID, so a name that changed would silently
    /// stop the phone re-joining on its own — and re-joining on its own is the
    /// behaviour the product is built around. Regenerating the passphrase would
    /// break it the same way, from the other end.
    var credentials: AccessPointCredentials {
        let defaults = UserDefaults.standard
        if let ssid = defaults.string(forKey: Self.ssidKey),
           let passphrase = defaults.string(forKey: Self.passphraseKey) {
            return AccessPointCredentials(ssid: ssid, passphrase: passphrase)
        }

        // A stable per-Mac identity, so the SSID is this Mac's and not a
        // constant two UpLink Macs in range would both answer to.
        let identity = defaults.string(forKey: Self.identityKey)
            ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(identity, forKey: Self.identityKey)

        let created = AccessPointCredentials(
            ssid: AccessPointCredentials.ssid(forFingerprint: identity),
            passphrase: AccessPointCredentials.generatePassphrase()
        )
        defaults.set(created.ssid, forKey: Self.ssidKey)
        defaults.set(created.passphrase, forKey: Self.passphraseKey)
        log.info("access point credentials created for \(created.ssid, privacy: .public)")
        return created
    }

    /// Replaces a helper still running an older build of this app.
    ///
    /// **Replacing the app does not restart a running LaunchDaemon**, and
    /// nothing short of root can restart one — `launchctl kickstart` answers
    /// "Operation not permitted". So the daemon goes on running whatever binary
    /// it started with, indefinitely, while the app, the code on disk and every
    /// version string all say otherwise. Fixes were shipped to a machine that
    /// never loaded them for most of a night, and every symptom pointed at code
    /// that was not executing.
    ///
    /// Unregistering and registering again is the one restart an unprivileged
    /// app can perform. The service is already approved, so this does not ask
    /// the user for anything.
    func reportIfStale() async {
        guard isRegistered else { return }
        let mine = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let theirs = await build()

        // A helper too old to answer at all is exactly the case this exists
        // for, so a nil is treated as stale rather than as a reason to stop.
        guard theirs != mine else { return }

        // SAID, NOT ACTED ON, and that is the correction.
        //
        // This used to unregister and register again, which is the only restart
        // an unprivileged app can perform on a system daemon. It works, and it
        // returns the service to *needing approval* — so the helper does not
        // come back until the user visits Login Items. Measured 2026-08-21: it
        // left the machine with no helper at all, which is strictly worse than
        // the stale one it replaced. A repair that can leave the system worse
        // than it found it must not run unattended.
        //
        // A stale helper still works; it is working from an older idea of what
        // to do. So the drift is reported and the user decides.
        isStale = true
        log.error(
            "helper is build \(theirs ?? "too old to say", privacy: .public), app is \(mine, privacy: .public) — toggle UpLink off and on in Login Items to update it"
        )
    }

    /// Whether the running helper predates this build. Surfaced in the menu, so
    /// it is visible rather than buried in a log nobody reads.
    private(set) var isStale = false

    /// The build the running helper was launched from, or nil if it is too old
    /// to say.
    private func build() async -> String? {
        await withCheckedContinuation { continuation in
            proxy { helper, _ in
                guard let helper else { return continuation.resume(returning: nil) }
                helper.helperBuild { continuation.resume(returning: $0) }
            }
        }
    }

    /// Records the password the user set on the network in System Settings.
    func setPassphrase(_ passphrase: String) {
        UserDefaults.standard.set(passphrase, forKey: Self.passphraseKey)
        log.info("access point passphrase updated")
    }

    /// Whether this Mac intends to be hosting, regardless of whether the
    /// interface has appeared yet.
    ///
    /// **Intent, not observation, and the difference is a live loop.** The
    /// route tunnel's mode is pinned while hosting because Internet Sharing is
    /// sourced from that tunnel and rebuilds the access point on every
    /// reconfiguration. Deciding that from `bridge100` existing leaves a hole
    /// exactly where it matters: while the access point is *coming up* the
    /// interface is absent, so the Mac reports not-hosting, the reconciler asks
    /// for standby, the tunnel reconfigures, and Internet Sharing tears down
    /// the access point it was in the middle of starting. en0 then reclaims the
    /// radio, and the whole thing repeats every few seconds — which is what the
    /// user saw as the Mac "pulsing" between its own Wi-Fi and the shared one.
    static var intendsToHost: Bool {
        get { UserDefaults.standard.bool(forKey: "UpLinkIntendsToHost") }
        set { UserDefaults.standard.set(newValue, forKey: "UpLinkIntendsToHost") }
    }

    /// Raises the access point using this Mac's own credentials.
    func raise() async -> String? { await raise(credentials) }

    /// Whether the helper is installed and approved.
    var isRegistered: Bool {
        SMAppService.daemon(plistName: Self.plistName).status == .enabled
    }

    /// What the user has to do, if anything, before the access point can run.
    ///
    /// `.requiresApproval` is not a failure: registering a daemon puts it in
    /// Login Items awaiting a switch, and saying so is the difference between
    /// a one-time setup step and an app that appears broken.
    var registrationStatus: SMAppService.Status {
        SMAppService.daemon(plistName: Self.plistName).status
    }

    func register() {
        let service = SMAppService.daemon(plistName: Self.plistName)
        guard service.status != .enabled else { return }
        do {
            try service.register()
            log.info("helper registered, status now \(String(describing: service.status), privacy: .public)")
        } catch {
            log.error("helper registration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Brings the access point up, returning nil on success or a reason.
    func raise(_ credentials: AccessPointCredentials) async -> String? {
        // Set BEFORE the call, not after it succeeds. The window this closes is
        // precisely the one that was broken: the seconds between asking for the
        // access point and the interface appearing.
        Self.intendsToHost = true
        return await withCheckedContinuation { continuation in
            proxy { helper, fail in
                guard let helper else { return continuation.resume(returning: fail) }
                helper.raiseAccessPoint(
                    ssid: credentials.ssid, passphrase: credentials.passphrase
                ) { reason in
                    continuation.resume(returning: reason)
                }
            }
        }
    }

    func lower() async -> String? {
        Self.intendsToHost = false
        return await withCheckedContinuation { continuation in
            proxy { helper, fail in
                guard let helper else { return continuation.resume(returning: fail) }
                helper.lowerAccessPoint { reason in continuation.resume(returning: reason) }
            }
        }
    }

    /// Whether the access point is actually up, as the helper sees the
    /// interfaces — never as the preference file reads, which is input rather
    /// than output and has been observed disagreeing with reality.
    func isUp() async -> Bool {
        await withCheckedContinuation { continuation in
            proxy { helper, _ in
                guard let helper else { return continuation.resume(returning: false) }
                helper.accessPointStatus { up in continuation.resume(returning: up) }
            }
        }
    }

    // MARK: XPC

    /// Hands back a proxy, or nil and a reason.
    ///
    /// The error handler is as important as the success path: an XPC call to a
    /// helper that was never approved simply never replies, and a continuation
    /// that is never resumed is a hang, not an error. Both handlers below exist
    /// to make sure the reply always arrives.
    private func proxy(_ body: @escaping @MainActor (UpLinkHelperProtocol?, String?) -> Void) {
        guard isRegistered else {
            body(nil, "the UpLink helper has not been approved yet")
            return
        }
        let connection = connection ?? makeConnection()
        self.connection = connection

        let once = OneShotFlag()
        // CRASHED THE APP, and it took an hour of looking elsewhere to see it.
        //
        // XPC invokes this error block on ITS OWN QUEUE, not on the main actor.
        // This type is @MainActor, so the previous version's `self?.log` and
        // its direct `body(...)` were main-actor work performed on a background
        // thread: the Swift runtime asserts and the process aborts. Not an
        // error, not a hang — SIGABRT at launch, crash-looping, with the menu
        // bar never appearing and every downstream symptom looking like a
        // bridge fault.
        //
        // It fired reliably whenever an XPC call FAILED, which is exactly what
        // a method the running helper is too old to implement does. So the
        // staleness check crashed the app by way of the stale helper it was
        // written to detect.
        //
        // The logger is captured by value — `Logger` is Sendable — and every
        // resumption hops to the main actor explicitly.
        //
        // `@Sendable` is what actually fixes it, and nothing less does. A
        // closure written inline in a method of a @MainActor type INHERITS that
        // isolation, so the runtime asserts on ENTERING it from XPC's queue —
        // before a single line of the body runs. Moving the work inside onto
        // the main actor therefore changed nothing; the closure has to opt out
        // of inheriting isolation in the first place.
        let log = self.log
        let handler: @Sendable (Error) -> Void = { error in
            guard once.claim() else { return }
            log.error("helper unreachable: \(error.localizedDescription, privacy: .public)")
            let message = error.localizedDescription
            Task { @MainActor in body(nil, message) }
        }
        let remote = connection.remoteObjectProxyWithErrorHandler(handler) as? UpLinkHelperProtocol

        guard once.claim() else { return }
        body(remote, remote == nil ? "the UpLink helper is not answering" : nil)
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(
            machServiceName: UpLinkHelper.machServiceName, options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: UpLinkHelperProtocol.self)
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        connection.resume()
        return connection
    }
}

/// Lets exactly one of two racing paths run.
///
/// Same shape as `OneShot` in the kit, and for the same reason: an XPC error
/// handler and a normal return can both fire, and resuming a continuation twice
/// is a crash rather than a warning.
private final class OneShotFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

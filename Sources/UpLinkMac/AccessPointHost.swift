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
        await withCheckedContinuation { continuation in
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
        await withCheckedContinuation { continuation in
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
    private func proxy(_ body: @escaping (UpLinkHelperProtocol?, String?) -> Void) {
        guard isRegistered else {
            body(nil, "the UpLink helper has not been approved yet")
            return
        }
        let connection = connection ?? makeConnection()
        self.connection = connection

        let once = OneShotFlag()
        let remote = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            guard once.claim() else { return }
            self?.log.error("helper unreachable: \(error.localizedDescription, privacy: .public)")
            body(nil, error.localizedDescription)
        } as? UpLinkHelperProtocol

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

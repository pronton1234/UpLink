import Foundation
import UpLinkKit
import OSLog

/// The privileged half of UpLink on the Mac.
///
/// Exists for one reason: **Internet Sharing has no public API and cannot be
/// toggled from an app.** It can be driven by writing
/// `com.apple.nat.plist` and restarting `com.apple.NetworkSharing`, and both of
/// those need root.
///
/// Installed once with `SMAppService.daemon(plistName:)`, which is not new
/// privilege surface — the app is already unsandboxed and already installs a
/// system extension the user approves in the same panel.
///
/// `RunAtLoad` is belt-and-braces rather than the mechanism. What actually
/// restores Internet Sharing after a restart is configd's own
/// `com.apple.SystemConfiguration.ISPreference` plugin, which reads the same
/// preference file. `com.apple.NetworkSharing` has no `RunAtLoad` of its own,
/// so it cannot be what restores itself.
final class HelperService: NSObject, NSXPCListenerDelegate, UpLinkHelperProtocol {

    private let log = Logger(subsystem: "com.uplink.app", category: "helper")

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: UpLinkHelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func raiseAccessPoint(
        ssid: String,
        passphrase: String,
        withReply reply: @escaping (String?) -> Void
    ) {
        do {
            try AccessPointControl.raise(ssid: ssid, passphrase: passphrase)
            reply(nil)
        } catch {
            // Reported rather than logged and swallowed: "not bridging" with no
            // cause is the exact failure LinkStatus exists to prevent, and the
            // access point being down is the one cause the user can act on.
            log.error("raise failed: \(String(describing: error), privacy: .public)")
            reply(String(describing: error))
        }
    }

    func lowerAccessPoint(withReply reply: @escaping (String?) -> Void) {
        do {
            try AccessPointControl.lower()
            reply(nil)
        } catch {
            log.error("lower failed: \(String(describing: error), privacy: .public)")
            reply(String(describing: error))
        }
    }

    func accessPointStatus(withReply reply: @escaping (Bool) -> Void) {
        reply(AccessPointControl.isUp())
    }

    func helperBuild(withReply reply: @escaping (String) -> Void) {
        reply(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown")
    }
}

let delegate = HelperService()
let listener = NSXPCListener(machServiceName: UpLinkHelper.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()

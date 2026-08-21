#if os(macOS)
import Foundation

/// What the menu-bar app may ask the privileged helper to do.
///
/// Deliberately tiny. The helper runs as root, so every method here is a hole
/// in the app's own privilege boundary — and the app is already unsandboxed.
/// Everything that can be decided without root is decided in the kit and passed
/// in as a value: the helper is given an SSID and a passphrase, not a licence
/// to configure networking.
///
/// Note what is absent. There is no "run this command", no path parameter, and
/// no way to name the interface or the source service — those are derived
/// inside the helper from the machine, so a compromised app cannot point the
/// access point at a real network and put internet behind it.
@objc public protocol UpLinkHelperProtocol {

    /// Brings the access point up. Replies nil on success, or a reason.
    func raiseAccessPoint(
        ssid: String,
        passphrase: String,
        withReply reply: @escaping (String?) -> Void
    )

    /// Takes it down and releases the sleep assertion.
    func lowerAccessPoint(withReply reply: @escaping (String?) -> Void)

    /// Whether the access point is currently up, as the helper sees it.
    func accessPointStatus(withReply reply: @escaping (Bool) -> Void)

    /// The build of the app this helper was launched from.
    ///
    /// Exists because **replacing the app does not restart a running
    /// LaunchDaemon**, and nothing short of root can restart one. A stale
    /// helper looks identical to a current one from every angle: the app is
    /// new, the code on disk is new, and the daemon quietly goes on running
    /// whatever it started with. That cost most of a night, repeatedly, with
    /// every symptom pointing at code that was not executing.
    ///
    /// An older helper does not implement this at all, and the call failing is
    /// itself the answer.
    func helperBuild(withReply reply: @escaping (String) -> Void)
}

public enum UpLinkHelper {
    /// The Mach service the daemon publishes and the app connects to.
    public static let machServiceName = "com.uplink.app.helper"
}
#endif

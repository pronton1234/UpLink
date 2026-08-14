import Foundation
import OSLog
import SystemExtensions
import UpLinkKit

/// Bridges `OSSystemExtensionRequestDelegate`'s callbacks into one closure.
final class SystemExtensionDelegate: NSObject, OSSystemExtensionRequestDelegate {

    enum Result {
        case completed
        case needsApproval
        case failed(String)
    }

    private let onResult: (Result) -> Void
    // Every callback is logged as well as surfaced to the UI. Without this, a
    // request silently dropped by sysextd looks identical to one that was never
    // made, and the only place the difference shows is a menu someone has to
    // think to open.
    private let log = Logger(subsystem: UpLinkIdentifiers.logSubsystem, category: "sysext")

    init(onResult: @escaping (Result) -> Void) {
        self.onResult = onResult
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension replacement: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        // Always take the version shipped inside this app bundle. A stale
        // extension left from a previous build is a miserable thing to debug
        // against, because the symptom is code that behaves as if your edits
        // never happened.
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        log.error("sysext: needs user approval in System Settings")
        onResult(.needsApproval)
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        log.error("sysext: finished, result=\(result.rawValue, privacy: .public)")
        switch result {
        case .completed:
            onResult(.completed)
        case .willCompleteAfterReboot:
            // Rare, but silently reporting success here would leave the user
            // staring at an app that never connects.
            onResult(.failed("Restart your Mac to finish installing the network extension."))
        @unknown default:
            onResult(.completed)
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let code = (error as? OSSystemExtensionError)?.code.rawValue ?? -1
        log.error("sysext: FAILED code=\(code, privacy: .public) \(error.localizedDescription, privacy: .public)")
        onResult(.failed(Self.explain(error)))
    }

    /// Turns `OSSystemExtensionError` into something a user can act on.
    ///
    /// These codes are opaque and the two that actually happen — a build that
    /// is not notarized, and an app outside /Applications — both look like
    /// generic failures otherwise.
    private static func explain(_ error: Error) -> String {
        guard let code = (error as? OSSystemExtensionError)?.code else {
            return error.localizedDescription
        }
        switch code {
        case .extensionNotFound:
            return "The network extension is missing from the app bundle. Rebuild, and check the extension is embedded in Contents/Library/SystemExtensions."
        case .validationFailed:
            return "The extension failed validation — usually an entitlement that the provisioning profile does not grant."
        case .authorizationRequired, .requestSuperseded:
            return "Approve UpLink in System Settings → General → Login Items & Extensions → Network Extensions."
        case .unsupportedParentBundleLocation:
            return "macOS only activates a system extension when the app is in /Applications. Run ./scripts/release-mac.sh, which installs it there."
        case .codeSignatureInvalid:
            return "The extension's signature was rejected. Development builds must be notarized: run ./scripts/release-mac.sh."
        default:
            return "\(error.localizedDescription) (OSSystemExtensionError \(code.rawValue))"
        }
    }
}

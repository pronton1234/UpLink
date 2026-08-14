import Foundation
import OSLog

/// A small text log the phone keeps on disk, so its side of a failure can be
/// read afterwards.
///
/// ## Why this exists
///
/// Every log line on the phone goes to the unified log, which needs a cable to
/// read live — and **attaching the cable changes the thing under test**, because
/// it gives the Mac a second path to the phone and the peer link stops being
/// AWDL. So every round of debugging the cable-free case has been inference
/// from the phone's *silence* on the Mac's side: a hundred seconds with no
/// inbound connection tells you the phone did not dial, and nothing about why.
///
/// One file in a shared App Group container turns the next test from an
/// argument into a reading. Pull it with no cable attached during the run:
///
/// ```
/// xcrun devicectl device copy from --device <udid> \
///   --domain-type appGroupDataContainer \
///   --domain-identifier group.com.uplink.app \
///   --source Library/Caches/uplink-phone.log --destination <absolute path>
/// ```
///
/// ## What it deliberately is not
///
/// Not a replacement for `os.Logger` — every call site still logs there too,
/// because that is what a developer with a cable will look at first. This is
/// the copy that survives.
///
/// Bounded by rewriting from the start once it passes a cap, rather than by
/// rotating files: the interesting window is the last few minutes before a
/// failure, the extension can be killed at any moment, and a scheme that can
/// lose the newest lines to a rotation is worse than one that occasionally
/// loses the oldest.
public struct PhoneDiagnosticLog: Sendable {

    public static let appGroup = "group.com.uplink.app"
    public static let fileName = "uplink-phone.log"

    /// Roughly a few thousand lines — minutes of session churn, small enough to
    /// copy off the device in a second.
    private static let maximumBytes = 512 * 1024

    public static let shared = PhoneDiagnosticLog()

    private let url: URL?
    /// Why there is no file, when there is no file.
    ///
    /// The first version of this returned early on a nil container and said
    /// nothing, so when it produced no log after a cable-free test there was no
    /// way to tell "the extension never ran" from "the extension ran and could
    /// not write" — which is precisely the ambiguity the whole type exists to
    /// remove. A diagnostic that can fail silently is not a diagnostic.
    private let unavailableReason: String?
    private let queue = DispatchQueue(label: "com.uplink.app.phonelog")

    private init() {
        let log = Logger(subsystem: UpLinkIdentifiers.logSubsystem, category: "phonelog")
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup)
        else {
            url = nil
            unavailableReason = "no container for App Group \(Self.appGroup)"
            log.error("phone log unavailable: no container for App Group \(Self.appGroup, privacy: .public)")
            return
        }

        // Library/Caches, not the container root.
        //
        // Measured 2026-08-14: with the entitlement present in both the binary
        // and the provisioning profile, and the container plainly existing on
        // the device, a write to `<container>/uplink-phone.log` produced no
        // file at all. `devicectl` reports Library, Library/Caches and
        // Library/Preferences as Writable and says nothing about the root.
        // Writing into a directory the system itself created is one fewer
        // assumption, and costs nothing.
        let directory = container.appendingPathComponent("Library/Caches", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            url = directory.appendingPathComponent(Self.fileName)
            unavailableReason = nil
            log.error("phone log at \(directory.path, privacy: .public)/\(Self.fileName, privacy: .public)")
        } catch {
            url = nil
            unavailableReason = "could not create \(directory.path): \(error)"
            log.error("phone log unavailable: \(String(describing: error), privacy: .public)")
        }
    }

    /// Whether the container is actually reachable.
    ///
    /// Returns false when the App Group entitlement is missing or not yet in the
    /// provisioning profile — worth surfacing, because a silent no-op here would
    /// leave the next failure just as unreadable as the last one.
    public var isAvailable: Bool { url != nil }

    /// Empty when the log is working; otherwise why it is not.
    public var diagnosis: String { unavailableReason ?? "" }

    public func write(_ message: String) {
        guard let url else {
            // Loud, because the alternative is the silence that wasted a test.
            Logger(subsystem: UpLinkIdentifiers.logSubsystem, category: "phonelog")
                .error("dropping log line, \(unavailableReason ?? "unknown", privacy: .public): \(message, privacy: .public)")
            return
        }
        let line = "\(Self.timestamp()) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                let end = (try? handle.seekToEnd()) ?? 0
                if end > UInt64(Self.maximumBytes) {
                    // Start again rather than rotate. See the type's note: the
                    // last minutes are what matter and the process can die at
                    // any moment.
                    try? handle.truncate(atOffset: 0)
                    try? handle.seek(toOffset: 0)
                }
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// The whole file, for the `diagnostics` provider message.
    public func contents() -> String {
        guard let url else { return "(no diagnostic log: \(unavailableReason ?? "unknown"))" }
        guard let data = try? Data(contentsOf: url) else {
            return "(diagnostic log at \(url.path) could not be read — nothing written yet?)"
        }
        return String(data: data, encoding: .utf8) ?? "(unreadable)"
    }

    public func clear() {
        guard let url else { return }
        queue.async { try? Data().write(to: url, options: .atomic) }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}

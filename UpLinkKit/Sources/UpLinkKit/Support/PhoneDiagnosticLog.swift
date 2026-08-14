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
///   --source uplink-phone.log --destination .
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
    private let queue = DispatchQueue(label: "com.uplink.app.phonelog")

    private init() {
        url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup)?
            .appendingPathComponent(Self.fileName)
    }

    /// Whether the container is actually reachable.
    ///
    /// Returns false when the App Group entitlement is missing or not yet in the
    /// provisioning profile — worth surfacing, because a silent no-op here would
    /// leave the next failure just as unreadable as the last one.
    public var isAvailable: Bool { url != nil }

    public func write(_ message: String) {
        guard let url else { return }
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
        guard let url, let data = try? Data(contentsOf: url) else {
            return "(no diagnostic log — App Group container unavailable)"
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

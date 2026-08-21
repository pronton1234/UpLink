import Foundation
import UpLinkKit
import OSLog

/// The only thing in this process that touches the system.
///
/// Everything decidable lives in `UpLinkKit` and is unit-tested there —
/// `AccessPointConfiguration` builds the preferences, `HardwarePorts` finds the
/// interface. This type is I/O, deliberately, because it runs as root on a Mac
/// that is about to lose the radio anyone would be watching it over.
enum AccessPointControl {

    private static let log = Logger(subsystem: "com.uplink.app", category: "helper")

    enum Failure: Error, CustomStringConvertible {
        case noWiFiInterface
        case noSourceService
        case writeFailed
        case kickstartFailed(Int32)

        var description: String {
            switch self {
            case .noWiFiInterface: "this Mac reports no Wi-Fi interface"
            case .noSourceService: "no UpLink Route service to share from — is the route tunnel installed?"
            case .writeFailed: "could not write \(AccessPointConfiguration.preferencesPath)"
            case let .kickstartFailed(code): "NetworkSharing did not restart (status \(code))"
            }
        }
    }

    /// Brings the access point up.
    ///
    /// The source service is read from the existing preferences rather than
    /// taken from the caller. It must be the product's own dead-end route
    /// tunnel: sharing from a real network would put internet behind the
    /// access point, which is the one thing this must never do, and letting the
    /// caller name it would make that a one-line mistake.
    static func raise(ssid: String, passphrase: String) throws {
        guard let device = HardwarePorts.wifiDevice(in: try hardwarePorts()) else {
            throw Failure.noWiFiInterface
        }
        guard let service = existingSourceService() else {
            throw Failure.noSourceService
        }

        let configuration = AccessPointConfiguration(
            ssid: ssid,
            passphrase: passphrase,
            sourceServiceID: service,
            sharingDeviceKey: device
        )

        log.info("raising access point on \(device, privacy: .public) from \(service, privacy: .public)")
        try write(configuration.natPreferences())
        try kickstartNetworkSharing()
        holdAwake(true)
    }

    static func lower() throws {
        // Read, disable, write back — rather than writing a fresh dictionary —
        // so the user's own source selection survives being switched off.
        var preferences = currentPreferences() ?? [:]
        var nat = preferences["NAT"] as? [String: Any] ?? [:]
        nat["Enabled"] = 0
        if var airport = nat["AirPort"] as? [String: Any] {
            airport["Enabled"] = 0
            nat["AirPort"] = airport
        }
        preferences["NAT"] = nat

        log.info("lowering access point")
        try write(preferences)
        try kickstartNetworkSharing()
        holdAwake(false)
    }

    /// Whether an access point is genuinely up.
    ///
    /// Read from the interfaces, never from the preference file. The preference
    /// is input, not output: `:NAT:AirPort:Enabled` has been observed reading
    /// `0` with the access point fully up, because configd consumes the file
    /// into live state and does not write back. `bridge100` carrying the
    /// gateway with the radio on a dedicated `ap1` is what up actually looks
    /// like on this hardware — and `en0` reading `inactive` while hosting is
    /// expected rather than a fault.
    static func isUp() -> Bool {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return false }
        defer { freeifaddrs(addresses) }

        var sawBridge = false
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let name = String(cString: pointer.pointee.ifa_name)
            if name == "bridge100", pointer.pointee.ifa_flags & UInt32(IFF_RUNNING) != 0 {
                sawBridge = true
            }
        }
        return sawBridge
    }

    // MARK: The system

    private static func currentPreferences() -> [String: Any]? {
        NSDictionary(contentsOfFile: AccessPointConfiguration.preferencesPath) as? [String: Any]
    }

    /// The service currently configured as the sharing source.
    private static func existingSourceService() -> String? {
        (currentPreferences()?["NAT"] as? [String: Any])?["PrimaryService"] as? String
    }

    private static func write(_ preferences: [String: Any]) throws {
        guard (preferences as NSDictionary).write(
            toFile: AccessPointConfiguration.preferencesPath, atomically: true
        ) else { throw Failure.writeFailed }
    }

    /// Restarts the daemon so configd's Internet Sharing plugin re-reads the
    /// preference it just changed.
    private static func kickstartNetworkSharing() throws {
        let status = run("/bin/launchctl", ["kickstart", "-k", "system/com.apple.NetworkSharing"])
        guard status == 0 else { throw Failure.kickstartFailed(status) }
    }

    /// Internet Sharing sets no-sleep only on AC power — it says so in the
    /// panel — so a Mac hosting the access point on battery still sleeps. This
    /// is the other half, and it is root-only, which is a reason this helper
    /// exists even if everything above it turns out to be unnecessary.
    private static func holdAwake(_ awake: Bool) {
        _ = run("/usr/bin/pmset", ["-b", "disablesleep", awake ? "1" : "0"])
    }

    private static func hardwarePorts() throws -> String {
        let pipe = Pipe()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        task.arguments = ["-listallhardwareports"]
        task.standardOutput = pipe
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        do { try task.run() } catch { return -1 }
        task.waitUntilExit()
        return task.terminationStatus
    }
}

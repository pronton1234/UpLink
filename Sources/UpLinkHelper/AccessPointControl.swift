import Foundation
import SystemConfiguration
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
        case sessionFailed
        case lockFailed
        case commitFailed(String)
        case applyFailed(String)

        var description: String {
            switch self {
            case .noWiFiInterface: "this Mac reports no Wi-Fi interface"
            case .noSourceService: "no UpLink Route service to share from — is the route tunnel installed?"
            case .sessionFailed: "could not open the Internet Sharing preferences"
            case .lockFailed: "another process is holding the network preferences"
            case let .commitFailed(why): "could not save the sharing configuration: \(why)"
            case let .applyFailed(why): "saved the configuration but could not apply it: \(why)"
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

        guard let sourceName = serviceName(for: service) else {
            throw Failure.noSourceService
        }

        let configuration = AccessPointConfiguration(
            ssid: ssid,
            passphrase: passphrase,
            sourceServiceID: service,
            sharingDeviceKey: device,
            sourceName: sourceName
        )

        log.info("raising access point on \(device, privacy: .public) from \(service, privacy: .public)")
        // Merged onto what is already there. Replacing it drops keys we do not
        // know the purpose of — PrimaryInterface among them — and configd then
        // reports "external interface: (null)" with a file that reads correctly.
        try apply(configuration.natPreferences(mergedOnto: currentPreferences() ?? [:]))
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
        try apply(preferences)
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

    /// Writes the sharing configuration **through SystemConfiguration**, then
    /// asks configd to apply it.
    ///
    /// MEASURED 2026-08-20, and it is the difference between this working and
    /// not. Writing `com.apple.nat.plist` directly succeeds — the file ends up
    /// exactly right — and nothing happens, because a direct write goes behind
    /// SystemConfiguration's back and configd is never told. The obvious
    /// follow-up, restarting the daemon by hand, is refused outright:
    ///
    ///     launchctl kickstart -k system/com.apple.NetworkSharing
    ///     → 150: Operation not permitted while System Integrity Protection is engaged
    ///
    /// SIP owns Apple's daemons, so nothing outside Apple may restart one. That
    /// is not a gap to work around, it is the boundary saying to use the
    /// supported door instead: `SCPreferencesApplyChanges` is the notification
    /// System Settings itself sends, and configd's Internet Sharing plugin
    /// (`com.apple.SystemConfiguration.ISPreference`) is what listens for it and
    /// starts the daemon.
    ///
    /// The lock matters. These preferences are shared with System Settings, and
    /// committing without it can lose a concurrent edit — or fail in a way that
    /// reads as a permissions problem.
    private static func apply(_ nat: [String: Any]) throws {
        guard let preferences = SCPreferencesCreate(
            nil, "UpLink" as CFString, "com.apple.nat.plist" as CFString
        ) else { throw Failure.sessionFailed }

        guard SCPreferencesLock(preferences, true) else {
            throw Failure.lockFailed
        }
        defer { SCPreferencesUnlock(preferences) }

        guard let value = nat["NAT"] as? [String: Any] else {
            throw Failure.commitFailed("no NAT dictionary to write")
        }
        guard SCPreferencesSetValue(
            preferences, "NAT" as CFString, value as CFDictionary
        ) else { throw Failure.commitFailed(scError()) }

        guard SCPreferencesCommitChanges(preferences) else {
            throw Failure.commitFailed(scError())
        }
        // The half a direct file write can never do.
        guard SCPreferencesApplyChanges(preferences) else {
            throw Failure.applyFailed(scError())
        }
    }

    /// The human-readable name of a network service, by its identifier.
    ///
    /// Asked of the system rather than remembered, so a Mac whose
    /// `PrimaryInterface` was destroyed by an earlier version of this code can
    /// be repaired from the app instead of from System Settings — which is the
    /// manual step this helper exists to remove.
    private static func serviceName(for serviceID: String) -> String? {
        guard let preferences = SCPreferencesCreate(nil, "UpLink" as CFString, nil),
              let set = SCNetworkSetCopyCurrent(preferences),
              let services = SCNetworkSetCopyServices(set) as? [SCNetworkService]
        else { return nil }

        for service in services
        where (SCNetworkServiceGetServiceID(service) as String?) == serviceID {
            return SCNetworkServiceGetName(service) as String?
        }
        return nil
    }

    private static func scError() -> String {
        String(cString: SCErrorString(SCError()))
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

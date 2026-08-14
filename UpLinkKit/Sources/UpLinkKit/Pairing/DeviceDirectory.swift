import Foundation

/// Where the list of paired devices lives.
///
/// Split out from ``PairedDeviceStore`` because the Mac's proxy runs in a
/// **system extension**, which executes as root outside the login session and
/// therefore cannot reach the user keychain at all — `SecItemCopyMatching`
/// returns `errSecNotAvailable` (-25291) there, no matter how the access groups
/// are configured.
///
/// The split is along the right line anyway: a paired device record is a public
/// key plus a name. Nothing in it is secret. The one genuine secret — this device's
/// long-term private key — stays in the keychain on the app side and is handed
/// to the extension through `providerConfiguration`.
public protocol DeviceDirectory: Sendable {
    func pairedDevices() throws -> [PairedDevice]
    func save(_ device: PairedDevice) throws
    func remove(fingerprint: String) throws
}

extension PairedDeviceStore: DeviceDirectory {}

/// Paired devices in a file inside the shared app-group container.
///
/// Readable and writable by both the app and the system extension, which is the
/// point: the extension accepts pairings, the app displays and revokes them.
public struct GroupDeviceDirectory: DeviceDirectory {

    private let containerURL: URL

    /// - Returns: `nil` if the app group is unavailable, which means the
    ///   entitlement is missing rather than that there are no devices — worth
    ///   failing loudly rather than silently behaving as if nothing is paired.
    public init?(appGroup: String = "group.com.uplink.app") {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup
        ) else { return nil }
        self.containerURL = url
    }

    private var fileURL: URL { containerURL.appendingPathComponent("paired-devices.json") }

    public func pairedDevices() throws -> [PairedDevice] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([PairedDevice].self, from: data)) ?? []
    }

    public func save(_ device: PairedDevice) throws {
        var devices = try pairedDevices()
        devices.removeAll { $0.fingerprint == device.fingerprint }
        devices.append(device)
        try write(devices)
    }

    public func remove(fingerprint: String) throws {
        var devices = try pairedDevices()
        devices.removeAll { $0.fingerprint == fingerprint }
        try write(devices)
    }

    private func write(_ devices: [PairedDevice]) throws {
        let data = try JSONEncoder().encode(devices)
        // Atomic so a reader in the other process never sees a half-written
        // file — the app polls this while the extension may be writing it.
        try data.write(to: fileURL, options: .atomic)
    }
}

/// Paired devices held in memory for the lifetime of a process.
///
/// Used by the macOS system extension. That process is root, outside the login
/// session, so it can reach neither the user keychain nor a sandboxed app
/// group container reliably — and the app is unsandboxed while the extension is
/// sandboxed, so the two resolve group paths differently.
///
/// Rather than fight that, the extension holds the list in memory: seeded from
/// `providerConfiguration` at startup, and read back by the app through the
/// existing `"devices"` provider message when a new pairing completes. The app
/// remains the only writer of durable state, in its keychain.
public final class InMemoryDeviceDirectory: DeviceDirectory, @unchecked Sendable {

    private var devices: [PairedDevice]
    private let lock = NSLock()

    public init(seed: [PairedDevice] = []) {
        self.devices = seed
    }

    public func pairedDevices() throws -> [PairedDevice] {
        lock.lock(); defer { lock.unlock() }
        return devices
    }

    public func save(_ device: PairedDevice) throws {
        lock.lock(); defer { lock.unlock() }
        devices.removeAll { $0.fingerprint == device.fingerprint }
        devices.append(device)
    }

    public func remove(fingerprint: String) throws {
        lock.lock(); defer { lock.unlock() }
        devices.removeAll { $0.fingerprint == fingerprint }
    }
}

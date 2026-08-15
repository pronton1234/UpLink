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

/// Paired devices held in memory, for a process that cannot keep them.
///
/// The Mac's system extension runs as root outside the login session and gets
/// `errSecNotAvailable (-25291)` from the keychain, so it cannot store anything
/// durable: the app seeds it through `providerConfiguration` and learns about
/// new pairings over the "devices" IPC round trip.
///
/// The PHONE has no such problem — an iOS app extension shares the app's
/// keychain access group — so its listener uses `PairedDeviceStore` directly
/// and none of this applies there.
// `GroupDeviceDirectory` lived here: an app-group JSON file implementing
// `DeviceDirectory`. It had ZERO call sites and was superseded by the
// in-memory directory plus the "devices" IPC round trip.
//
// Deleted rather than left in place. A third storage path that looks
// production-ready is worse than none: durability here is genuinely confusing
// — the extension's store is in memory, the app's is the keychain, and the
// two are reconciled by a poll — and an unused fourth option invites someone
// to "fix" that by wiring up the one nothing has ever exercised.
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

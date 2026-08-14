import Foundation
import Security
import CryptoKit

/// A device this one has paired with.
public struct PairedDevice: Sendable, Equatable, Identifiable, Codable {
    public var id: String { fingerprint }
    /// Short hash of the peer's long-term public key. Shown in the UI and put
    /// in the Bonjour TXT record so a known device is recognisable before any
    /// connection is made.
    public let fingerprint: String
    public let name: String
    public let publicKey: Data
    public let pairedAt: Date

    public init(fingerprint: String, name: String, publicKey: Data, pairedAt: Date) {
        self.fingerprint = fingerprint
        self.name = name
        self.publicKey = publicKey
        self.pairedAt = pairedAt
    }

    public static func fingerprint(of publicKey: Data) -> String {
        let digest = SHA256.hash(data: publicKey)
        // First 8 bytes is plenty to distinguish a handful of personal devices
        // and short enough to render in a menu.
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

public enum KeychainError: Error, Equatable, Sendable {
    case unexpectedStatus(OSStatus)
    case malformedData

    /// Human-readable, because the two failures that actually happen here are
    /// both configuration mistakes rather than runtime conditions, and the raw
    /// OSStatus tells nobody anything.
    public var diagnosis: String {
        switch self {
        case let .unexpectedStatus(status):
            switch status {
            case -34018:
                return """
                    errSecMissingEntitlement (-34018): the process is not entitled to the \
                    keychain access group '\(UpLinkIdentifiers.keychainAccessGroupSuffix)'. \
                    Check that this target's .entitlements lists \
                    $(AppIdentifierPrefix)\(UpLinkIdentifiers.keychainAccessGroupSuffix) under \
                    keychain-access-groups, and that it is signed with a provisioning profile \
                    that includes it.
                    """
            case errSecInteractionNotAllowed:
                return """
                    errSecInteractionNotAllowed: the item is not readable while the device is \
                    locked. Items here use kSecAttrAccessibleAfterFirstUnlock precisely so the \
                    extension can read them on a locked phone — an item written with a stricter \
                    class will fail here.
                    """
            default:
                return "Keychain error \(status)"
            }
        case .malformedData:
            return "Stored keychain item could not be decoded."
        }
    }
}

/// Long-term identity and paired-peer storage, backed by the Keychain.
///
/// **This is shared between processes.** The app and its network extension are
/// separate processes that must agree on one long-term key pair and one list of
/// paired devices. That only works if both name the same access group *and*
/// both use the data protection keychain — see ``Configuration``.
public struct PairedDeviceStore: Sendable {

    /// How the store talks to the keychain.
    public struct Configuration: Sendable, Equatable {
        public var service: String
        /// Fully-qualified group, e.g. `"ABCDE12345.com.uplink.app"`. `nil`
        /// falls back to the first entry in the entitlement, which is the same
        /// group.
        public var accessGroup: String?
        /// Whether to use the data protection keychain.
        ///
        /// **Load-bearing on macOS.** The legacy file-based macOS keychain
        /// largely ignores `kSecAttrAccessGroup`, so with this off the Mac app
        /// and its system extension silently read two different keychains and
        /// each generates its own identity. On iOS this is the only keychain,
        /// so the flag is harmless there. Apple's TN3137 covers the split.
        public var useDataProtectionKeychain: Bool

        public init(
            service: String = UpLinkIdentifiers.keychainService,
            accessGroup: String? = UpLinkIdentifiers.keychainAccessGroup,
            useDataProtectionKeychain: Bool = true
        ) {
            self.service = service
            self.accessGroup = accessGroup
            self.useDataProtectionKeychain = useDataProtectionKeychain
        }

        /// The configuration every target should use. Named rather than
        /// defaulted so a call site that wants something else has to say so.
        public static let shared = Configuration()
    }

    private let configuration: Configuration

    public init(configuration: Configuration = .shared) {
        self.configuration = configuration
    }

    // MARK: Long-term identity

    private var identityAccount: String { "device-identity" }

    /// This device's long-term key pair, generated once on first use.
    ///
    /// Both the app and the extension call this. Because they share an access
    /// group they get the *same* key — if they ever diverge, pairing silently
    /// stops working, since the fingerprint the phone was paired against no
    /// longer matches the one the extension presents.
    public func loadOrCreateIdentity() throws -> Curve25519.KeyAgreement.PrivateKey {
        if let raw = try read(account: identityAccount) {
            return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        try write(key.rawRepresentation, account: identityAccount)
        return key
    }

    public func fingerprint() throws -> String {
        PairedDevice.fingerprint(of: try loadOrCreateIdentity().publicKey.rawRepresentation)
    }

    // MARK: Paired peers

    private var peersAccount: String { "paired-devices" }

    public func pairedDevices() throws -> [PairedDevice] {
        guard let raw = try read(account: peersAccount) else { return [] }
        guard let devices = try? JSONDecoder().decode([PairedDevice].self, from: raw) else {
            throw KeychainError.malformedData
        }
        return devices
    }

    public func save(_ device: PairedDevice) throws {
        var devices = try pairedDevices()
        devices.removeAll { $0.fingerprint == device.fingerprint }
        devices.append(device)
        try write(JSONEncoder().encode(devices), account: peersAccount)
    }

    public func remove(fingerprint: String) throws {
        var devices = try pairedDevices()
        devices.removeAll { $0.fingerprint == fingerprint }
        try write(JSONEncoder().encode(devices), account: peersAccount)
    }

    // MARK: Keychain plumbing

    /// Builds the query dictionary. Internal so the shape can be asserted in
    /// tests without a signed process — the SecItem calls themselves need
    /// entitlements and cannot run in a test bundle.
    func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: configuration.service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup = configuration.accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        if configuration.useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    /// Attributes applied on write.
    func writeAttributes() -> [String: Any] {
        [
            // Readable after first unlock so the extension can work while the
            // phone is locked — which is the entire point of running in an
            // extension. `WhenUnlocked` would break background operation.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
    }

    private func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw KeychainError.malformedData }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func write(_ data: Data, account: String) throws {
        let query = baseQuery(account: account)
        var attributes = writeAttributes()
        attributes[kSecValueData as String] = data

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = query
            insert.merge(attributes) { current, _ in current }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

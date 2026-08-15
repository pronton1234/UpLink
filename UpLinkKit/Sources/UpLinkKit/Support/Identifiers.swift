import Foundation

/// Every bundle identifier, keychain group, and log subsystem in one place.
///
/// These were previously scattered as string literals across four targets, two
/// Info.plists, and four entitlement files, which is exactly how the app and
/// its extension ended up reading two different keychains without anyone
/// noticing. A rename now touches this file and the build settings, nothing
/// else.
public enum UpLinkIdentifiers {

    /// The macOS and iOS apps deliberately share a bundle identifier. One App
    /// ID can serve both platforms, and sharing it means one identity, one set
    /// of capabilities, and one thing to register.
    public static let app = "com.uplink.app"

    /// macOS transparent proxy system extension.
    public static let macProxyExtension = "com.uplink.app.proxy"


    /// Log subsystem for every target.
    public static let logSubsystem = "com.uplink.app"

    /// Keychain service name. Not a bundle ID — just the bucket the items live
    /// in.
    public static let keychainService = "com.uplink.app"

    /// The shared keychain access group, without the team prefix.
    ///
    /// Both the app and its network extension declare
    /// `$(AppIdentifierPrefix)com.uplink.app` under `keychain-access-groups`.
    /// That shared group is the only reason two separate processes can see the
    /// same long-term identity — without it the app pairs a device and the
    /// extension cannot read it, and each generates its own private key.
    ///
    /// Keychain groups need no registration in the developer portal; the system
    /// validates them against the team prefix in the code signature.
    public static let keychainAccessGroupSuffix = "com.uplink.app"

    /// The team prefix (`"ABCDE12345."`, trailing dot included), read at build
    /// time from `$(AppIdentifierPrefix)` in each target's Info.plist.
    ///
    /// Resolved at runtime rather than hardcoded so the project keeps working
    /// when signed by a different account.
    public static var appIdentifierPrefix: String? {
        Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String
    }

    /// Fully-qualified keychain access group, or `nil` if the prefix is missing.
    ///
    /// A `nil` here is not a silent fallback to "unshared". `SecItem` treats an
    /// absent access group as "use the first entry in `keychain-access-groups`",
    /// which — because each entitlement file lists exactly the shared group and
    /// nothing else — lands in the same place. Both paths therefore share; the
    /// explicit one is just easier to debug when it does not.
    public static var keychainAccessGroup: String? {
        guard let prefix = appIdentifierPrefix else { return nil }
        return prefix + keychainAccessGroupSuffix
    }
}

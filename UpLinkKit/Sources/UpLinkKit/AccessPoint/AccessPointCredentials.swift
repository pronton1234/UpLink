import Foundation

/// What the phone needs in order to join the Mac's network by itself.
///
/// **This is what makes the whole flow one button.** The phone hands these to
/// `NEHotspotConfiguration(SSID:passphrase:isWEP:)`, so the user never opens
/// Settings, never picks a network out of a list, and never types a password.
///
/// They cross the pairing channel, which is already authenticated end to end by
/// TLS-PSK — the same channel the session key is agreed over. Nothing here is
/// ever shown to anyone, which is why the passphrase is sized for strength
/// rather than for being read aloud.
public struct AccessPointCredentials: Sendable, Equatable, Codable {

    public let ssid: String
    public let passphrase: String

    public init(ssid: String, passphrase: String) {
        self.ssid = ssid
        self.passphrase = passphrase
    }

    /// The network name for a Mac with this fingerprint.
    ///
    /// Derived rather than fixed, for two reasons that pull the same way. Two
    /// UpLink Macs in range with the same SSID would be a name collision the
    /// phone resolves arbitrarily — it would join whichever answered, and the
    /// pairing would then fail against a Mac that is working perfectly. And it
    /// must be **stable**, because a saved hotspot configuration is keyed by
    /// SSID: a name that moved would silently stop the phone re-joining on its
    /// own, which is the one behaviour the product is built around.
    ///
    /// Kept under the 32 bytes 802.11 allows. A longer SSID is not truncated
    /// politely, it is refused — inside Internet Sharing, on a Mac whose radio
    /// has just gone away.
    public static func ssid(forFingerprint fingerprint: String) -> String {
        // Recognisable first, because the user does see this in a Wi-Fi list
        // even though they never have to touch it.
        let suffix = fingerprint.prefix(8)
        return "UpLink-\(suffix)"
    }

    /// A fresh WPA2 passphrase.
    ///
    /// WPA2-PSK accepts 8...63 ASCII characters; outside that the network
    /// cannot be created at all. Nobody types this, so it is sized well above
    /// the floor. The character set deliberately excludes nothing that would
    /// need escaping when written into a property list.
    public static func generatePassphrase() -> String {
        let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var bytes = [UInt8](repeating: 0, count: 32)
        // SecRandomCopyBytes is unavailable to pure SwiftPM on every platform
        // this package builds for; the system generator is CSPRNG-backed.
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0 ... 255) }
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }
}

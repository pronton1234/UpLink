import Foundation

/// The Internet Sharing configuration the privileged helper writes.
///
/// **This is a value, not an action.** Internet Sharing has no public API, so
/// the helper drives it by writing this file and kickstarting
/// `com.apple.NetworkSharing` — a Mach-activated daemon running
/// `/usr/libexec/InternetSharing` with no `RunAtLoad` of its own. Every field
/// here is a place the design can be wrong in a way that only a reboot or a
/// radio outage would reveal, so the shape lives in the kit where `swift test`
/// can hold it, and the daemon is left with nothing but I/O.
///
/// **The plist is input, not output.** A prior hardware run recorded
/// `:NAT:AirPort:Enabled` reading `0` with the access point fully up, and
/// concluded "never test that field". That is correct, and it is about
/// *reading*: configd consumes this file into live state and does not write
/// back. A read proving nothing says nothing about whether a write is honoured
/// — which is why the write is a Phase 0 measurement rather than an assumption.
public struct AccessPointConfiguration: Sendable, Equatable {

    public static let preferencesPath =
        "/Library/Preferences/SystemConfiguration/com.apple.nat.plist"

    public let ssid: String
    public let passphrase: String

    /// SystemConfiguration service UUID of the source being shared.
    ///
    /// In production this is the product's own `RouteProvider` tunnel, so the
    /// access point comes up with **no internet behind it**. Sharing from a
    /// real network would defeat the entire premise: the phone would reach the
    /// internet through the Mac rather than the Mac through the phone.
    public let sourceServiceID: String

    /// BSD name of the interface hosting the radio.
    ///
    /// Supplied by ``HardwarePorts/wifiDevice(in:)`` rather than hardcoded, so
    /// this needs no measurement to be correct — it is whatever this Mac says
    /// its Wi-Fi interface is at the moment the helper asks. That also makes it
    /// right on a Mac that is not this one.
    public let sharingDeviceKey: String

    /// Human-readable name of the source service, e.g. `UpLink Route`.
    ///
    /// Needed because `PrimaryInterface` cannot always be merged from what is
    /// already on disk: a previous version of this code replaced the whole
    /// dictionary and destroyed it, and a Mac in that state has nothing left to
    /// carry forward. Rebuilding it from the service is what makes the helper
    /// able to repair its own past mistake rather than needing System Settings.
    public let sourceName: String

    public init(
        ssid: String,
        passphrase: String,
        sourceServiceID: String,
        sharingDeviceKey: String,
        sourceName: String
    ) {
        self.ssid = ssid
        self.passphrase = passphrase
        self.sourceServiceID = sourceServiceID
        self.sharingDeviceKey = sharingDeviceKey
        self.sourceName = sourceName
    }

    /// The configuration **merged onto** whatever is already there.
    ///
    /// MEASURED 2026-08-20, and the reason this takes an argument at all.
    /// Building a fresh dictionary looked complete — every field a reader would
    /// think of was present and correct — and configd answered:
    ///
    ///     [com.apple.NetworkSharing:preference] no external service id
    ///     [com.apple.NetworkSharing:preference] external interface: (null)
    ///     [com.apple.NetworkSharing:preference] sharing started on 0 interfaces
    ///
    /// The replacement had silently dropped `PrimaryInterface`, the sub-
    /// dictionary naming the source being shared. Nothing in the written file
    /// looked wrong; the fault was entirely in what was missing.
    ///
    /// So this never replaces. Unknown keys are carried through untouched,
    /// because a system preference is not ours to rewrite from first principles
    /// — we do not know what every key is for, and that is exactly the point.
    public func natPreferences(mergedOnto existing: [String: Any] = [:]) -> [String: Any] {
        var nat = existing["NAT"] as? [String: Any] ?? [:]

        var airport = nat["AirPort"] as? [String: Any] ?? [:]
        airport["Enabled"] = 1
        airport["NetworkName"] = ssid
        airport["NetworkPassword"] = Data(passphrase.utf8)
        nat["AirPort"] = airport

        // The source. Carried through rather than invented: it names the
        // service being shared, and pointing it at a real network instead of
        // the dead-end tunnel would put internet behind the access point.
        var primary = nat["PrimaryInterface"] as? [String: Any] ?? [:]
        primary["Enabled"] = 1
        // Rebuilt when absent rather than only enabled when present. Device and
        // HardwareKey are empty in this Mac's captured working configuration —
        // the name is what identifies the service — so they are filled only to
        // keep the dictionary the shape configd expects.
        if primary["PrimaryUserReadable"] == nil {
            primary["PrimaryUserReadable"] = sourceName
            primary["Device"] = primary["Device"] ?? ""
            primary["HardwareKey"] = primary["HardwareKey"] ?? ""
        }
        nat["PrimaryInterface"] = primary

        nat["Enabled"] = 1
        nat["PrimaryService"] = sourceServiceID
        nat["SharingDevices"] = [sharingDeviceKey]

        var merged = existing
        merged["NAT"] = nat
        return merged
    }

}

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

    /// BSD name of the interface the source service is **currently** on, e.g.
    /// `utun5`.
    ///
    /// MEASURED 2026-08-20, and the reason the access point would not start
    /// even with every other field correct. The source here is a VPN service,
    /// and a VPN has no static device: `preferences.plist` records its
    /// interface as `Type: VPN, DeviceName: None`. So `PrimaryInterface.Device`
    /// cannot be carried forward from configuration — it only exists at
    /// runtime, in `State:/Network/Service/<id>/IPv4` → `InterfaceName`.
    ///
    /// Left empty, configd resolves the source and then reports
    /// `external interface: (null)` and `sharing started on 0 interfaces`,
    /// having taken the Wi-Fi radio on the way. That is the worst shape of
    /// failure available: it looks like it is working.
    public let sourceDevice: String

    public init(
        ssid: String,
        passphrase: String,
        sourceServiceID: String,
        sharingDeviceKey: String,
        sourceName: String,
        sourceDevice: String
    ) {
        self.ssid = ssid
        self.passphrase = passphrase
        self.sourceServiceID = sourceServiceID
        self.sharingDeviceKey = sharingDeviceKey
        self.sourceName = sourceName
        self.sourceDevice = sourceDevice
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
        // Always set, never merely carried forward. The stored value is empty
        // for a VPN source and an empty Device is what makes configd report
        // `external interface: (null)` — after it has taken the radio.
        primary["Device"] = sourceDevice
        if primary["PrimaryUserReadable"] == nil {
            primary["PrimaryUserReadable"] = sourceName
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

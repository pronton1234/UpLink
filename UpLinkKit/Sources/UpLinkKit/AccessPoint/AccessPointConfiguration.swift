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

    public init(
        ssid: String,
        passphrase: String,
        sourceServiceID: String,
        sharingDeviceKey: String
    ) {
        self.ssid = ssid
        self.passphrase = passphrase
        self.sourceServiceID = sourceServiceID
        self.sharingDeviceKey = sharingDeviceKey
    }

    /// The dictionary written to ``preferencesPath``.
    ///
    /// Keys and nesting mirror what this Mac already holds, captured
    /// 2026-08-20 while sharing was off and already configured to share from
    /// `UpLink Route`.
    public func natPreferences() -> [String: Any] {
        let airport: [String: Any] = [
            "Enabled": 1,
            "NetworkName": ssid,
            "NetworkPassword": Data(passphrase.utf8),
            "40BitEncrypt": 1,
            "Channel": 0,
        ]
        let nat: [String: Any] = [
            "Enabled": 1,
            "AirPort": airport,
            "PrimaryService": sourceServiceID,
            "SharingDevices": [sharingDeviceKey],
            "NatPortMapDisabled": false,
        ]
        return ["NAT": nat]
    }
}

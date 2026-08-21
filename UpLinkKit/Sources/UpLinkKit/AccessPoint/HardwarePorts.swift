import Foundation

/// Which interface the access point is hosted on.
///
/// **Derived from the machine, never hardcoded.** The value goes into
/// `SharingDevices` in ``AccessPointConfiguration``, and getting it wrong hosts
/// the access point on the wrong interface — on a Mac that is about to lose the
/// radio being used to observe the mistake. Deriving it also means the design
/// needs no measurement to be written: the answer is whatever this Mac says it
/// is, at the moment the helper asks.
///
/// The parsing is here rather than in the daemon because it is the only part
/// that can be wrong in an interesting way, and here it can be held against
/// real output in milliseconds.
public enum HardwarePorts {

    /// The BSD name of the Wi-Fi interface, from `networksetup -listallhardwareports`.
    ///
    /// The trap this exists to avoid, and the reason the fixture in the tests is
    /// verbatim from a real Mac: Ethernet adapters are listed **before** Wi-Fi,
    /// and their port titles carry a device in parentheses —
    /// `Hardware Port: Ethernet Adapter (en3)`. Anything that takes the first
    /// `Device:` line, or that harvests a name out of a port title, answers
    /// confidently and wrongly.
    ///
    /// Blocks are separated by blank lines, so a `Wi-Fi` block with no `Device:`
    /// of its own must yield nothing rather than reaching into the next block.
    public static func wifiDevice(in listing: String) -> String? {
        var inWiFiBlock = false
        for rawLine in listing.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                // A block ended. If it was Wi-Fi's and carried no device, the
                // answer is nothing — not whatever comes next.
                inWiFiBlock = false
                continue
            }
            if let port = line.dropPrefix("Hardware Port:") {
                // Exact match. "Wi-Fi Adapter" and similar are different ports.
                inWiFiBlock = port.trimmingCharacters(in: .whitespaces) == "Wi-Fi"
                continue
            }
            if inWiFiBlock, let device = line.dropPrefix("Device:") {
                let name = device.trimmingCharacters(in: .whitespaces)
                return name.isEmpty ? nil : name
            }
        }
        return nil
    }
}

private extension String {
    /// The remainder after `prefix`, or nil if this string does not start with it.
    func dropPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}

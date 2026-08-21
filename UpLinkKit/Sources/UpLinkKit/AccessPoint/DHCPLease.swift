import Foundation

/// A client of the network the Mac hosts, as `bootpd` recorded it.
///
/// **This is how the Mac finds the phone, and it is deliberately not Bonjour.**
/// The Mac is the DHCP server for its own access point, so it already knows
/// every address it handed out — no browsing, no service resolution, no local
/// network permission prompt, and nothing that has to survive a radio change.
/// `/var/db/dhcpd_leases` is world-readable and updated as clients join.
public struct DHCPLease: Sendable, Equatable {

    public static let path = "/var/db/dhcpd_leases"

    public let name: String?
    public let address: String
    public let hardwareAddress: String?
    /// Lease timestamp as `bootpd` wrote it, used only to order entries.
    public let lease: UInt64?

    /// Parses the whole file.
    ///
    /// The format is brace-delimited records of `key=value` lines. Anything
    /// without an address is skipped rather than yielding a blank one: an empty
    /// address is a dial to nowhere, and nowhere takes the full connect timeout
    /// to fail.
    public static func parse(_ contents: String) -> [DHCPLease] {
        var leases: [DHCPLease] = []
        var fields: [String: String] = [:]
        var inRecord = false

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "{" { inRecord = true; fields = [:]; continue }
            if line == "}" {
                if inRecord, let address = fields["ip_address"], !address.isEmpty {
                    leases.append(DHCPLease(
                        name: fields["name"],
                        address: address,
                        hardwareAddress: fields["hw_address"],
                        lease: fields["lease"].flatMap(Self.parseHex)
                    ))
                }
                inRecord = false
                continue
            }
            guard inRecord, let separator = line.firstIndex(of: "=") else { continue }
            fields[String(line[line.startIndex ..< separator])] =
                String(line[line.index(after: separator)...])
        }
        return leases
    }

    /// The most recently issued lease, or nil if there are none.
    ///
    /// The file outlives the network, so an entry from a previous session reads
    /// exactly like a live one and nothing here can tell them apart. Newest is
    /// the best guess this file supports; the dial is what actually confirms it.
    public static func mostRecent(in contents: String) -> DHCPLease? {
        parse(contents).max { ($0.lease ?? 0) < ($1.lease ?? 0) }
    }

    private static func parseHex(_ value: String) -> UInt64? {
        let digits = value.hasPrefix("0x") ? String(value.dropFirst(2)) : value
        return UInt64(digits, radix: 16)
    }
}

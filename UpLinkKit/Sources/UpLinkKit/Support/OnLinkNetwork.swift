import Foundation

/// A network this Mac is directly attached to.
///
/// Exists because **"private" and "on-link" are different things**, and only
/// the second one is what the capture policy actually needs.
///
/// `CapturePolicy` excluded RFC 1918 and RFC 4193 space by address prefix, on
/// the reasonable-sounding theory that a local host is a local host. IPv6 does
/// not work that way: a home LAN gets a globally routable /64 delegated to it,
/// so this Mac and the phone sitting next to it both hold addresses that are
/// indistinguishable from real internet hosts by inspection —
/// `2001:db8:1:2:a113:…` and `2001:db8:1:2:23:…`. Nothing in a
/// prefix rule can separate those from a server in another country.
///
/// The consequence, measured on 2026-08-14: with the bridge up, every IPv6
/// neighbour on the user's own network was handed to a phone on a cellular
/// link that cannot reach it. The sharpest case was
/// `com.apple.CoreDevice.remotepairingd`, the Mac↔iPhone developer channel —
/// the Mac captured its own control connection to the phone and tried to route
/// it *through* the phone, 1217 claims in a few seconds, and the session died
/// inside three seconds every time.
///
/// This is the same lesson as resolvers, which `docs/REGRESSIONS.md` already
/// records: a globally-scoped address can still be local, so it has to be read
/// from the system rather than inferred.
public struct OnLinkNetwork: Sendable, Equatable, Hashable {

    /// The network address, with all host bits cleared.
    public let network: [UInt8]
    public let prefixLength: Int

    /// Refuses a prefix broad enough to swallow the internet.
    ///
    /// The failure mode this guards is total and silent: one interface
    /// reporting a `::/0` netmask would exclude every destination, the bridge
    /// would carry nothing, and it would present as "connected but no traffic"
    /// — the single hardest symptom to diagnose in this product, and the one it
    /// has already produced three times for other reasons. A real on-link
    /// network is a /64 or a /24; nothing legitimate is near these floors.
    public static let minimumIPv4PrefixLength = 8
    public static let minimumIPv6PrefixLength = 16

    public init?(address: String, prefixLength: Int) {
        guard let (bytes, isIPv6) = Self.parse(address) else { return nil }
        let maximum = isIPv6 ? 128 : 32
        let minimum = isIPv6 ? Self.minimumIPv6PrefixLength : Self.minimumIPv4PrefixLength
        guard prefixLength >= minimum, prefixLength <= maximum else { return nil }
        self.network = Self.masked(bytes, to: prefixLength)
        self.prefixLength = prefixLength
    }

    /// Whether `address` sits in this network.
    public func contains(_ address: String) -> Bool {
        guard let (bytes, _) = Self.parse(address), bytes.count == network.count else { return false }
        return Self.masked(bytes, to: prefixLength) == network
    }

    /// Parses a numeric address, tolerating an IPv6 zone (`fe80::1%en0`).
    ///
    /// The zone matters: `getnameinfo` returns link-local addresses in scoped
    /// form, and `inet_pton` rejects them outright, so without stripping it
    /// every link-local interface would be silently skipped.
    static func parse(_ address: String) -> (bytes: [UInt8], isIPv6: Bool)? {
        let bare = address.split(separator: "%", maxSplits: 1).first.map(String.init) ?? address

        var v6 = in6_addr()
        if bare.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            return (withUnsafeBytes(of: &v6) { Array($0) }, true)
        }
        var v4 = in_addr()
        if bare.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            return (withUnsafeBytes(of: &v4) { Array($0) }, false)
        }
        return nil
    }

    static func masked(_ bytes: [UInt8], to prefixLength: Int) -> [UInt8] {
        var out = bytes
        for index in out.indices {
            let bitsBefore = index * 8
            if bitsBefore >= prefixLength {
                out[index] = 0
            } else if bitsBefore + 8 > prefixLength {
                let keep = prefixLength - bitsBefore
                out[index] &= UInt8(truncatingIfNeeded: 0xFF << (8 - keep))
            }
        }
        return out
    }
}

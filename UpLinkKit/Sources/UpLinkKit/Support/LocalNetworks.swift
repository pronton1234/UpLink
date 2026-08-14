import Darwin
import Foundation

/// The networks this Mac is directly attached to, read from its interfaces.
///
/// The companion to ``SystemResolvers``, and for the same reason: a local
/// address cannot be recognised by inspection, so it has to be asked for. A
/// home LAN's IPv6 /64 is globally routable, which makes every neighbour on it
/// look exactly like an internet host — see ``OnLinkNetwork``.
///
/// Read at session start rather than once at launch, because the Mac may have
/// joined a different network since, and a stale list is wrong in the dangerous
/// direction: it would bridge a neighbour the phone cannot reach, which times
/// out rather than failing.
/// Lives in the kit, not the extension, so it can be run without deploying a
/// signed and notarized system extension. `getifaddrs` is portable; the
/// resolver list next door needs SystemConfiguration and cannot follow.
public enum LocalNetworks {

    public static func current() -> [OnLinkNetwork] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var found: [OnLinkNetwork] = []
        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(interface.pointee.ifa_flags)
            // Loopback is already excluded by its own rule, and a down
            // interface's address says nothing about what is reachable.
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }

            guard let address = interface.pointee.ifa_addr,
                  let netmask = interface.pointee.ifa_netmask,
                  address.pointee.sa_family == UInt8(AF_INET)
                    || address.pointee.sa_family == UInt8(AF_INET6),
                  let text = presentation(address),
                  let length = prefixLength(netmask),
                  let network = OnLinkNetwork(address: text, prefixLength: length)
            else { continue }

            if !found.contains(network) { found.append(network) }
        }
        return found
    }

    /// Numeric form. Link-local addresses come back scoped (`fe80::1%en0`),
    /// which ``OnLinkNetwork`` strips.
    private static func presentation(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = getnameinfo(
            address, socklen_t(address.pointee.sa_len),
            &buffer, socklen_t(buffer.count),
            nil, 0, NI_NUMERICHOST
        )
        guard status == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func prefixLength(_ netmask: UnsafeMutablePointer<sockaddr>) -> Int? {
        switch netmask.pointee.sa_family {
        case UInt8(AF_INET):
            return netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                var raw = $0.pointee.sin_addr.s_addr
                return leadingOnes(withUnsafeBytes(of: &raw) { Array($0) })
            }
        case UInt8(AF_INET6):
            return netmask.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                var raw = $0.pointee.sin6_addr
                return leadingOnes(withUnsafeBytes(of: &raw) { Array($0) })
            }
        default:
            return nil
        }
    }

    /// Counts the leading set bits of a contiguous netmask.
    private static func leadingOnes(_ bytes: [UInt8]) -> Int {
        var total = 0
        for byte in bytes {
            guard byte == 0xFF else {
                total += byte.leadingNonzeroBitCount
                break
            }
            total += 8
        }
        return total
    }
}

private extension UInt8 {
    /// Leading 1 bits, which for a well-formed netmask byte is all of them.
    var leadingNonzeroBitCount: Int { (~self).leadingZeroBitCount }
}

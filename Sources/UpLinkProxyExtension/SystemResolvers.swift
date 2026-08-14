import Foundation
import SystemConfiguration

/// The DNS servers this Mac is configured to use.
///
/// These must never be bridged. A resolver is almost always the local router,
/// reachable from this Mac and from nowhere else — least of all from a phone on
/// a cellular network. Sending a lookup there through the bridge cannot succeed;
/// it can only time out, and since every connection starts with a lookup, the
/// whole machine feels throttled while the bridge correctly reports that it is
/// carrying traffic over cellular.
///
/// Address prefixes cannot identify these. A resolver handed out by an AT&T
/// gateway looks like `2001:db8:1:2::1` — globally scoped, and
/// indistinguishable from a real internet host without knowing it is the
/// router. So the list is read from the system rather than inferred.
enum SystemResolvers {

    /// Reads the current resolver addresses from the dynamic store.
    ///
    /// Returns an empty set on failure rather than throwing: not knowing the
    /// resolvers is a degraded state, not a fatal one, and the private-network
    /// rules in ``CapturePolicy`` still catch the common IPv4 case.
    static func current() -> Set<String> {
        guard let store = SCDynamicStoreCreate(nil, "com.uplink.app.resolvers" as CFString, nil, nil),
              let dns = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any],
              let servers = dns["ServerAddresses"] as? [String]
        else { return [] }

        return Set(servers.map { $0.lowercased() })
    }
}

import Foundation

/// Decides which of the Mac's outbound flows cross the bridge.
///
/// Lives in the kit rather than the extension so the rules are testable without
/// a system extension, a notarized build, or a phone. The most important rule
/// by far is the first one — see ``shouldCapture(remoteEndpoint:)``.
public struct CapturePolicy: Sendable, Equatable {

    /// Endpoint descriptions belonging to the phone we are bridging through.
    public var peerEndpoints: Set<String> = []

    /// Hosts that must always be reached directly, never through the phone.
    ///
    /// In practice these are the Mac's own DNS resolvers. They are usually the
    /// home router, and a router is reachable from the Mac and from nowhere
    /// else — certainly not from a phone on a cellular network. Bridging a DNS
    /// query to one means the query is sent to the phone, which cannot deliver
    /// it, so the lookup times out and retries. Every page load then stalls on
    /// name resolution, which feels exactly like a throttled connection while
    /// the UI correctly reports that traffic is going over cellular.
    ///
    /// Prefix rules cannot catch this on their own: a resolver address like
    /// `2001:db8:1:2::1` is globally scoped and indistinguishable from a
    /// real internet host by inspection. It has to be named.
    public var directHosts: Set<String> = []

    /// Signing identifiers of apps whose traffic must never cross the bridge.
    ///
    /// The developer escape hatch, and the only exclusion that works for UDP.
    /// The other rules judge a *destination*, which a `NEAppProxyUDPFlow` does
    /// not have at claim time and which a datagram carries only as an already
    /// resolved IP — so naming a host cannot keep an app's UDP traffic off the
    /// bridge, and naming an IP cannot survive a service that rotates them.
    ///
    /// The concrete need: the machine driving a device test reaches its own API
    /// over this Mac's connection. A bridge that misbehaves takes that
    /// connection down, which takes down the ability to diagnose the bridge —
    /// so the debugging tool goes offline exactly when it is needed. Naming the
    /// app declines its flows before anything is claimed, which is the only
    /// point at which declining is free.
    public var directApps: Set<String> = []

    public init(
        peerEndpoints: Set<String> = [],
        directHosts: Set<String> = [],
        directApps: Set<String> = []
    ) {
        self.peerEndpoints = peerEndpoints
        self.directHosts = directHosts
        self.directApps = directApps
    }

    /// Whether flows belonging to `signingIdentifier` may be bridged at all.
    ///
    /// Judged separately from the endpoint because it applies to UDP sessions,
    /// which have no endpoint to judge.
    public func shouldCapture(app signingIdentifier: String?) -> Bool {
        guard let signingIdentifier, !directApps.isEmpty else { return true }
        return !directApps.contains(signingIdentifier)
    }

    /// Whether a flow to `remoteEndpoint` should be proxied.
    ///
    /// **The self-capture guard.** The extension's own connection to the phone
    /// is an outbound flow and matches the capture rules exactly like any
    /// other. Proxying it would mean the bytes we send to the phone get
    /// captured and sent to the phone, which captures them again — an unbounded
    /// loop that pegs the CPU and takes down all networking on the Mac within
    /// seconds. Recovering requires killing the extension, so this is the worst
    /// failure this codebase can produce.
    public func shouldCapture(remoteEndpoint: String) -> Bool {
        guard !remoteEndpoint.isEmpty else { return false }

        // 1. Never bridge our own link to the phone.
        if peerEndpoints.contains(remoteEndpoint) { return false }
        if let host = Self.host(of: remoteEndpoint),
           peerEndpoints.contains(where: { Self.host(of: $0) == host }) {
            return false
        }

        // 2. Never bridge loopback. It never leaves the machine, and capturing
        //    it would break every local development server on the box —
        //    including, now, nothing of ours, but plenty of the user's.
        if Self.isLoopback(remoteEndpoint) { return false }

        // 3. Never bridge link-local or multicast. That is where Bonjour
        //    discovery lives; capturing it would stop us finding the phone at
        //    all, making the bridge unrecoverable after any reconnect.
        if Self.isLinkLocalOrMulticast(remoteEndpoint) { return false }

        // 4. Never bridge the Mac's own resolvers.
        if let host = Self.host(of: remoteEndpoint)?.lowercased(),
           directHosts.contains(where: { $0.lowercased() == host }) {
            return false
        }

        // 5. Never bridge the local network. A printer, a NAS, a router admin
        //    page and a LAN development server are all reachable from this Mac
        //    and from nowhere else; handing one to a phone on a cellular
        //    network cannot succeed, it can only time out. Keeping them direct
        //    is also what the user expects — bridging should not disconnect
        //    them from their own house.
        if Self.isPrivateNetwork(remoteEndpoint) { return false }

        return true
    }

    /// Strips the port, tolerating bracketed IPv6 (`[fe80::1]:443`).
    static func host(of endpoint: String) -> String? {
        if endpoint.hasPrefix("[") {
            guard let close = endpoint.firstIndex(of: "]") else { return nil }
            return String(endpoint[endpoint.index(after: endpoint.startIndex) ..< close])
        }
        guard let colon = endpoint.lastIndex(of: ":") else { return endpoint }
        return String(endpoint[endpoint.startIndex ..< colon])
    }

    static func isLoopback(_ endpoint: String) -> Bool {
        guard let host = host(of: endpoint)?.lowercased() else { return false }
        return host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }

    /// RFC 1918 / RFC 4193 space: addresses that only mean something on the
    /// local network.
    ///
    /// The phone's own hotspot subnet (172.20.10.0/24) falls in here, which is
    /// correct twice over — it is the peer link, and it is not routable from
    /// the cellular side either.
    static func isPrivateNetwork(_ endpoint: String) -> Bool {
        guard let host = host(of: endpoint)?.lowercased() else { return false }

        if host.hasPrefix("10.") || host.hasPrefix("192.168.") { return true }

        // 172.16.0.0/12 is 172.16 through 172.31 — not all of 172.
        if host.hasPrefix("172.") {
            let parts = host.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16 ... 31).contains(second) {
                return true
            }
        }

        // IPv6 unique local addresses, fc00::/7.
        if host.hasPrefix("fc") || host.hasPrefix("fd") { return true }

        return false
    }

    static func isLinkLocalOrMulticast(_ endpoint: String) -> Bool {
        guard let host = host(of: endpoint)?.lowercased() else { return false }
        // IPv4 link-local (169.254/16), IPv4 multicast incl. mDNS (224.0.0.251),
        // IPv6 link-local (fe80::/10), IPv6 multicast (ff00::/8).
        return host.hasPrefix("169.254.")
            || host.hasPrefix("224.")
            || host.hasPrefix("fe80:")
            || host.hasPrefix("ff02:")
            || host.hasPrefix("ff00:")
    }
}

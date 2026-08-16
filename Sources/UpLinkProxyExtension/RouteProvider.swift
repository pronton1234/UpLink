import Foundation
import NetworkExtension
import OSLog
import UpLinkKit

/// Gives the Mac a network service, so that it has a route and a resolver.
///
/// **It carries no traffic.** Every packet it receives is counted and dropped.
/// That sounds absurd for a tunnel, and it is the entire point.
///
/// ## Why this exists
///
/// `NETransparentProxyProvider` intercepts flows at the socket layer, above
/// routing — so any flow that *can be originated* is handed to it. But a flow to
/// an internet destination cannot be originated at all when the Mac has no
/// route: `connect()` fails at route lookup first, and `handleNewFlow` is never
/// called. Measured 2026-08-14 with Wi-Fi disconnected and the bridge live and
/// healthy:
///
/// ```
/// IPv4 default route : NONE
/// flows claimed      : 0
/// curl by IP         : exitcode 7
/// scutil --dns       : empty
/// ```
///
/// and the controlled comparison, same machine, same second:
///
/// ```
/// curl --interface en0 (has route)  ->  http 301,   2 flows claimed
/// curl --interface en9 (no route)   ->  exitcode 7, 0 flows claimed
/// ```
///
/// So the route does not need to *carry* anything. It needs to exist, so the
/// socket can be created, so the policy check runs and the proxy takes the flow.
/// A packet tunnel is the only supported way to give macOS a primary network
/// service, and unlike a transparent proxy its `dnsSettings` are honoured — a
/// transparent proxy accepts them and silently ignores them, having no interface
/// to attach them to.
///
/// This replaces `scripts/standalone-mode.sh`, which achieved the same thing by
/// pointing the Wi-Fi service at a dead gateway with `networksetup`. That needed
/// root, left macOS believing Wi-Fi was misconfigured, and had to be run by hand
/// in the right order.
///
/// ## The packet counter is a measurement, not bookkeeping
///
/// If the proxy keeps winning the flows, almost nothing should arrive here —
/// only ICMP and whatever the proxy declines. A steady stream means the tunnel
/// is capturing traffic the proxy should have taken, and since this drops
/// everything, that is a total outage rather than a slow path. The count is how
/// that is known rather than guessed.
final class RouteProvider: NEPacketTunnelProvider, @unchecked Sendable {

    private let log = Logger(subsystem: UpLinkIdentifiers.logSubsystem, category: "route")

    /// Any address will do; nothing is ever sent here. It exists because
    /// `NEPacketTunnelNetworkSettings` requires the interface to have one.
    private static let tunnelAddress = "10.55.1.2"
    private static let tunnelMask = "255.255.255.0"
    private static let tunnelAddressV6 = "fd00:1155::2"

    private let counter = PacketCounter()

    /// The mode currently applied, so a mode message that changes nothing does
    /// not re-apply settings once a second. `nil` means "unknown" — set on a
    /// rejection, so the next message retries rather than believing a mode that
    /// never took.
    ///
    /// A lock rather than an actor because `handleAppMessage` is synchronous;
    /// hopping to an actor to answer it is how a reply gets lost.
    private let modeLock = NSLock()
    private var appliedMode: RouteTunnelMode?

    /// Settings for a mode.
    ///
    /// **Two modes, because this tunnel is never stopped.** It used to be
    /// stopped whenever the bridge session went away, and restarted when one
    /// came back — which cannot work, because NetworkExtension refuses to start
    /// a packet tunnel on a Mac with no network, and the whole point of this
    /// product is a Mac with no network. Measured 2026-08-15, thirty times in
    /// thirty-one seconds:
    ///
    ///     NESMVPNSessionStatePreparingNetwork → "No network available"
    ///     status changed to disconnected, last stop reason No network available
    ///
    /// An already-running tunnel has no such problem: the same session then
    /// stayed connected for twenty minutes with the Wi-Fi radio off. So the
    /// tunnel stays up and changes what it captures, which is a settings call
    /// on a live interface and needs no network at all.
    ///
    /// See ``RouteTunnelReconciler`` for the decision that drives this.
    private static func settings(for mode: RouteTunnelMode) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        let ipv4 = NEIPv4Settings(addresses: [tunnelAddress], subnetMasks: [tunnelMask])
        let ipv6 = NEIPv6Settings(addresses: [tunnelAddressV6], networkPrefixLengths: [64])

        switch mode {
        case .capture:
            // The OPPOSITE of the iOS tunnel, which sets `includedRoutes = []`
            // because it is a process host that must capture nothing. Here the
            // default route is the whole product of this provider.
            ipv4.includedRoutes = [NEIPv4Route.default()]
            // IPv6 too, or a v6-capable destination is routed out whatever
            // interface still has a v6 default — which is a leak, and on this
            // machine there are stale v6 defaults via idle utun interfaces that
            // outlive the network they belonged to.
            ipv6.includedRoutes = [NEIPv6Route.default()]
            // The half a transparent proxy cannot do. With no network service
            // the Mac has no resolver at all — `scutil --dns` comes back empty
            // — so name resolution fails before a packet is sent, and the
            // bridge looks dead while working perfectly because there is
            // nothing for it to carry. Public anycast because it must be
            // reachable THROUGH the bridge: a query to 1.1.1.1 is an ordinary
            // public destination the capture policy carries to the phone.
            settings.dnsSettings = NEDNSSettings(servers: UpLinkDNS.servers)

        case .standby:
            // NO ROUTES AND NO RESOLVER. This is what makes never stopping the
            // tunnel safe: with no bridge behind it, a capturing tunnel drops
            // every packet the proxy declines, and the Mac has no network at
            // all until both apps are quit. Here it holds an address, keeps the
            // interface alive so it never has to be started again, and takes
            // nothing.
            ipv4.includedRoutes = []
            ipv6.includedRoutes = []
            settings.dnsSettings = nil
        }

        settings.ipv4Settings = ipv4
        settings.ipv6Settings = ipv6
        settings.mtu = 1500
        return settings
    }

    /// Applies a mode, unless it is already the one in force.
    private func apply(_ mode: RouteTunnelMode, then: @escaping @Sendable (Error?) -> Void) {
        modeLock.lock()
        let unchanged = (appliedMode == mode)
        appliedMode = mode
        modeLock.unlock()
        guard !unchanged else { then(nil); return }

        let log = self.log
        setTunnelNetworkSettings(Self.settings(for: mode)) { [weak self] error in
            if let error {
                log.error("route: \(String(describing: mode), privacy: .public) settings rejected: \(error.localizedDescription, privacy: .public)")
                // Forget it, so the next tick tries again rather than believing
                // a mode that never took.
                if let self {
                    self.modeLock.lock()
                    self.appliedMode = nil
                    self.modeLock.unlock()
                }
            } else {
                switch mode {
                case .capture:
                    log.error("route: capturing — default routes and DNS \(UpLinkDNS.servers.joined(separator: ","), privacy: .public)")
                case .standby:
                    log.error("route: standby — no routes, no resolver; this Mac's own network is untouched")
                }
            }
            then(error)
        }
    }

    /// The app's 1Hz reconciler telling us what to capture.
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        let wanted: RouteTunnelMode
        switch String(decoding: messageData, as: UTF8.self) {
        case "capture": wanted = .capture
        case "standby": wanted = .standby
        default:
            completionHandler?(Data("unknown".utf8))
            return
        }
        // Boxed for the same reason as `startTunnel`'s: the completion handler
        // is a non-Sendable function type crossing into a @Sendable closure.
        let done = UncheckedSendableBox(completionHandler)
        apply(wanted) { error in
            done.value?(Data((error == nil ? "ok" : "failed").utf8))
        }
    }

    // Completion-handler form rather than the async override: the async variant
    // receives a non-Sendable `[String: NSObject]?` across an isolation
    // boundary, which Swift 6 rejects. Same reason as the iOS provider.
    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        log.error("route: startTunnel")

        let log = self.log
        let counter = self.counter
        let done = UncheckedSendableBox(completionHandler)
        let flow = UncheckedSendableBox(packetFlow)

        // STARTS IN STANDBY, ALWAYS, whatever prompted the start.
        //
        // The tunnel is started eagerly now — while the Mac still has a network
        // to start it with — rather than at the moment a session appears, which
        // is the moment the network has been taken away. Coming up capturing
        // would mean an eager start broke the user's Wi-Fi; the reconciler
        // switches it to `.capture` on the next tick if a session is live.
        apply(.standby) { error in
            if let error {
                done.value(error)
                return
            }
            // The read loop lives out here rather than inside the actor: it has
            // to touch `packetFlow`, which is not Sendable, and Swift 6 rejects
            // sending a closure that does so into actor-isolated code. The actor
            // keeps only the count.
            let task = Task {
                var reported = 0
                while !Task.isCancelled {
                    let packets = await Self.readPackets(from: flow)
                    let seen = await counter.add(packets.count)
                    // On a change, not per packet. A per-packet line on the hot
                    // path is how session diagnostics got evicted from the log
                    // buffer before.
                    if seen - reported >= 100 || (seen > 0 && reported == 0) {
                        reported = seen
                        log.error("route: packets \(seen, privacy: .public) — flows the proxy did NOT claim")
                    }
                }
            }
            Task { await counter.hold(task) }
            done.value(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        log.error("route: stopTunnel \(reason.rawValue, privacy: .public)")
        let counter = self.counter
        let done = UncheckedSendableBox(completionHandler)
        Task {
            await counter.stop()
            done.value()
        }
    }

    /// One batch from the tunnel. `nonisolated static` so the non-Sendable
    /// `packetFlow` is only ever touched through the box, never captured by
    /// actor-isolated code.
    private static func readPackets(
        from flow: UncheckedSendableBox<NEPacketTunnelFlow>
    ) async -> [Data] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[Data], Never>) in
            flow.value.readPackets { packets, _ in continuation.resume(returning: packets) }
        }
    }
}

/// Drains the tunnel and reports how much arrived.
///
/// Reading is not optional even though everything is discarded: an unread
/// `packetFlow` applies backpressure into the stack rather than politely doing
/// nothing, so a tunnel that ignores its packets is worse than one that drops
/// them. Discarding is also the safe failure: a packet that reaches here is one
/// the proxy did not claim, and forwarding it is not possible — this provider
/// has no connection to the phone, by design.
private actor PacketCounter {

    private var task: Task<Void, Never>?
    private var total = 0

    func hold(_ task: Task<Void, Never>) { self.task = task }

    /// Returns the running total so the caller can decide whether to log,
    /// without a second hop back into the actor.
    func add(_ n: Int) -> Int {
        total += n
        return total
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

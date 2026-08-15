import Foundation
import Network
import OSLog

/// Keeps AWDL scheduled between sessions by holding a unicast socket to the
/// peer.
///
/// ## The deadlock this breaks
///
/// The kernel decides AWDL's airtime from how many active AWDL sockets it sees.
/// Measured 2026-08-14, with the Mac's Wi-Fi disconnected:
///
///   1. the session dies within ~60ms of the infra link dropping, because the
///      kernel re-derives `awdl0` and the TCP connection goes with it;
///   2. `SocketsActive` falls to 0 and the schedule drops to Low Power;
///   3. mDNSResponder then stops transmitting on `awdl0` — measured silence of
///      102 seconds, from 16:28:14 to 16:29:56;
///   4. so the phone browses and finds nothing, cannot dial, and no socket is
///      created — which is what kept the schedule in Low Power.
///
/// AWDL is not dead during this. The radio stayed up, and the kernel logged a
/// `PeerAdd` for the phone at 16:29:24, in the middle of the window. What is
/// missing is a reason to schedule airtime.
///
/// ## Why unicast, and why not the listener
///
/// The Mac's TCP listener does not count: one was running throughout that entire
/// window while `SocketsActive` stayed 0. Nor does multicast — a probe sending a
/// datagram a second to `ff02::1%awdl0` for 20 seconds produced 22 kernel samples
/// at `SocketsActive 0` and one at 1. Only the real unicast session moved it,
/// and while it was up the schedule sat in `Data` at 76% duty cycle.
///
/// So this holds a unicast UDP socket to the peer's own link-local address,
/// which is exactly the shape that was observed to work. It is not a fight with
/// the kernel; it is telling the kernel the truth, that we still want this link.
///
/// ## Not yet verified on hardware
///
/// The mechanism is inferred from the kernel's own counter and one negative
/// control. Whether an *idle* unicast socket counts the same as a busy one is
/// the open question, and it needs the phone to answer.
public actor AWDLPresence {

    private let log = Logger(subsystem: UpLinkIdentifiers.logSubsystem, category: "presence")

    /// One a second: frequent enough to keep the socket unambiguously live,
    /// rare enough to be irrelevant to battery next to the radio itself.
    private static let heartbeat: Duration = .seconds(1)

    /// Held for at most this long after a session ends.
    ///
    /// Bounded because this costs airtime and battery, and a peer that has not
    /// come back in three minutes has gone away rather than blinked. The
    /// recovery being rescued here took under two.
    private static let maximumHold: Duration = .seconds(180)

    /// Discard port. Nothing listens, and nothing should: the socket existing is
    /// the entire point, not anything it carries.
    private static let port: NWEndpoint.Port = 9

    private let queue: DispatchQueue
    private var connection: NWConnection?
    private var task: Task<Void, Never>?

    public init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// Whether a hold is currently in place. For tests and for the log.
    public var isHolding: Bool { connection != nil }

    /// Starts holding the link open towards `peer`.
    ///
    /// A no-op unless the peer is an AWDL-scoped link-local address: on a shared
    /// network or over USB the kernel is not making this decision, and an extra
    /// socket would buy nothing.
    public func hold(peerDescription: String) {
        guard let host = Self.awdlHost(in: peerDescription) else {
            log.error("not holding: \(peerDescription, privacy: .public) is not an AWDL peer")
            return
        }
        release()

        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v6
        }

        let connection = NWConnection(host: NWEndpoint.Host(host), port: Self.port, using: parameters)
        connection.start(queue: queue)
        self.connection = connection
        log.error("holding AWDL open towards \(host, privacy: .public)")

        task = Task { [weak self] in
            let deadline = ContinuousClock.now + Self.maximumHold
            while !Task.isCancelled, ContinuousClock.now < deadline {
                connection.send(content: Data("uplink".utf8), completion: .contentProcessed { _ in })
                try? await Task.sleep(for: Self.heartbeat)
            }
            await self?.expire()
        }
    }

    /// Stops holding. Called when a session is established — the session's own
    /// socket is a better reason for the kernel to schedule AWDL than ours.
    public func release() {
        task?.cancel()
        task = nil
        connection?.cancel()
        connection = nil
    }

    private func expire() {
        guard connection != nil else { return }
        log.error("hold expired after \(Self.maximumHold.components.seconds)s without a session")
        release()
    }

    /// The host part of a peer description, but only when it is AWDL.
    ///
    /// TWO formats reach this, and getting it wrong is silent. `MacSessionHost`
    /// builds `"\(host):\(port)"` for a `.hostPort` endpoint, giving
    /// `fe80::2063:e4ff:fed6:7ce0%awdl0:52540` — colon-separated. The `accept:`
    /// log line prints `String(describing:)` instead, giving
    /// `fe80::…%awdl0.52540` — dot-separated.
    ///
    /// The first version handled only the dot form, because that is the one
    /// visible in the log, and its test pinned that form too. So the test was
    /// green against an input the code never actually receives, and in
    /// production the hold was made towards a host with `:52540` glued on.
    ///
    /// The separator is located AFTER the `%` scope, which is what makes this
    /// unambiguous: an IPv6 literal is full of colons, so "split on the last
    /// colon" would turn a bare `fe80::1` into `fe80:`.
    static func awdlHost(in description: String) -> String? {
        guard let scope = description.range(of: "%awdl") else { return nil }

        let afterScope = description[scope.lowerBound...]
        guard let separator = afterScope.lastIndex(where: { $0 == ":" || $0 == "." }) else {
            return description
        }
        let port = afterScope[afterScope.index(after: separator)...]
        guard !port.isEmpty, port.allSatisfy(\.isNumber) else { return description }
        return String(description[description.startIndex ..< separator])
    }
}

import Foundation
import Network

/// Opens destination connections on the phone, pinned to the cellular radio.
///
/// This type is the entire product in one place. Everything else — discovery,
/// pairing, framing, flow control — exists to get a byte here, where it leaves
/// the phone through `requiredInterfaceType = .cellular` on an ordinary app
/// socket. The carrier sees traffic from an app, with the phone's own TTL and
/// on the phone's normal APN, which is what makes it indistinguishable from any
/// other app's data rather than recognisable as tethering.
public actor CellularDialer: DestinationDialer {

    private let queue: DispatchQueue
    private let requiredInterface: NWInterface.InterfaceType?
    private let bearer: WirelessBearer

    /// - Parameter requiredInterface: `.cellular` in production. Injectable so
    ///   the spike apps and the Simulator (which has no cellular radio) can run
    ///   the same code path unpinned.
    /// - Parameter bearer: which link carries the peer connection. Determines
    ///   the interfaces a destination dial must refuse — see ``WirelessBearer``.
    public init(
        queue: DispatchQueue,
        requiredInterface: NWInterface.InterfaceType? = .cellular,
        bearer: WirelessBearer = .hostedAP
    ) {
        self.queue = queue
        self.requiredInterface = requiredInterface
        self.bearer = bearer
    }

    public func connect(to destination: StreamOpen) async throws -> DestinationConnection {
        let parameters = Self.parameters(
            for: destination, requiredInterface: requiredInterface, bearer: bearer
        )

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(destination.host),
            port: NWEndpoint.Port(rawValue: destination.port) ?? .https
        )

        let connection = NWConnection(to: endpoint, using: parameters)
        let wrapper = NWDestinationConnection(connection: connection)
        try await wrapper.start(on: queue)
        return wrapper
    }

    /// How a proxied connection leaves the phone.
    ///
    /// Split out from ``connect(to:)`` so the egress pinning — which is the
    /// product's entire claim — can be asserted directly. A test that rebuilt
    /// these parameters itself would prove nothing about what ships.
    static func parameters(
        for destination: StreamOpen,
        requiredInterface: NWInterface.InterfaceType?,
        bearer: WirelessBearer
    ) -> NWParameters {
        let parameters: NWParameters
        switch destination.proto {
        case .tcp:
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            parameters = NWParameters(tls: nil, tcp: tcp)
        case .udp:
            parameters = NWParameters(dtls: nil, udp: NWProtocolUDP.Options())
        }

        // The line the whole product rests on. Left unset when nil so the
        // Simulator, which has no cellular radio, can exercise this same path.
        if let requiredInterface {
            parameters.requiredInterfaceType = requiredInterface
        }

        // NEW HAZARD WITH THE CABLE, and it points the wrong way down the very
        // link that carries the bridge.
        //
        // Plugging the phone into the Mac gives the phone a wired Ethernet
        // interface. If the Mac ever has a route to share — Personal Hotspot in
        // the other direction, an old `standalone-mode` address left behind,
        // internet sharing switched on — the phone can egress back up the cable
        // instead of over cellular. The bridge would then carry traffic from
        // the Mac to the phone and straight back to the Mac: the user is not
        // bypassing anything, and the egress report would say `.wiredEthernet`
        // rather than `.cellular` only *after* the fact.
        //
        // `requiredInterfaceType` alone does not cover this. It is documented
        // as a preference that Network.framework may fall back from, which is
        // precisely how a Wi-Fi fallback was observed being reported as a
        // successful cellular dial. Prohibiting the interface outright is the
        // half that cannot be negotiated away.
        //
        // AND THE SAME HAZARD EXISTS WIRELESSLY, one interface over. With the
        // phone associated to an access point the Mac hosts, a dial satisfied
        // over Wi-Fi leaves the phone, crosses the access point and arrives
        // back at the Mac — the identical loop, reached by a different radio.
        //
        // So the prohibited set is not a property of this dialer, it is a
        // property of whichever link is carrying the peer connection. Asking
        // the bearer is what stops the two from drifting apart when one is
        // added. Loopback is deliberately NOT prohibited by any of them: a
        // destination on the phone's own loopback is not a way around the
        // bridge, and banning it breaks every integration test that points
        // "the internet" at a local server — which is how the datagram and
        // refused-destination suites are able to run without a network at all.
        parameters.prohibitedInterfaceTypes = bearer.prohibitedEgressInterfaces

        // Never route a proxied connection through a proxy configured on the
        // phone — that would silently re-route the user's traffic somewhere
        // they did not ask for.
        parameters.preferNoProxies = true

        return parameters
    }
}

/// A live connection to one destination.
actor NWDestinationConnection: DestinationConnection {

    private let connection: NWConnection
    private var pending: [Data] = []
    private var waiters: [CheckedContinuation<Data?, Error>] = []
    private var isClosed = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    /// How long a destination may take to answer before the dial is abandoned.
    ///
    /// Shorter than the peer link's timeout: this is one destination host, and
    /// a stream waiting on it is a browser tab spinning.
    public static let connectTimeout: TimeInterval = 10

    /// Whether waiting could still plausibly help.
    ///
    /// `NWConnection` reports a refused, unreachable or unresolvable
    /// destination as `.waiting`, not `.failed`, because it will keep retrying
    /// if the path changes. For a proxied flow that is the wrong trade: the Mac
    /// has a tab open waiting for an answer, and "connection refused" is not
    /// going to improve. Genuinely transient conditions — the radio still
    /// coming up, no route yet — are left to the timeout.
    private static func isTerminal(_ error: NWError) -> Bool {
        switch error {
        case .dns:
            return true
        case let .posix(code):
            return code == .ECONNREFUSED
                || code == .EHOSTUNREACH
                || code == .ENETUNREACH
                || code == .ECONNRESET
                || code == .ETIMEDOUT
        default:
            return false
        }
    }

    /// Starts the connection and waits until it is usable or has failed.
    ///
    /// Every terminal state must resume the continuation. An earlier version
    /// handled only `.ready`, `.failed` and `.cancelled`, so a dial that could
    /// not be satisfied sat in `.waiting` forever and this never returned. The
    /// stream it belonged to hung until the Mac's own flow gave up, which is
    /// what filled the logs with `udp flow failed: The peer closed the flow`.
    func start(on queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OneShot<Void>(continuation)

            // No cancellation needed: OneShot resumes at most once, so this
            // fires harmlessly if the dial already settled.
            queue.asyncAfter(deadline: .now() + Self.connectTimeout) {
                once.resume(throwing: ChannelError.handshakeFailed(
                    "destination did not answer within \(Int(Self.connectTimeout))s"
                ))
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume(returning: ())
                case let .failed(error):
                    once.resume(throwing: error)
                case .cancelled:
                    once.resume(throwing: ChannelError.peerClosed)
                case let .waiting(error):
                    if Self.isTerminal(error) { once.resume(throwing: error) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
        pump()
    }

    /// Reports the interface this connection is **actually** using.
    ///
    /// Read from `currentPath` after the connection is ready, deliberately not
    /// inferred from what we asked for. If iOS satisfied the connection over
    /// Wi-Fi despite the cellular requirement, the user needs to be told —
    /// that is the difference between the bridge working and merely appearing
    /// to work.
    func egressInterface() async -> EgressInterface {
        guard let path = connection.currentPath else { return .unknown }

        // `usesInterfaceType` reflects the path actually selected.
        if path.usesInterfaceType(.cellular) { return .cellular }
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.wiredEthernet) { return .wired }
        if path.usesInterfaceType(.loopback) { return .loopback }
        return .other
    }

    /// Continuously drains the destination socket.
    ///
    /// **`isComplete` does not mean "the connection is over".** On a UDP
    /// connection it marks the end of each *message*, and every datagram sets
    /// it. Treating it as end-of-connection — which this did — closed the
    /// destination the instant its first reply arrived: `receive()` returned
    /// nil forever after, the datagram pump broke out of its loop, and that
    /// destination was dead for the rest of the session.
    ///
    /// DNS is the worst victim, because a resolver is one destination expected
    /// to answer many queries. The first lookup succeeded and every later one
    /// hung until the flow was aborted, so the bridge carried TCP at full speed
    /// while no hostname would resolve.
    ///
    /// A real end-of-stream is `isComplete` with nothing in hand: TCP's FIN
    /// delivers no bytes. A datagram always carries some, so it never trips this.
    private nonisolated func pump() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            Task { [weak self] in
                guard let self else { return }
                let carriedBytes = !(data?.isEmpty ?? true)
                if carriedBytes, let data { await self.deliver(data) }

                let endOfStream = isComplete && !carriedBytes
                if endOfStream || error != nil { await self.finish() }
                else { self.pump() }
            }
        }
    }

    private func deliver(_ data: Data) {
        if waiters.isEmpty { pending.append(data) }
        else { waiters.removeFirst().resume(returning: data) }
    }

    private func finish() {
        guard !isClosed else { return }
        isClosed = true
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting { waiter.resume(returning: nil) }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    func receive() async throws -> Data? {
        if !pending.isEmpty { return pending.removeFirst() }
        if isClosed { return nil }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func close() async {
        finish()
        connection.cancel()
    }
}

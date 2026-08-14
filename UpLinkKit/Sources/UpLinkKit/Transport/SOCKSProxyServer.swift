import Foundation
import Network
import OSLog

/// Listens on loopback and turns each SOCKS5 CONNECT into a bridged stream.
///
/// Runs inside the ordinary Mac app — no extension, no entitlement ceremony.
/// Binding to `127.0.0.1` rather than all interfaces is the security boundary:
/// only processes on this Mac can reach it, so no authentication is needed and
/// nobody on the network can borrow the phone's cellular plan.
public actor SOCKSProxyServer {

    /// Conventional SOCKS port, and what the system proxy is pointed at.
    public static let defaultPort: UInt16 = 1080

    private let log = Logger(subsystem: UpLinkIdentifiers.logSubsystem, category: "socks")
    private let port: UInt16
    private let queue: DispatchQueue

    private var listener: NWListener?
    /// Nil when no phone is connected; every CONNECT fails fast until it is set.
    private var initiator: BridgeInitiator?
    private var activeConnections = 0

    public init(port: UInt16 = SOCKSProxyServer.defaultPort, queue: DispatchQueue) {
        self.port = port
        self.queue = queue
    }

    public var isRunning: Bool { listener != nil }
    public var connectionCount: Int { activeConnections }

    public func setInitiator(_ initiator: BridgeInitiator?) {
        self.initiator = initiator
    }

    public func start() throws {
        guard listener == nil else { return }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Loopback only — this is the whole access-control story, and it is why
        // the proxy needs no authentication.
        //
        // The bind address is expressed ONLY via requiredLocalEndpoint. Passing
        // `on:` as well contradicts it (one says "port on any interface", the
        // other "this address and port") and the listener never comes up.
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!
        )

        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case let .failed(error) = state {
                Task { await self?.logFailure(error) }
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        log.info("SOCKS5 listening on 127.0.0.1:\(self.port)")
    }

    private func logFailure(_ error: NWError) {
        log.error("listener failed: \(error.localizedDescription, privacy: .public)")
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) async {
        activeConnections += 1
        let client = LocalConnection(connection: connection)

        do {
            try await client.start(on: queue)
            try await serve(client)
        } catch {
            log.debug("client ended: \(String(describing: error), privacy: .public)")
        }

        await client.close()
        activeConnections -= 1
    }

    private func serve(_ client: LocalConnection) async throws {
        var handshake = SOCKS5Handshake()

        // Drive the handshake until a destination is known.
        while handshake.state != .ready {
            guard let bytes = try await client.receive() else { return }
            guard let reply = try handshake.consume(bytes) else { continue }
            try await client.send(reply)
            if handshake.state == .failed { return }
        }

        guard let destination = handshake.destination else { return }

        guard let initiator else {
            // No phone connected. Answer properly rather than hanging, so the
            // browser shows a clean error instead of spinning.
            try await client.send(SOCKS5Handshake.reply(.networkUnreachable))
            return
        }

        let stream: ProxiedStream
        do {
            stream = try await initiator.openStream(to: destination)
        } catch {
            try await client.send(SOCKS5Handshake.reply(.hostUnreachable))
            return
        }

        try await client.send(SOCKS5Handshake.reply(.succeeded))

        // A client may pipeline its first request bytes into the same packet as
        // the CONNECT. Dropping them would truncate the very first request.
        let pipelined = handshake.takeBufferedPayload()
        if !pipelined.isEmpty {
            try await stream.send(pipelined)
        }

        await pump(client: client, stream: stream)
    }

    /// Shuttles bytes both ways until either side closes.
    ///
    /// Nothing is buffered to disk: a `Data` goes from one socket to the other
    /// and is released.
    private func pump(client: LocalConnection, stream: ProxiedStream) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                while let data = try? await client.receive(), !data.isEmpty {
                    guard (try? await stream.send(data)) != nil else { break }
                }
                await stream.close()
            }
            group.addTask {
                while let data = await stream.receive() {
                    guard (try? await client.send(data)) != nil else { break }
                }
                await client.close()
            }
        }
    }
}

/// One local client of the SOCKS proxy.
actor LocalConnection {

    private let connection: NWConnection
    private var pending: [Data] = []
    private var waiters: [CheckedContinuation<Data?, Error>] = []
    private var isClosed = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start(on queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = OneShot<Void>(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(returning: ())
                case let .failed(error): once.resume(throwing: error)
                case .cancelled: once.resume(throwing: ChannelError.peerClosed)
                default: break
                }
            }
            connection.start(queue: queue)
        }
        pump()
    }

    private nonisolated func pump() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            Task { [weak self] in
                guard let self else { return }
                if let data, !data.isEmpty { await self.deliver(data) }
                if isComplete || error != nil { await self.finish() } else { self.pump() }
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

    func close() {
        finish()
        connection.cancel()
    }
}

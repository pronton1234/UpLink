import Foundation
import OSLog

/// A duplex byte pipe over a POSIX socket.
///
/// Deliberately not `NWConnection`: the `usbmuxd` control socket is
/// `AF_UNIX`, and after a successful `Connect` the very same descriptor becomes
/// the data pipe to the phone. Network.framework cannot adopt an existing file
/// descriptor, so the socket must be driven directly.
///
/// Reads and writes get separate queues because the link is genuinely full
/// duplex — a single queue would let a large upload block every inbound frame,
/// which is the head-of-line stall `ConcurrencyRegressionTests` already guards
/// against one layer up.
final class RawSocket: @unchecked Sendable {

    private let fd: Int32
    private let readQueue: DispatchQueue
    private let writeQueue: DispatchQueue
    private let lock = NSLock()
    private var isClosed = false

    /// Reads and writes currently blocked inside a syscall on ``fd``.
    ///
    /// **The descriptor must outlive them.** `close()` runs on a different
    /// thread from the blocked `read`, and closing a descriptor out from under
    /// a syscall does not merely fail that call: the number is immediately free
    /// for the kernel to hand to the *next* socket any thread opens, so the
    /// blocked read can resume against a completely unrelated connection and
    /// the subsequent `close` shuts down someone else's. Under a parallel test
    /// run — many sockets opening and closing at once — this took the whole
    /// process down rather than failing a case.
    ///
    /// So `close()` only ever calls `shutdown`, which is what actually unblocks
    /// a waiting read, and whoever finishes last performs the real `close`.
    private var inFlight = 0

    init(fd: Int32, label: String) {
        self.fd = fd
        self.readQueue = DispatchQueue(label: "\(label).read")
        self.writeQueue = DispatchQueue(label: "\(label).write")
    }

    /// Claims the descriptor for one syscall. Returns false if it is gone.
    private func retainFD() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return false }
        inFlight += 1
        return true
    }

    /// Releases it, closing for real if this was the last user of a socket
    /// that has already been asked to close.
    private func releaseFD() {
        lock.lock()
        inFlight -= 1
        let shouldClose = isClosed && inFlight == 0
        lock.unlock()
        if shouldClose { Darwin.close(fd) }
    }

    /// Opens a `SOCK_STREAM` connection to a UNIX-domain socket path.
    static func connectUnix(path: String) throws -> RawSocket {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(path.utf8)
        // `sun_path` is 104 bytes on Darwin and is NOT length-prefixed, so an
        // over-long path would be silently truncated into a different socket.
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            throw USBMuxError.unavailable("socket path is longer than \(capacity - 1) bytes: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw USBMuxError.unavailable("socket() failed: \(String(cString: strerror(errno)))")
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(fd)
            throw USBMuxError.unavailable("connect(\(path)) failed: \(reason)")
        }

        // The pipe carries interactive browsing traffic multiplexed with bulk
        // transfers; Nagle would add a delay to every small frame.
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))

        return RawSocket(fd: fd, label: "com.uplink.usbmux")
    }

    /// Writes every byte, looping over short writes.
    func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async { [self] in
                guard retainFD() else {
                    continuation.resume(throwing: USBMuxError.disconnected)
                    return
                }
                defer { releaseFD() }
                var sent = 0
                let total = data.count
                let outcome: Result<Void, Error> = data.withUnsafeBytes { raw -> Result<Void, Error> in
                    guard let base = raw.baseAddress else { return .success(()) }
                    while sent < total {
                        let written = Darwin.write(fd, base.advanced(by: sent), total - sent)
                        if written > 0 {
                            sent += written
                            continue
                        }
                        // Interrupted by a signal is not an error; retry.
                        if written < 0 && errno == EINTR { continue }
                        return .failure(USBMuxError.disconnected)
                    }
                    return .success(())
                }
                continuation.resume(with: outcome)
            }
        }
    }

    /// Reads whatever is available, up to `max` bytes. `nil` means the peer
    /// closed — end of stream, not an error.
    func read(max: Int = 64 * 1024) async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
            readQueue.async { [self] in
                guard retainFD() else {
                    continuation.resume(returning: nil)
                    return
                }
                defer { releaseFD() }
                var buffer = [UInt8](repeating: 0, count: max)
                while true {
                    let count = buffer.withUnsafeMutableBytes { raw in
                        Darwin.read(fd, raw.baseAddress, max)
                    }
                    if count > 0 {
                        continuation.resume(returning: Data(buffer[0 ..< count]))
                        return
                    }
                    if count == 0 {
                        continuation.resume(returning: nil)
                        return
                    }
                    if errno == EINTR { continue }
                    // Everything else is end of stream. A close() from another
                    // task shuts the socket down precisely to break us out of
                    // this blocking read, so an error here is the normal
                    // teardown path as often as it is a real fault — and the
                    // layer above treats both identically: the session ends
                    // and is redialled.
                    continuation.resume(returning: nil)
                    return
                }
            }
        }
    }

    private var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isClosed
    }

    /// Idempotent.
    ///
    /// `shutdown` is what unblocks a waiting `read`; the descriptor itself is
    /// only closed once nothing is inside a syscall on it. See ``inFlight``.
    func close() {
        lock.lock()
        let alreadyClosed = isClosed
        isClosed = true
        let canCloseNow = inFlight == 0
        lock.unlock()
        guard !alreadyClosed else { return }
        shutdown(fd, SHUT_RDWR)
        if canCloseNow { Darwin.close(fd) }
    }
}

/// A `FrameChannel` over a raw `usbmuxd` pipe.
///
/// Once `Connect` succeeds the control socket stops speaking the plist protocol
/// and becomes an ordinary byte stream to the port on the phone, so this is a
/// thin adapter — everything above it (TLS, framing, the multiplexer) is
/// unchanged from the AWDL era.
public actor USBMuxChannel: FrameChannel {

    private let socket: RawSocket
    /// Bytes that arrived in the same read as the `Connect` result.
    ///
    /// The daemon can coalesce its `Result` reply and the first data from the
    /// phone into one TCP segment. Dropping the remainder loses the first
    /// frame of the session, which presents as a handshake that hangs — the
    /// same class of bug `BridgeInitiator.run(resuming:decoder:)` exists to
    /// avoid one layer up.
    private var carryOver: Data?
    private var isClosed = false

    init(socket: RawSocket, carryOver: Data?) {
        self.socket = socket
        self.carryOver = (carryOver?.isEmpty == false) ? carryOver : nil
    }

    public func send(_ data: Data) async throws {
        guard !isClosed else { throw ChannelError.notConnected }
        try await socket.write(data)
    }

    public func receive() async throws -> Data? {
        if let pending = carryOver {
            carryOver = nil
            return pending
        }
        guard !isClosed else { return nil }
        return try await socket.read()
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        socket.close()
    }
}

public enum USBDeviceEvent: Sendable, Equatable {
    case attached(USBDevice)
    case detached(deviceID: UInt32)
}

/// Talks to `usbmuxd`.
///
/// The socket path is injectable so the test suite can point this at a fake
/// daemon on a temporary path and exercise attach, detach, refusal, and the
/// Wi-Fi-device filter with no cable and no phone.
public struct USBMuxClient: Sendable {

    /// Where `usbmuxd` listens on macOS.
    public static let defaultSocketPath = "/var/run/usbmuxd"

    private let socketPath: String
    private let log = Logger(subsystem: UpLinkIdentifiers.logSubsystem, category: "usbmux")

    public init(socketPath: String = USBMuxClient.defaultSocketPath) {
        self.socketPath = socketPath
    }

    // MARK: - Enumeration

    /// Every **cabled** device attached right now.
    ///
    /// Wi-Fi-paired devices are filtered out here rather than by the caller;
    /// see ``USBDevice/ConnectionType`` for why using one would be a silent
    /// failure rather than a loud one.
    public func listDevices() async throws -> [USBDevice] {
        let socket = try RawSocket.connectUnix(path: socketPath)
        defer { socket.close() }

        var reader = ReplyReader()
        try await send(.listDevices, on: socket, tag: 1)
        while let reply = try await reader.next(from: socket) {
            if case let .deviceList(devices) = reply {
                return devices.filter { $0.connectionType.isCable }
            }
        }
        throw USBMuxError.disconnected
    }

    /// A live stream of attach and detach events for **cabled** devices.
    ///
    /// The returned stream owns its own socket; cancelling the consuming task
    /// (or letting the stream go out of scope) closes it.
    public func listen() -> AsyncThrowingStream<USBDeviceEvent, Error> {
        AsyncThrowingStream { continuation in
            // One box, one termination handler. Assigning `onTermination`
            // twice would silently discard the first, leaking the socket.
            let held = SocketBox()
            let task = Task {
                do {
                    let socket = try RawSocket.connectUnix(path: socketPath)
                    held.set(socket)

                    var reader = ReplyReader()
                    try await send(.listen, on: socket, tag: 1)

                    // usbmuxd answers Listen with a Result, then replays the
                    // devices already attached as Attached events before going
                    // live. So a device plugged in before we started still
                    // arrives — no separate initial ListDevices needed.
                    while let reply = try await reader.next(from: socket) {
                        switch reply {
                        case let .result(code):
                            guard code == .ok else {
                                continuation.finish(throwing: USBMuxError.refused(code))
                                return
                            }
                        case let .attached(device):
                            guard device.connectionType.isCable else {
                                log.notice("ignoring \(device.udid, privacy: .public) — usbmuxd reports it over the network, not the cable")
                                continue
                            }
                            continuation.yield(.attached(device))
                        case let .detached(deviceID):
                            // Detached carries no Properties, so it cannot be
                            // filtered by connection type. Emitting it for a
                            // device we never announced is harmless: the
                            // consumer keys off its own attached set.
                            continuation.yield(.detached(deviceID: deviceID))
                        case let .unknownResult(number):
                            continuation.finish(throwing: USBMuxError.malformed(
                                "usbmuxd refused Listen with result \(number)"
                            ))
                            return
                        case .deviceList, .unrecognised:
                            continue
                        }
                    }
                    continuation.finish(throwing: USBMuxError.disconnected)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                held.close()
            }
        }
    }

    /// Lets the stream's termination handler reach a socket that is opened
    /// later, inside the task.
    private final class SocketBox: @unchecked Sendable {
        private let lock = NSLock()
        private var socket: RawSocket?
        private var closedEarly = false

        func set(_ socket: RawSocket) {
            lock.lock()
            let alreadyDone = closedEarly
            self.socket = socket
            lock.unlock()
            // The stream can be torn down before the socket finishes opening.
            if alreadyDone { socket.close() }
        }

        func close() {
            lock.lock()
            let socket = self.socket
            closedEarly = true
            lock.unlock()
            socket?.close()
        }
    }

    // MARK: - Connect

    /// Opens a TCP connection to `port` on the attached device.
    ///
    /// A `.connectionRefused` result is the ordinary "UpLink is not running on
    /// the phone" case, not a broken cable — see
    /// ``USBMuxCodec/ResultCode/explanation``.
    public func connect(to deviceID: UInt32, port: UInt16) async throws -> USBMuxChannel {
        let socket = try RawSocket.connectUnix(path: socketPath)
        var reader = ReplyReader()
        do {
            try await send(.connect(deviceID: deviceID, port: port), on: socket, tag: 1)
            guard let reply = try await reader.next(from: socket) else {
                throw USBMuxError.disconnected
            }
            if case let .unknownResult(number) = reply {
                throw USBMuxError.malformed("usbmuxd refused Connect with result \(number)")
            }
            guard case let .result(code) = reply else {
                throw USBMuxError.malformed("expected a Result for Connect, got \(reply)")
            }
            guard code == .ok else { throw USBMuxError.refused(code) }
        } catch {
            socket.close()
            throw error
        }
        // Anything already buffered past the Result is session data.
        return USBMuxChannel(socket: socket, carryOver: reader.residue)
    }

    private func send(_ request: USBMuxCodec.Request, on socket: RawSocket, tag: UInt32) async throws {
        try await socket.write(try USBMuxCodec.encode(request, tag: tag))
    }

    /// Accumulates bytes until a whole message is present, then hands it over.
    private struct ReplyReader {
        /// Bytes read but not yet consumed by a decoded message. After the
        /// final control message this is the start of the data stream.
        private(set) var residue = Data()

        mutating func next(from socket: RawSocket) async throws -> USBMuxCodec.Reply? {
            while true {
                if let (reply, consumed) = try USBMuxCodec.decode(residue) {
                    residue.removeSubrange(residue.startIndex ..< residue.startIndex + consumed)
                    return reply
                }
                guard let chunk = try await socket.read() else { return nil }
                residue.append(chunk)
            }
        }
    }
}

/// The ports the phone listens on, and the order the Mac tries them.
public enum UpLinkUSB {

    /// The Network Extension's listener. Preferred, because the extension
    /// keeps running while the phone is locked or the app is backgrounded.
    public static let extensionPort: UInt16 = 50505

    /// The foreground app's listener.
    ///
    /// Insurance against the one assumption this transport rests on: that
    /// `usbmux Connect` can reach a listener inside a Network Extension. It
    /// reaches app-hosted listeners routinely, and an extension is an ordinary
    /// process, but if that turns out not to hold the product still works with
    /// the phone's app in the foreground — degraded, and *visibly* so, rather
    /// than mysteriously dead.
    public static let appPort: UInt16 = 50506

    /// Tried in order. First to answer wins.
    public static let ports: [UInt16] = [extensionPort, appPort]

    /// For diagnostics: which side answered.
    public static func describe(port: UInt16) -> String {
        switch port {
        case extensionPort: "network extension"
        case appPort: "foreground app"
        default: "port \(port)"
        }
    }
}

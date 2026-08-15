import Foundation
@testable import UpLinkKit

/// A stand-in for `usbmuxd`, speaking the real wire protocol over a temporary
/// UNIX socket.
///
/// This exists so the entire USB transport — attach and detach streaming, the
/// Wi-Fi-device filter, `Connect` refusal, and the byte pipe that follows a
/// successful `Connect` — can be exercised with no cable, no phone, and no
/// daemon. Every one of those paths otherwise needs hardware to see even once,
/// and this codebase has already paid for the habit of proving things only on a
/// device: a whole test round was spent on a phone running stale code.
///
/// It is deliberately literal about the protocol rather than sharing the
/// production encoder. A fake that reuses the code under test cannot catch a
/// codec that is self-consistently wrong.
final class FakeUSBMuxDaemon: @unchecked Sendable {

    /// What `Connect` should do.
    enum ConnectBehavior: Sendable {
        /// Accept, then echo every byte back. Lets a test drive `USBMuxChannel`
        /// end to end.
        case echo
        /// Accept, immediately send `payload`, then echo. Used to prove the
        /// carry-over path, where the daemon coalesces its `Result` and the
        /// first session bytes into one segment.
        case greet(Data)
        case refuse(USBMuxCodec.ResultCode)
    }

    let path: String

    private let listenFD: Int32
    private let queue = DispatchQueue(label: "fake.usbmux.accept")
    private let lock = NSLock()
    private var devices: [USBDevice]
    private var behavior: ConnectBehavior
    private var eventClients: [Int32] = []
    private var openFDs: [Int32] = []
    private var stopped = false

    /// Ports the fake will accept a `Connect` for. Anything else is refused,
    /// so a test can prove the Mac falls through from the extension port to the
    /// app port.
    private var acceptedPorts: Set<UInt16>

    init(
        devices: [USBDevice] = [],
        behavior: ConnectBehavior = .echo,
        acceptedPorts: Set<UInt16> = [UpLinkUSB.extensionPort, UpLinkUSB.appPort]
    ) throws {
        self.devices = devices
        self.behavior = behavior
        self.acceptedPorts = acceptedPorts

        // A UNIX socket path must fit in 104 bytes, so the short temp dir
        // rather than the very long per-test sandbox path.
        self.path = "/tmp/uplink-fakemux-\(UInt32.random(in: 0 ..< .max)).sock"
        unlink(path)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw Failure.socket("socket() failed") }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { throw Failure.socket("bind() failed: \(String(cString: strerror(errno)))") }
        guard listen(listenFD, 8) == 0 else { throw Failure.socket("listen() failed") }

        queue.async { [weak self] in self?.acceptLoop() }
    }

    enum Failure: Error { case socket(String) }

    // MARK: - Driving the fake from a test

    /// Waits until a client has sent `Listen` and been registered.
    ///
    /// Tests used to sleep a fixed 250ms here, which is a race dressed up as a
    /// pause: under a loaded parallel run the connect and `Listen` round trip
    /// can take longer, the pushed event goes to nobody, and the test fails
    /// somewhere unrelated. Waiting on the actual condition removes the guess.
    func awaitListener(within seconds: Double = 5) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if hasListener { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure.socket("no client sent Listen within \(seconds)s")
    }

    /// Synchronous, because `NSLock` cannot be taken from an async context —
    /// the compiler rejects it outright, since a suspension while holding it
    /// would block a cooperative thread.
    private var hasListener: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !eventClients.isEmpty
    }

    /// Pushes an attach event to every client that sent `Listen`.
    func attach(_ device: USBDevice) {
        lock.lock()
        devices.append(device)
        let clients = eventClients
        lock.unlock()
        let message = Self.frame(["MessageType": "Attached"].merging(Self.body(of: device)) { a, _ in a })
        for client in clients { Self.writeAll(client, message) }
    }

    func detach(deviceID: UInt32) {
        lock.lock()
        devices.removeAll { $0.deviceID == deviceID }
        let clients = eventClients
        lock.unlock()
        let message = Self.frame(["MessageType": "Detached", "DeviceID": Int(deviceID)])
        for client in clients { Self.writeAll(client, message) }
    }

    /// Idempotent.
    ///
    /// Only ever `shutdown`s: the serving threads own their descriptors and
    /// close them when their blocking read returns. Closing a descriptor that
    /// another thread is inside a syscall on frees the number for immediate
    /// reuse, so the blocked read resumes against whatever socket got it next —
    /// which took the whole parallel test process down rather than failing one
    /// case. The production socket has the same rule; see `RawSocket.inFlight`.
    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let toWake = openFDs + eventClients
        eventClients.removeAll()
        lock.unlock()

        for fd in toWake { shutdown(fd, SHUT_RDWR) }
        shutdown(listenFD, SHUT_RDWR)
        unlink(path)
    }

    deinit { stop() }

    // MARK: - Server

    private func acceptLoop() {
        // This thread owns `listenFD` and is the only thing that closes it.
        defer { close(listenFD) }
        while true {
            let client = accept(listenFD, nil, nil)
            lock.lock()
            let isStopped = stopped
            if !isStopped && client >= 0 { openFDs.append(client) }
            lock.unlock()
            if isStopped { if client >= 0 { close(client) }; return }
            guard client >= 0 else { return }
            DispatchQueue(label: "fake.usbmux.client").async { [weak self] in
                self?.serve(client)
            }
        }
    }

    private func serve(_ fd: Int32) {
        guard let request = readOneMessage(fd) else { finish(fd); return }
        let messageType = request["MessageType"] as? String

        switch messageType {
        case "ListDevices":
            lock.lock()
            let snapshot = devices
            lock.unlock()
            Self.writeAll(fd, Self.frame(["DeviceList": snapshot.map(Self.entry(for:))]))
            finish(fd)

        case "Listen":
            Self.writeAll(fd, Self.frame(["MessageType": "Result", "Number": 0]))
            lock.lock()
            let snapshot = devices
            eventClients.append(fd)
            lock.unlock()
            // Real usbmuxd replays what is already attached before going live.
            for device in snapshot {
                Self.writeAll(fd, Self.frame(
                    ["MessageType": "Attached"].merging(Self.body(of: device)) { a, _ in a }
                ))
            }
            // Block until the client goes away, so this descriptor has exactly
            // one owner and one closer, like every other one here. A Listen
            // client never sends again, so this read only returns at EOF or
            // when `stop()` shuts the socket down.
            var sink = [UInt8](repeating: 0, count: 64)
            while read(fd, &sink, 64) > 0 {}
            finish(fd)

        case "Connect":
            let wire = request["PortNumber"] as? Int ?? 0
            let port = USBMuxCodec.hostPort(wire)
            lock.lock()
            let behavior = self.behavior
            let accepted = acceptedPorts.contains(port)
            lock.unlock()

            if case let .refuse(code) = behavior {
                Self.writeAll(fd, Self.frame(["MessageType": "Result", "Number": code.rawValue]))
                finish(fd)
                return
            }
            guard accepted else {
                Self.writeAll(fd, Self.frame([
                    "MessageType": "Result",
                    "Number": USBMuxCodec.ResultCode.connectionRefused.rawValue,
                ]))
                finish(fd)
                return
            }

            var opening = Self.frame(["MessageType": "Result", "Number": 0])
            if case let .greet(payload) = behavior {
                // Deliberately appended to the SAME write, so the Result and
                // the first session bytes land in one segment. That is the
                // coalescing `USBMuxChannel.carryOver` exists to survive, and
                // splitting it here would make the test pass for the wrong
                // reason.
                opening.append(payload)
            }
            Self.writeAll(fd, opening)
            echoLoop(fd)

        default:
            finish(fd)
        }
    }

    /// Closes a client descriptor and forgets it, in that order and exactly
    /// once. Leaving a closed number in `openFDs` is what let `stop()` shut
    /// down an unrelated socket that had since been given the same number.
    private func finish(_ fd: Int32) {
        lock.lock()
        let known = openFDs.contains(fd) || eventClients.contains(fd)
        openFDs.removeAll { $0 == fd }
        eventClients.removeAll { $0 == fd }
        lock.unlock()
        if known { close(fd) }
    }

    private func echoLoop(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, 64 * 1024) }
            guard count > 0 else { finish(fd); return }
            Self.writeAll(fd, Data(buffer[0 ..< count]))
        }
    }

    private func readOneMessage(_ fd: Int32) -> [String: Any]? {
        var accumulated = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            if let header = USBMuxCodec.decodeHeader(accumulated),
               let bodyLength = header.bodyLength,
               accumulated.count >= USBMuxCodec.headerSize + bodyLength {
                let body = accumulated.subdata(
                    in: USBMuxCodec.headerSize ..< USBMuxCodec.headerSize + bodyLength
                )
                return try? PropertyListSerialization.propertyList(
                    from: body, options: [], format: nil
                ) as? [String: Any]
            }
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, 4096) }
            guard count > 0 else { return nil }
            accumulated.append(contentsOf: buffer[0 ..< count])
        }
    }

    // MARK: - Encoding (independent of the production encoder, on purpose)

    private static func body(of device: USBDevice) -> [String: Any] {
        [
            "DeviceID": Int(device.deviceID),
            "Properties": [
                "SerialNumber": device.udid,
                "ConnectionType": {
                    switch device.connectionType {
                    case .usb: "USB"
                    case .network: "Network"
                    case let .other(raw): raw
                    }
                }() as String,
            ] as [String: Any],
        ]
    }

    private static func entry(for device: USBDevice) -> [String: Any] {
        ["MessageType": "Attached"].merging(body(of: device)) { a, _ in a }
    }

    private static func frame(_ plist: [String: Any]) -> Data {
        let body = try! PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        var data = Data()
        for word: UInt32 in [UInt32(16 + body.count), 1, 8, 1] {
            withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) }
        }
        return data + body
    }

    private static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let written = write(fd, base.advanced(by: sent), data.count - sent)
                if written <= 0 { return }
                sent += written
            }
        }
    }
}

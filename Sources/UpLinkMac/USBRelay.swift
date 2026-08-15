import Foundation
import Network
import OSLog
import UpLinkKit

/// What the relay currently sees on the cable.
enum USBRelayState: Sendable, Equatable {
    /// No cabled iPhone attached.
    case noDevice
    /// Attached, but nothing answered on either UpLink port — the phone's app
    /// is not running, or the bridge is switched off over there.
    case attachedNotAnswering(udid: String)
    /// Attached and answering. `port` is the loopback port the extension should
    /// dial; `answeringPort` records which side of the phone picked up.
    case ready(udid: String, port: UInt16, answeringPort: UInt16)
    case failed(String)
}

/// Pumps the USB cable onto a loopback port the proxy extension can reach.
///
/// **Why this lives in the app.** The proxy extension is sandboxed
/// (`com.apple.security.app-sandbox` in its entitlements) and the sandbox does
/// not permit opening `/var/run/usbmuxd`. The menu-bar app is deliberately
/// unsandboxed — it has to be, to install a system extension at all — so it is
/// the only process that can speak to `usbmuxd`.
///
/// **It cannot read the traffic.** TLS-PSK runs end to end between the phone
/// and the extension; everything crossing this relay is ciphertext for a key
/// this process never sees. The relay is `read`/`write` and nothing else.
///
/// The cost of the arrangement is honest and is surfaced in the UI: quitting
/// the app drops the bridge.
@MainActor
final class USBRelay {

    private let log = Logger(subsystem: UpLinkIdentifiers.logSubsystem, category: "usb")
    private let client = USBMuxClient()

    private(set) var state: USBRelayState = .noDevice {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    /// Called whenever the cable's state changes, so the menu bar can say
    /// something true about it.
    var onStateChange: ((USBRelayState) -> Void)?

    private var watchTask: Task<Void, Never>?
    private var listener: NWListener?

    /// Live relay connections, by identity, so teardown can CLOSE them.
    ///
    /// This used to be an array of `Task`s pruned with `isCancelled` — which
    /// tests cancellation, not completion, so a pump that ended normally (the
    /// usual case) stayed in the array for the life of the app. Cancelling was
    /// no use either: both copy loops block in `receive()`, which suspends on a
    /// continuation only a network callback resumes, so cancellation is
    /// invisible and the sockets stayed open. Closing the channels is the only
    /// thing that ends a pump.
    private var pumps: [UUID: (local: FrameChannel, remote: FrameChannel)] = [:]
    private var device: USBDevice?
    private var answeringPort: UInt16?

    func start() {
        guard watchTask == nil else { return }
        watchTask = Task { [weak self] in await self?.watch() }
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
        // Cleared so an `attached` still suspended mid-probe fails its
        // `isStillCurrent` check and cannot publish `.ready` after teardown.
        device = nil
        answeringPort = nil
        teardown()
        state = .noDevice
    }

    // MARK: - Device watch

    private func watch() async {
        // The stream replays devices already attached before it goes live, so a
        // phone plugged in before the app launched still arrives.
        do {
            for try await event in client.listen() {
                guard !Task.isCancelled else { return }
                switch event {
                case let .attached(device):
                    await attached(device)
                case let .detached(deviceID):
                    detached(deviceID)
                }
            }
            // The daemon is not supposed to end this stream. If it does, the
            // only honest state is "we no longer know", and retrying is right —
            // usbmuxd restarts across OS updates.
            log.error("usbmux event stream ended — restarting in 2s")
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { watchTask = Task { [weak self] in await self?.watch() } }
        } catch {
            log.error("usbmux listen failed: \(String(describing: error), privacy: .public)")
            state = .failed(Self.explain(error))
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { watchTask = Task { [weak self] in await self?.watch() } }
        }
    }

    private func attached(_ device: USBDevice) async {
        // `USBMuxClient` already discards devices usbmuxd reaches over the
        // network rather than the cable, so anything arriving here is wired.
        log.error("usb: attached \(device.udid, privacy: .public)")
        self.device = device

        // NO PAIRING CHECK HERE, deliberately.
        //
        // The relay is a dumb pipe and must come up for any cabled device,
        // because PAIRING ITSELF RUNS OVER IT: the Mac dials the phone with the
        // code, so refusing to relay until a pairing exists would make a first
        // pairing impossible. Whether to actually bridge is decided one layer
        // up by the TLS-PSK handshake, which refuses a peer this Mac holds no
        // key for — and that is a decision the relay could not make correctly
        // anyway, since it cannot read the traffic.
        //
        // Find which port the phone is listening on before claiming to be
        // ready. Doing it now rather than on first use means the UI can
        // distinguish "not plugged in" from "plugged in, app not running",
        // which are the two states with completely different remedies.
        guard let answering = await probePorts(of: device) else {
            guard isStillCurrent(device) else { return }
            teardown()
            state = .attachedNotAnswering(udid: device.udid)
            return
        }
        guard isStillCurrent(device) else { return }
        answeringPort = answering

        do {
            let port = try await startListener()
            // Re-checked after every suspension. `startListener` now awaits the
            // bind (it used to block the main thread), and `stop()` can land in
            // that window during quit — leaving this to resume afterwards and
            // publish `.ready`, re-announcing a relay port on the way out.
            guard isStillCurrent(device) else { return }
            state = .ready(udid: device.udid, port: port, answeringPort: answering)
            log.error("usb: relaying 127.0.0.1:\(port, privacy: .public) → \(UpLinkUSB.describe(port: answering), privacy: .public)")
        } catch {
            log.error("usb: could not open the relay listener: \(String(describing: error), privacy: .public)")
            // Checked here too: a throw during quit would otherwise publish
            // `.failed` after teardown had already settled on `.noDevice`.
            guard isStillCurrent(device) else { return }
            state = .failed("could not open a local relay port: \(error)")
        }
    }

    /// Whether this attach is still the one we care about.
    ///
    /// `attached` suspends twice — probing the ports and awaiting the bind — so
    /// the device can be unplugged, or the relay stopped, underneath it.
    private func isStillCurrent(_ device: USBDevice) -> Bool {
        guard !Task.isCancelled, self.device?.deviceID == device.deviceID else { return false }
        return true
    }

    private func detached(_ deviceID: UInt32) {
        guard device?.deviceID == deviceID else { return }
        log.error("usb: detached \(self.device?.udid ?? "?", privacy: .public)")
        device = nil
        answeringPort = nil
        teardown()
        state = .noDevice
    }

    /// Tries the extension's port, then the app's.
    ///
    /// The extension is preferred because it keeps running while the phone is
    /// locked. Falling through to the app's port is the insurance against the
    /// one assumption this transport rests on — that `usbmux Connect` can reach
    /// a listener inside a Network Extension at all.
    private func probePorts(of device: USBDevice) async -> UInt16? {
        for port in UpLinkUSB.ports {
            do {
                let probe = try await client.connect(to: device.deviceID, port: port)
                await probe.close()
                return port
            } catch USBMuxError.refused(.connectionRefused) {
                continue    // nothing listening there; try the next
            } catch {
                log.error("usb: probing port \(port, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                continue
            }
        }
        log.error("usb: \(device.udid, privacy: .public) answered on neither port — is UpLink running on the phone?")
        return nil
    }

    // MARK: - Loopback listener

    private func startListener() async throws -> UInt16 {
        listener?.cancel()

        let parameters = NWParameters.tcp
        // Nothing off this machine may reach the relay. It carries ciphertext,
        // but a port that forwards straight into the phone is not something to
        // leave listening on a network interface.
        //
        // Both lines, for the reason recorded in `TransportParameters.listener`:
        // removing `acceptLocalOnly` as apparently-redundant stopped the
        // equivalent listener accepting connections at all.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener

        // Bind is asynchronous; the extension cannot be told a port of 0.
        //
        // `await`, not `Thread.sleep`. This type is `@MainActor`, so a blocking
        // sleep froze the UI for up to three seconds — on the attach path, so
        // every replug and every reconnect.
        for _ in 0 ..< 300 {
            if let port = listener.port, port.rawValue != 0 { return port.rawValue }
            try? await Task.sleep(for: .milliseconds(10))
        }
        throw USBMuxError.unavailable("relay listener did not bind within 3s")
    }

    private func accept(_ connection: NWConnection) {
        guard let device, let answering = answeringPort else {
            connection.cancel()
            return
        }
        Task { [weak self] in
            await self?.pump(connection, to: device, port: answering)
        }
    }

    /// One accepted loopback connection ↔ one fresh `usbmux Connect`.
    private func pump(_ connection: NWConnection, to device: USBDevice, port: UInt16) async {
        let local = NWConnectionChannel(connection: connection)
        do {
            try await local.start(on: .global(qos: .userInitiated))
        } catch {
            log.error("usb: local relay connection failed: \(String(describing: error), privacy: .public)")
            await local.close()
            return
        }

        let remote: USBMuxChannel
        do {
            remote = try await client.connect(to: device.deviceID, port: port)
        } catch {
            log.error("usb: could not reach the phone: \(String(describing: error), privacy: .public)")
            await local.close()
            // The phone stopped answering. Say so rather than leaving the UI
            // claiming a healthy cable.
            state = .attachedNotAnswering(udid: device.udid)
            return
        }

        let token = UUID()
        pumps[token] = (local, remote)
        defer { pumps.removeValue(forKey: token) }

        // Both directions run concurrently and either one ending tears the pair
        // down — a half-closed relay is how a session hangs instead of failing.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await Self.copy(from: local, to: remote) }
            group.addTask { await Self.copy(from: remote, to: local) }
            await group.next()
            await local.close()
            await remote.close()
            await group.waitForAll()
        }
    }

    private static func copy(from source: FrameChannel, to destination: FrameChannel) async {
        while let bytes = try? await source.receive(), !bytes.isEmpty {
            do { try await destination.send(bytes) } catch { return }
        }
    }

    private func teardown() {
        listener?.cancel()
        listener = nil
        // CLOSED, not cancelled. The copy loops cannot observe cancellation;
        // closing the channels is what unblocks their reads and ends them.
        let open = pumps.values
        pumps.removeAll()
        Task {
            for pair in open {
                await pair.local.close()
                await pair.remote.close()
            }
        }
    }

    private static func explain(_ error: Error) -> String {
        if case let USBMuxError.unavailable(reason) = error {
            return "cannot reach usbmuxd — \(reason)"
        }
        if case let USBMuxError.refused(code) = error {
            return code.explanation
        }
        return String(describing: error)
    }
}

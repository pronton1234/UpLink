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
    case attachedNotAnswering
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
    /// Re-derives the truth on a timer. See ``start()``.
    private var supervisor: Task<Void, Never>?
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
        guard supervisor == nil else { return }
        // LEVEL-TRIGGERED, not edge-triggered. This is the whole design.
        //
        // Every failure this relay has had was a missed edge: an attach event
        // that arrived before the extension had a client, a probe that ran a
        // second too early, a device that re-enumerated while a retry loop held
        // the old id, a re-probe loop that cancelled itself. Each was fixed by
        // adding another edge to react to, and the next gap was always the case
        // that list left out.
        //
        // So the supervisor does not react to anything. Every tick it asks what
        // is TRUE right now — which cabled device does usbmuxd report, is a port
        // answering, do we have a listener for it — and makes reality match.
        // A missed event costs at most one tick; it cannot strand anything,
        // because nothing is remembered that is not re-derived.
        supervisor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.reconcile()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        // The event stream is now only a latency optimisation: it wakes the
        // supervisor early so a plug is noticed instantly rather than within a
        // tick. If it dies, the supervisor carries on — which is the difference
        // between a stream that must not fail and one that merely helps.
        watchTask = Task { [weak self] in await self?.watch() }
    }

    func stop() {
        supervisor?.cancel()
        supervisor = nil
        watchTask?.cancel()
        watchTask = nil
        device = nil
        answeringPort = nil
        teardown()
        state = .noDevice
    }

    // MARK: - The supervisor

    /// Makes the relay match what is actually attached and answering.
    ///
    /// Idempotent and safe to run at any time: it is the only thing that
    /// changes `state`, so there is no ordering to get wrong between it and an
    /// event handler.
    /// True while a reconcile is in flight.
    ///
    /// `reconcile` has `await` points — enumerating, probing, binding — and TWO
    /// callers: the supervisor's timer and the event stream. Without this they
    /// interleave, both conclude "no relay for this device", and both open a
    /// listener. Observed: two announcements in the same millisecond, on ports
    /// 54646 and 54647, with the first orphaned the moment the second replaced
    /// it — so the extension was told about a port whose listener had already
    /// been dropped.
    ///
    /// Skipping rather than queueing is deliberate: the next tick is two
    /// seconds away and re-derives everything, so a dropped overlap costs
    /// nothing, while a queue of stale reconciles would each act on facts that
    /// were true when they were scheduled.
    private var isReconciling = false

    private func reconcile() async {
        // Checked and set with no await between, so it is a real mutex.
        guard !isReconciling else { return }
        isReconciling = true
        defer { isReconciling = false }

        // The DECISION lives in `RelayReconciler`, in the kit, so every
        // transition below is provable without a cable. This function only
        // gathers the facts and carries the decision out.
        let attached: [USBDevice]?
        do {
            attached = try await client.listDevices()
        } catch {
            log.error("usb: could not enumerate devices: \(String(describing: error), privacy: .public)")
            attached = nil      // "I could not ask", NOT "nothing is attached"
        }

        // Probing costs a usbmux round trip, so only do it when the answer can
        // change the outcome.
        var answering: UInt16?
        if let device = attached?.first {
            if case let .ready(udid, _, port) = state, udid == device.udid, listener != nil {
                answering = port            // already known good
            } else {
                answering = await probePorts(of: device)
            }
        }

        let holding = RelayHolding(
            udid: { if case let .ready(udid, _, _) = state { return udid } else { return nil } }(),
            listenerPort: listener?.port?.rawValue
        )

        switch RelayReconciler.next(attached: attached, holding: holding, answeringPort: answering) {
        case .hold:
            return

        case .standDown:
            guard state != .noDevice else { return }
            log.error("usb: no cabled device")
            device = nil
            answeringPort = nil
            teardown()
            state = .noDevice

        case let .waitForPhone(udid):
            guard state != .attachedNotAnswering else { return }
            log.error("usb: \(udid, privacy: .public) attached but answering on neither port")
            teardown()
            state = .attachedNotAnswering

        case let .openRelay(found, port):
            device = found
            answeringPort = port
            do {
                let local = try await startListener()
                state = .ready(udid: found.udid, port: local, answeringPort: port)
                log.error("usb: relaying 127.0.0.1:\(local, privacy: .public) → \(UpLinkUSB.describe(port: port), privacy: .public)")
            } catch {
                log.error("usb: could not open the relay listener: \(String(describing: error), privacy: .public)")
                state = .failed("could not open a local relay port: \(error)")
            }
        }
    }

    // MARK: - Device events (latency only)

    private func watch() async {
        do {
            for try await _ in client.listen() {
                guard !Task.isCancelled else { return }
                // Deliberately ignores WHICH event it was. The supervisor is
                // the only thing that decides anything; this just makes it
                // decide sooner.
                await reconcile()
            }
        } catch {
            log.error("usbmux listen failed: \(String(describing: error), privacy: .public)")
        }
        // No self-restart chain here either. If the stream ends, the supervisor
        // keeps reconciling on its timer, and the next `start()` re-arms this.
        guard !Task.isCancelled else { return }
        try? await Task.sleep(for: .seconds(2))
        if !Task.isCancelled { watchTask = Task { [weak self] in await self?.watch() } }
    }

    /// Tries the extension's port, then the app's.
    ///
    /// The extension is preferred because it keeps running while the phone is
    /// locked. The app port is the fallback, and which one answered is reported
    /// so a degraded setup is visible rather than merely working badly.
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
            state = .attachedNotAnswering
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

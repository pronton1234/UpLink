import Foundation
import Network
import OSLog
import UpLinkKit

/// Wires the pure ``WifiWatchdog`` decision logic to real `NWPathMonitor`
/// events and a real timer.
///
/// The policy — including the exclusion of the link being bridged over — lives
/// in `WifiWatchdog` and is unit-tested there. This type only translates
/// between Network framework and that state machine, and owns the timer.
///
/// Per the spec, monitoring is entirely idle while the bridge is off: the
/// monitor is not even started, so there is zero background evaluation.
@MainActor
final class WatchdogController {

    private let log = Logger(subsystem: UpLinkIdentifiers.logSubsystem, category: "watchdog")
    private let model: MenuBarModel
    private let onNotify: () -> Void

    private var watchdog = WifiWatchdog()
    private var monitor: NWPathMonitor?
    private var timer: DispatchSourceTimer?
    private var wasConnected = false

    init(model: MenuBarModel, onNotify: @escaping () -> Void) {
        self.model = model
        self.onNotify = onNotify

        model.observe { [weak self] in
            Task { @MainActor in self?.bridgeStateChanged() }
        }
    }

    private func bridgeStateChanged() {
        let connected = model.status.isConnected
        guard connected != wasConnected else { return }
        wasConnected = connected

        watchdog.bridgeInterfaceName = model.bridgeInterfaceName
        apply(watchdog.setBridgeActive(connected))

        if connected { startMonitoring() } else { stopMonitoring() }
    }

    private func startMonitoring() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)

        monitor.pathUpdateHandler = { [weak self] path in
            // Validations are routed onto the main queue before touching the
            // state machine or the timer, so the long-running countdown is only
            // ever mutated from one thread.
            Task { @MainActor in self?.handle(path) }
        }
        monitor.start(queue: .global(qos: .utility))
        self.monitor = monitor
        log.info("watchdog monitoring started")
    }

    private func stopMonitoring() {
        monitor?.cancel()
        monitor = nil
        cancelTimer()
        log.info("watchdog monitoring stopped")
    }

    private func handle(_ path: NWPath) {
        let observation = WatchdogPath(
            hasSatisfiedWifi: path.status == .satisfied,
            wifiInterfaceName: path.availableInterfaces.first(where: { $0.type == .wifi })?.name,
            isConstrained: path.isConstrained || path.isExpensive
        )
        apply(watchdog.handle(observation))
    }

    private func apply(_ action: WatchdogAction) {
        switch action {
        case .startTimer: startTimer()
        case .cancelTimer: cancelTimer()
        case .none: break
        }
    }

    private func startTimer() {
        cancelTimer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // Non-repeating, per the spec: one suggestion per qualifying stretch.
        timer.schedule(deadline: .now() + WifiWatchdog.debounce)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.watchdog.timerFired() {
                self.log.info("watchdog fired")
                self.onNotify()
            }
            self.cancelTimer()
        }
        timer.resume()
        self.timer = timer
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }
}

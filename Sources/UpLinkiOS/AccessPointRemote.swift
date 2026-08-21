import Foundation
import CoreBluetooth
import UpLinkKit
import OSLog

/// Starts the Mac's access point from the phone, over Bluetooth.
///
/// **Why this cannot be done over Wi-Fi.** The phone reaches the Mac over the
/// network the Mac hosts, so asking the Mac to start hosting has to travel some
/// other way. Bluetooth LE is a separate radio that needs no association and is
/// listening while the access point is down, which is exactly the window this
/// has to work in.
///
/// **It sends one byte.** No data ever travels here — see ``RemoteCommand``,
/// which refuses anything that is not exactly one known command. The bridge
/// itself runs over 5 GHz Wi-Fi, a different radio in a different band, so this
/// cannot slow it down even while it is talking.
final class AccessPointRemote: NSObject, @unchecked Sendable {

    private let log = Logger(subsystem: UpLinkIdentifiers.logSubsystem, category: "remote")
    private let queue = DispatchQueue(label: "com.uplink.app.ble.central")

    private var central: CBCentralManager?
    private var mac: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?

    /// Resumed once the command has been written, or when we give up.
    private var waiter: CheckedContinuation<Bool, Never>?
    private var pending: RemoteCommand?
    private var timeout: DispatchWorkItem?

    /// Asks the Mac to raise its access point.
    ///
    /// Returns whether the command was delivered — not whether the network is
    /// up, which takes a few more seconds and is better learned by looking for
    /// it. Never throws: a Mac that cannot be reached over Bluetooth is a
    /// reason to try the network anyway, since it may already be hosting.
    func send(_ command: RemoteCommand, timeoutSeconds: TimeInterval = 8) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard waiter == nil else {
                    // One at a time. A queued second command would arrive after
                    // the first had already changed the answer.
                    continuation.resume(returning: false)
                    return
                }
                waiter = continuation
                pending = command

                let work = DispatchWorkItem { [self] in
                    log.error("remote: no Mac answered within \(Int(timeoutSeconds), privacy: .public)s")
                    finish(false)
                }
                timeout = work
                queue.asyncAfter(deadline: .now() + timeoutSeconds, execute: work)

                if central == nil {
                    central = CBCentralManager(delegate: self, queue: queue)
                } else if central?.state == .poweredOn {
                    beginScan()
                }
            }
        }
    }

    // MARK: On the Bluetooth queue

    private func beginScan() {
        log.error("remote: scanning for the Mac")
        central?.scanForPeripherals(
            withServices: [CBUUID(string: RemoteControlIDs.serviceUUID)], options: nil
        )
    }

    private func finish(_ delivered: Bool) {
        timeout?.cancel()
        timeout = nil
        central?.stopScan()
        if let mac { central?.cancelPeripheralConnection(mac) }
        mac = nil
        commandCharacteristic = nil
        pending = nil
        let continuation = waiter
        waiter = nil
        continuation?.resume(returning: delivered)
    }
}

extension AccessPointRemote: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            log.error("remote: bluetooth unavailable (state \(central.state.rawValue, privacy: .public))")
            if waiter != nil { finish(false) }
            return
        }
        if waiter != nil { beginScan() }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard mac == nil else { return }
        log.error("remote: found a Mac, connecting")
        central.stopScan()
        mac = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([CBUUID(string: RemoteControlIDs.serviceUUID)])
    }

    func centralManager(
        _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
    ) {
        log.error("remote: connect failed — \(error?.localizedDescription ?? "unknown", privacy: .public)")
        finish(false)
    }
}

extension AccessPointRemote: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first else { return finish(false) }
        peripheral.discoverCharacteristics(
            [CBUUID(string: RemoteControlIDs.commandUUID)], for: service
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
    ) {
        guard let characteristic = service.characteristics?.first(
            where: { $0.uuid == CBUUID(string: RemoteControlIDs.commandUUID) }
        ), let command = pending else { return finish(false) }

        commandCharacteristic = characteristic
        // `.withResponse`, so delivery is confirmed rather than hoped for: the
        // whole point is knowing the Mac heard us before we go looking for a
        // network that may not be coming.
        peripheral.writeValue(command.encoded, for: characteristic, type: .withResponse)
    }

    func peripheral(
        _ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?
    ) {
        if let error {
            log.error("remote: write failed — \(error.localizedDescription, privacy: .public)")
            return finish(false)
        }
        log.error("remote: command delivered")
        finish(true)
    }
}

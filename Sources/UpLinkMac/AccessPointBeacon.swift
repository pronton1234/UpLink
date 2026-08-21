import Foundation
import CoreBluetooth
import UpLinkKit
import OSLog

/// Lets the phone bring the access point up while it is down.
///
/// **The one thing Wi-Fi cannot do for us.** The phone's only path to the Mac
/// is the network the Mac hosts, so "start hosting" cannot be asked for over
/// that network — the request needs a channel that works when the access point
/// is off. Bluetooth LE is a separate radio, always listening, needing no
/// association, and it is the only such channel both devices have.
///
/// **It never carries data.** The characteristic accepts a single byte, checked
/// against ``RemoteCommand``, and advertising stops entirely once a session is
/// live. BLE is 2.4 GHz and the access point runs at 5 GHz, so even while
/// advertising the two do not contend for airtime.
///
/// Everything CoreBluetooth touches stays on its own queue; only plain values
/// cross to the main actor, which is what Swift 6 is asking for here and also
/// what keeps the menu off the Bluetooth queue.
final class AccessPointBeacon: NSObject, @unchecked Sendable {

    private let log = Logger(subsystem: UpLinkIdentifiers.logSubsystem, category: "beacon")
    private let queue = DispatchQueue(label: "com.uplink.app.ble")

    private var manager: CBPeripheralManager?
    private var isAdvertising = false

    /// Called on the main actor when the phone asks for something.
    private let onCommand: @Sendable @MainActor (RemoteCommand) -> Void
    /// Answers "is the access point up?" without touching the main actor, since
    /// a BLE read must be replied to promptly.
    private let accessPointIsUp: @Sendable () -> Bool

    init(
        onCommand: @escaping @Sendable @MainActor (RemoteCommand) -> Void,
        accessPointIsUp: @escaping @Sendable () -> Bool
    ) {
        self.onCommand = onCommand
        self.accessPointIsUp = accessPointIsUp
    }

    func start() {
        queue.async { [self] in
            guard manager == nil else { return }
            manager = CBPeripheralManager(delegate: self, queue: queue)
        }
    }

    /// Stops advertising while a bridge is live, and resumes when it ends.
    ///
    /// Nothing needs the doorbell once the door is open, and a radio that is
    /// silent cannot be blamed for anything the link does.
    func setSessionLive(_ live: Bool) {
        queue.async { [self] in
            guard let manager, manager.state == .poweredOn else { return }
            if live { stopAdvertising() } else { beginAdvertising(manager) }
        }
    }

    // MARK: On the Bluetooth queue

    private func beginAdvertising(_ manager: CBPeripheralManager) {
        guard !isAdvertising else { return }
        isAdvertising = true
        manager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: RemoteControlIDs.serviceUUID)],
            CBAdvertisementDataLocalNameKey: "UpLink",
        ])
        log.error("beacon: advertising")
    }

    private func stopAdvertising() {
        guard isAdvertising, let manager else { return }
        isAdvertising = false
        manager.stopAdvertising()
        log.error("beacon: advertising stopped")
    }
}

extension AccessPointBeacon: CBPeripheralManagerDelegate {

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else {
            // Said out loud: Bluetooth being off is a cause the user can fix,
            // and without the doorbell the phone cannot start anything at all.
            log.error("beacon: bluetooth unavailable (state \(peripheral.state.rawValue, privacy: .public))")
            isAdvertising = false
            return
        }

        let command = CBMutableCharacteristic(
            type: CBUUID(string: RemoteControlIDs.commandUUID),
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )
        let state = CBMutableCharacteristic(
            type: CBUUID(string: RemoteControlIDs.stateUUID),
            properties: [.read],
            value: nil,
            permissions: [.readable]
        )
        let service = CBMutableService(
            type: CBUUID(string: RemoteControlIDs.serviceUUID), primary: true
        )
        service.characteristics = [command, state]
        peripheral.removeAllServices()
        peripheral.add(service)
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?
    ) {
        if let error {
            log.error("beacon: service failed — \(error.localizedDescription, privacy: .public)")
            return
        }
        beginAdvertising(peripheral)
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]
    ) {
        for request in requests {
            guard let data = request.value, let command = RemoteCommand.decode(data) else {
                // Refused rather than ignored. A write that is not exactly one
                // known byte is the shape this channel must never accept, and
                // silence would make that indistinguishable from success.
                log.error("beacon: refused a write that was not a command")
                continue
            }
            log.error("beacon: \(String(describing: command), privacy: .public)")
            let handler = onCommand
            Task { @MainActor in handler(command) }
        }
        // Exactly one response per batch, which CoreBluetooth requires.
        if let first = requests.first { peripheral.respond(to: first, withResult: .success) }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest
    ) {
        // Answered from the interfaces, not from a cached flag: the phone uses
        // this to decide whether a raise is needed, and a stale yes means it
        // waits for a network that is not coming.
        request.value = Data([accessPointIsUp() ? 1 : 0])
        peripheral.respond(to: request, withResult: .success)
    }
}

import Foundation
import UpLinkKit

// THE ONE UNVERIFIED ASSUMPTION IN THE WIRED TRANSPORT.
//
// Everything else about `usbmuxd` is exercised by `swift test` against a fake
// daemon: the framing, the byte-swapped port, attach/detach streaming, the
// Wi-Fi-device filter, `Connect` refusal, and the byte pipe that follows.
// None of that needs hardware.
//
// What cannot be faked is whether `usbmux Connect` can reach a listener inside
// an iOS **Network Extension**. It reaches app-hosted listeners routinely —
// that is what `iproxy` does, and how every dev tool talks to a debug server on
// a device — and an extension is an ordinary process with no documented
// restriction here. But it has never been tried in this project, and the
// difference matters: the extension keeps running while the phone is locked,
// and the app does not.
//
// So the product tries the extension's port first and falls back to the app's,
// and this probe reports which one actually answered. Run it with the phone
// plugged in and UpLink running, then record the answer in
// docs/device-test-log.md and delete this directory.
//
//     swift run --package-path spike/usb-probe usb-probe
//
// Add `--watch` to sit on the event stream and watch attach/detach instead.

let client = USBMuxClient()
let watching = CommandLine.arguments.contains("--watch")
let selfTesting = CommandLine.arguments.contains("--selftest")

func describe(_ device: USBDevice) -> String {
    "\(device.udid)  deviceID=\(device.deviceID)  via=\(device.connectionType)"
}

// Verifies the CODEC against Apple's daemon, with no phone attached.
//
// This closes a real gap. The unit tests run against a fake usbmuxd that was
// written from the same reading of the protocol as the client itself — so if
// that reading is wrong, the fake is wrong in the same direction and every test
// passes anyway. Only the real daemon can break that circularity, and it does
// not need a device: `ListDevices` and `Listen` both answer on an empty Mac,
// and a bad header, version, message type or plist body fails them.
if selfTesting {
    print("Self-test against the real usbmuxd at \(USBMuxClient.defaultSocketPath)\n")

    do {
        let devices = try await client.listDevices()
        print("  ListDevices: OK — daemon parsed our request and we parsed its reply")
        print("               (\(devices.count) cabled device(s))")
    } catch {
        print("  ListDevices: FAILED — \(error)")
        print("\nThe codec does not match the real daemon. The unit tests cannot")
        print("catch this: they run against a fake built on the same assumptions.")
        exit(1)
    }

    // `Listen` is a different message and a different reply shape: a Result
    // followed by a live event stream. Bounded here, because it never ends.
    let listened = await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            do {
                for try await _ in client.listen() { return true }
                return true     // stream ended cleanly: Result was accepted
            } catch {
                print("  Listen:      FAILED — \(error)")
                return false
            }
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(2))
            return true         // no error within the window means Result was OK
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
    guard listened else { exit(1) }
    print("  Listen:      OK — subscription accepted, event stream live")

    print("\nCodec verified against Apple's usbmuxd. What remains untestable")
    print("without a device: whether Connect reaches a Network Extension.")
    exit(0)
}

if watching {
    print("Watching for cabled devices. ^C to stop.\n")
    do {
        for try await event in client.listen() {
            switch event {
            case let .attached(device): print("ATTACHED  \(describe(device))")
            case let .detached(deviceID): print("DETACHED  deviceID=\(deviceID)")
            }
        }
    } catch {
        print("stream ended: \(error)")
        exit(1)
    }
    exit(0)
}

let devices: [USBDevice]
do {
    devices = try await client.listDevices()
} catch {
    print("Could not talk to usbmuxd: \(error)")
    print("If /var/run/usbmuxd is missing, usbmuxd is not running — reboot.")
    exit(1)
}

guard let device = devices.first else {
    print("No CABLED iPhone attached.")
    print("Note: devices paired over Wi-Fi are deliberately filtered out — the")
    print("whole premise is that the Mac is not depending on a network.")
    exit(1)
}

print("Device: \(describe(device))\n")

var answered: [UInt16] = []
for port in UpLinkUSB.ports {
    let label = UpLinkUSB.describe(port: port)
    do {
        let channel = try await client.connect(to: device.deviceID, port: port)
        await channel.close()
        print("  port \(port) (\(label)): ANSWERED")
        answered.append(port)
    } catch let USBMuxError.refused(code) {
        print("  port \(port) (\(label)): refused — \(code.explanation)")
    } catch {
        print("  port \(port) (\(label)): \(error)")
    }
}

print("")
if answered.contains(UpLinkUSB.extensionPort) {
    print("RESULT: usbmux CAN reach a listener inside a Network Extension.")
    print("The preferred path works. Record this and delete spike/usb-probe.")
} else if answered.contains(UpLinkUSB.appPort) {
    print("RESULT: only the FOREGROUND APP answered.")
    print("usbmux could not reach the Network Extension's listener, so the")
    print("bridge will drop whenever the phone locks or the app is")
    print("backgrounded. The fallback works, but this is the finding that")
    print("would justify moving the listener — record it before deleting.")
} else {
    print("RESULT: nothing answered on either port.")
    print("Most likely UpLink is simply not running on the phone. Check that")
    print("first — a refused connection does NOT mean the cable or the")
    print("lockdown pairing is broken.")
    exit(1)
}

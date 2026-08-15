import Testing
import Foundation
@testable import UpLinkKit

// Driven against `FakeUSBMuxDaemon`, which speaks the real protocol over a
// temporary UNIX socket. Everything the Mac does to find and reach the phone is
// covered here with no cable attached.

@Suite("usbmux client")
struct USBMuxClientTests {

    @Test("ListDevices returns the attached cabled devices", .timeLimit(.minutes(1)))
    func listsDevices() async throws {
        let daemon = try FakeUSBMuxDaemon(devices: [
            USBDevice(deviceID: 1, udid: "PHONE-A", connectionType: .usb),
            USBDevice(deviceID: 2, udid: "PHONE-B", connectionType: .usb),
        ])
        defer { daemon.stop() }

        let devices = try await USBMuxClient(socketPath: daemon.path).listDevices()
        #expect(devices.map(\.udid).sorted() == ["PHONE-A", "PHONE-B"])
    }

    // The premise of the whole product is that the Mac is not depending on
    // Wi-Fi. usbmuxd also reports devices paired over Wi-Fi, and they differ
    // from cabled ones only by this field — so using one would produce a bridge
    // that looks like it works and dies with the Wi-Fi.
    @Test("A device usbmuxd reaches over the network is never offered", .timeLimit(.minutes(1)))
    func networkDevicesAreFilteredFromListDevices() async throws {
        let daemon = try FakeUSBMuxDaemon(devices: [
            USBDevice(deviceID: 1, udid: "OVER-WIFI", connectionType: .network),
            USBDevice(deviceID: 2, udid: "OVER-CABLE", connectionType: .usb),
        ])
        defer { daemon.stop() }

        let devices = try await USBMuxClient(socketPath: daemon.path).listDevices()
        #expect(devices.map(\.udid) == ["OVER-CABLE"])
    }

    @Test("A device attached before Listen still arrives", .timeLimit(.minutes(1)))
    func replaysAlreadyAttachedDevices() async throws {
        let daemon = try FakeUSBMuxDaemon(devices: [
            USBDevice(deviceID: 1, udid: "ALREADY-THERE", connectionType: .usb),
        ])
        defer { daemon.stop() }

        for try await event in USBMuxClient(socketPath: daemon.path).listen() {
            #expect(event == .attached(
                USBDevice(deviceID: 1, udid: "ALREADY-THERE", connectionType: .usb)
            ))
            return
        }
        Issue.record("the stream ended without replaying the attached device")
    }

    @Test("Listen streams attach and detach as they happen", .timeLimit(.minutes(1)))
    func streamsAttachAndDetach() async throws {
        let daemon = try FakeUSBMuxDaemon()
        defer { daemon.stop() }

        let events = Task {
            var collected: [USBDeviceEvent] = []
            for try await event in USBMuxClient(socketPath: daemon.path).listen() {
                collected.append(event)
                if collected.count == 2 { break }
            }
            return collected
        }

        try await daemon.awaitListener()
        daemon.attach(USBDevice(deviceID: 3, udid: "PLUGGED-IN", connectionType: .usb))
        try await Task.sleep(for: .milliseconds(100))
        daemon.detach(deviceID: 3)

        let collected = try await events.value
        #expect(collected == [
            .attached(USBDevice(deviceID: 3, udid: "PLUGGED-IN", connectionType: .usb)),
            .detached(deviceID: 3),
        ])
    }

    @Test("A Wi-Fi device attaching is not reported as a cable", .timeLimit(.minutes(1)))
    func networkDevicesAreFilteredFromListen() async throws {
        let daemon = try FakeUSBMuxDaemon()
        defer { daemon.stop() }

        let events = Task {
            var collected: [USBDeviceEvent] = []
            for try await event in USBMuxClient(socketPath: daemon.path).listen() {
                collected.append(event)
                if collected.count == 1 { break }
            }
            return collected
        }

        try await daemon.awaitListener()
        daemon.attach(USBDevice(deviceID: 4, udid: "OVER-WIFI", connectionType: .network))
        try await Task.sleep(for: .milliseconds(100))
        daemon.attach(USBDevice(deviceID: 5, udid: "OVER-CABLE", connectionType: .usb))

        let collected = try await events.value
        #expect(collected == [
            .attached(USBDevice(deviceID: 5, udid: "OVER-CABLE", connectionType: .usb)),
        ])
    }

    @Test("Connect opens a byte pipe to the phone", .timeLimit(.minutes(1)))
    func connectYieldsAWorkingChannel() async throws {
        let daemon = try FakeUSBMuxDaemon(behavior: .echo)
        defer { daemon.stop() }

        let channel = try await USBMuxClient(socketPath: daemon.path)
            .connect(to: 1, port: UpLinkUSB.extensionPort)
        try await channel.send(Data("hello over the cable".utf8))

        let echoed = try await channel.receive()
        #expect(echoed == Data("hello over the cable".utf8))
        await channel.close()
    }

    // usbmuxd can coalesce its Result reply and the first bytes from the phone
    // into a single segment. Dropping the remainder loses the first frame of
    // the session, which presents as a handshake that hangs rather than fails.
    @Test("Bytes arriving in the same segment as the Connect result are not lost", .timeLimit(.minutes(1)))
    func carriesOverCoalescedBytes() async throws {
        let greeting = Data("first frame of the session".utf8)
        let daemon = try FakeUSBMuxDaemon(behavior: .greet(greeting))
        defer { daemon.stop() }

        let channel = try await USBMuxClient(socketPath: daemon.path)
            .connect(to: 1, port: UpLinkUSB.extensionPort)

        #expect(try await channel.receive() == greeting)
        await channel.close()
    }

    @Test("A refused Connect surfaces the reason rather than hanging", .timeLimit(.minutes(1)))
    func refusedConnectThrows() async throws {
        let daemon = try FakeUSBMuxDaemon(behavior: .refuse(.connectionRefused))
        defer { daemon.stop() }

        await #expect(throws: USBMuxError.refused(.connectionRefused)) {
            _ = try await USBMuxClient(socketPath: daemon.path)
                .connect(to: 1, port: UpLinkUSB.extensionPort)
        }
    }

    // The extension port is preferred but is the one unproven assumption in the
    // transport; the app port is the fallback. The Mac must actually fall
    // through rather than give up on the first refusal.
    @Test("A refusal on the extension port leaves the app port reachable", .timeLimit(.minutes(1)))
    func fallsThroughToTheAppPort() async throws {
        let daemon = try FakeUSBMuxDaemon(behavior: .echo, acceptedPorts: [UpLinkUSB.appPort])
        defer { daemon.stop() }
        let client = USBMuxClient(socketPath: daemon.path)

        await #expect(throws: USBMuxError.refused(.connectionRefused)) {
            _ = try await client.connect(to: 1, port: UpLinkUSB.extensionPort)
        }

        let channel = try await client.connect(to: 1, port: UpLinkUSB.appPort)
        try await channel.send(Data("via the app".utf8))
        #expect(try await channel.receive() == Data("via the app".utf8))
        await channel.close()
    }

    @Test("A missing daemon socket is reported, not crashed on", .timeLimit(.minutes(1)))
    func missingDaemonIsReported() async throws {
        let client = USBMuxClient(socketPath: "/tmp/uplink-no-such-usbmux-\(UInt32.random(in: 0 ..< .max))")
        await #expect(throws: USBMuxError.self) { _ = try await client.listDevices() }
    }
}

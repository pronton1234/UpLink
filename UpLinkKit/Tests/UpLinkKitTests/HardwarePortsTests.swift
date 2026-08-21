import Testing
@testable import UpLinkKit

@Suite("Finding the Wi-Fi device to host the access point on")
struct HardwarePortsTests {

    // Verbatim from this Mac, 2026-08-20. Ethernet adapters come FIRST, which
    // is the trap: anything that takes the first `Device:` it sees, or that
    // matches loosely on the port name, hosts the access point on the wrong
    // interface — and does so on a Mac whose radio is about to disappear.
    private let real = """
    Hardware Port: Ethernet Adapter (en3)
    Device: en3
    Ethernet Address: 16:7c:c3:c6:3b:89

    Hardware Port: Thunderbolt Bridge
    Device: bridge0
    Ethernet Address: 36:b4:b4:6a:f7:00

    Hardware Port: Wi-Fi
    Device: en0
    Ethernet Address: 74:a6:cd:b7:9e:70

    Hardware Port: Thunderbolt 1
    Device: en1
    Ethernet Address: 36:b4:b4:6a:f7:00
    """

    @Test("This Mac's Wi-Fi device is found, past the adapters listed before it")
    func findsWiFiOnThisMac() {
        #expect(HardwarePorts.wifiDevice(in: real) == "en0")
    }

    @Test("With no Wi-Fi port there is no device, rather than a wrong one")
    func noWiFiPort() {
        let wired = """
        Hardware Port: Thunderbolt Bridge
        Device: bridge0
        Ethernet Address: 36:b4:b4:6a:f7:00
        """
        #expect(HardwarePorts.wifiDevice(in: wired) == nil)
    }

    // A port whose NAME contains a device in parentheses must not have that
    // device harvested — the Device: line is the only authority.
    @Test("A device named in a port's title is not mistaken for the answer")
    func portTitleIsNotTheDevice() {
        let odd = """
        Hardware Port: Ethernet Adapter (en3)
        Device: en9
        Ethernet Address: 16:7c:c3:c6:3b:89

        Hardware Port: Wi-Fi
        Device: en0
        Ethernet Address: 74:a6:cd:b7:9e:70
        """
        #expect(HardwarePorts.wifiDevice(in: odd) == "en0")
    }

    @Test("Wi-Fi last in the list is still found")
    func wifiLast() {
        let last = """
        Hardware Port: Thunderbolt Bridge
        Device: bridge0

        Hardware Port: Wi-Fi
        Device: en2
        """
        #expect(HardwarePorts.wifiDevice(in: last) == "en2")
    }

    @Test("A Wi-Fi block with no device yields nothing, not the next block's")
    func wifiWithoutDevice() {
        let broken = """
        Hardware Port: Wi-Fi

        Hardware Port: Thunderbolt Bridge
        Device: bridge0
        """
        #expect(HardwarePorts.wifiDevice(in: broken) == nil)
    }

    @Test("Empty input is nothing, not a crash")
    func empty() {
        #expect(HardwarePorts.wifiDevice(in: "") == nil)
    }
}

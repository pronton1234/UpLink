import Testing
import Foundation
@testable import UpLinkKit

@Suite("The Internet Sharing configuration this Mac will be given")
struct AccessPointConfigurationTests {

    private var config: AccessPointConfiguration {
        AccessPointConfiguration(
            ssid: "UpLink",
            passphrase: "correct-horse-battery",
            sourceServiceID: "5F2E593C-4D8D-4175-AC49-2A8C56C10587",
            sharingDeviceKey: "en0",
            sourceName: "UpLink Route"
        )
    }

    private func nat(_ config: AccessPointConfiguration) -> [String: Any]? {
        config.natPreferences()["NAT"] as? [String: Any]
    }

    @Test("NAT is enabled, which is the whole point of writing the file")
    func natIsEnabled() {
        #expect(nat(config)?["Enabled"] as? Int == 1)
    }

    @Test("The radio is enabled and carries the SSID we chose")
    func airportCarriesTheSSID() {
        let airport = nat(config)?["AirPort"] as? [String: Any]
        #expect(airport?["Enabled"] as? Int == 1)
        #expect(airport?["NetworkName"] as? String == "UpLink")
    }

    // The source must be the product's dead-end route tunnel. Sharing from a
    // real network would put internet behind the access point, which is the
    // one thing this must never do.
    @Test("The source is whatever service we were told, verbatim")
    func sourceIsTheRouteTunnel() {
        #expect(nat(config)?["PrimaryService"] as? String
            == "5F2E593C-4D8D-4175-AC49-2A8C56C10587")
    }

    @Test("The Wi-Fi device is listed as the sharing device")
    func sharingDeviceIsListed() {
        #expect(nat(config)?["SharingDevices"] as? [String] == ["en0"])
    }

    @Test("The passphrase is carried as data, which is how the key is stored")
    func passphraseIsData() {
        let airport = nat(config)?["AirPort"] as? [String: Any]
        #expect(airport?["NetworkPassword"] as? Data == Data("correct-horse-battery".utf8))
    }

    @Test("The path is the system location, not a per-user one")
    func pathIsSystemWide() {
        #expect(AccessPointConfiguration.preferencesPath
            == "/Library/Preferences/SystemConfiguration/com.apple.nat.plist")
    }

    // It round-trips through a real plist, because the helper writes a file and
    // a dictionary that cannot be serialised would fail only at that point --
    // in a root daemon, on a Mac whose radio has just been taken away.
    @Test("It serialises as a property list")
    func serialises() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: config.natPreferences(), format: .xml, options: 0
        )
        let back = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any]
        let airport = (back?["NAT"] as? [String: Any])?["AirPort"] as? [String: Any]
        #expect(airport?["NetworkName"] as? String == "UpLink")
    }
}

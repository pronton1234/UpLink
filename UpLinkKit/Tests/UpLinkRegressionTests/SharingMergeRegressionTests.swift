import Testing
import Foundation
@testable import UpLinkKit

// SYMPTOM, on hardware 2026-08-20: the access point did not come up, and the
// preference file afterwards looked entirely correct — NAT enabled, AirPort
// enabled, the SSID, SharingDevices [en0], PrimaryService pointing at the
// dead-end route tunnel. configd disagreed:
//
//     [com.apple.NetworkSharing:preference] no external service id
//     [com.apple.NetworkSharing:preference] external interface: (null)
//     [com.apple.NetworkSharing:preference] sharing started on 0 interfaces
//
// The configuration had been built from scratch and had silently dropped
// PrimaryInterface, the sub-dictionary naming the source being shared. Nothing
// present was wrong; the fault was entirely in what was absent — which is why
// reading the written file proved nothing.

@Suite("Regression: sharing configuration merges, never replaces")
struct SharingMergeRegressionTests {

    private var config: AccessPointConfiguration {
        AccessPointConfiguration(
            ssid: "UpLink-c743de63",
            passphrase: "PqXxRUJef4Do8qigDKs7zqVKzVgdagLw",
            sourceServiceID: "5F2E593C-4D8D-4175-AC49-2A8C56C10587",
            sharingDeviceKey: "en0",
            sourceName: "UpLink Route",
            sourceDevice: "utun5"
        )
    }

    /// This Mac's real off-state, captured 2026-08-20.
    private var onDisk: [String: Any] {
        [
            "NAT": [
                "AirPort": [
                    "40BitEncrypt": 1, "Channel": 0, "Enabled": 0,
                    "NetworkName": "Pranit's MacBook Air",
                ] as [String: Any],
                "Enabled": 0,
                "NatPortMapDisabled": false,
                "PrimaryInterface": [
                    "Device": "", "Enabled": 0, "HardwareKey": "",
                    "PrimaryUserReadable": "UpLink Route",
                ] as [String: Any],
                "PrimaryService": "5F2E593C-4D8D-4175-AC49-2A8C56C10587",
                "SharingDevices": [],
            ] as [String: Any],
        ]
    }

    private func nat(_ merged: [String: Any]) -> [String: Any]? {
        merged["NAT"] as? [String: Any]
    }

    @Test("PrimaryInterface survives — the key whose absence caused the failure")
    func primaryInterfaceSurvives() {
        let primary = nat(config.natPreferences(mergedOnto: onDisk))?["PrimaryInterface"] as? [String: Any]
        #expect(primary != nil)
        #expect(primary?["PrimaryUserReadable"] as? String == "UpLink Route")
    }

    @Test("PrimaryInterface is enabled, or the source is named but not used")
    func primaryInterfaceIsEnabled() {
        let primary = nat(config.natPreferences(mergedOnto: onDisk))?["PrimaryInterface"] as? [String: Any]
        #expect(primary?["Enabled"] as? Int == 1)
    }

    // The general rule, not just the one key that bit us. A system preference
    // is not ours to rewrite from first principles: we do not know what every
    // key is for, which is the whole reason this defect was possible.
    @Test("Keys we do not understand are carried through untouched")
    func unknownKeysSurvive() {
        var withStranger = onDisk
        var natDict = withStranger["NAT"] as! [String: Any]
        natDict["SomeKeyAppleAddedLater"] = "keep me"
        withStranger["NAT"] = natDict

        let merged = nat(config.natPreferences(mergedOnto: withStranger))
        #expect(merged?["SomeKeyAppleAddedLater"] as? String == "keep me")
        #expect(merged?["NatPortMapDisabled"] as? Bool == false)
    }

    @Test("Top-level keys outside NAT are left alone")
    func siblingsOfNATSurvive() {
        var withSibling = onDisk
        withSibling["SomeOtherTopLevelKey"] = 42
        let merged = config.natPreferences(mergedOnto: withSibling)
        #expect(merged["SomeOtherTopLevelKey"] as? Int == 42)
    }

    @Test("What we do set, we set — the merge is not a no-op")
    func ourValuesWin() {
        let merged = nat(config.natPreferences(mergedOnto: onDisk))
        #expect(merged?["Enabled"] as? Int == 1)
        #expect((merged?["AirPort"] as? [String: Any])?["NetworkName"] as? String == "UpLink-c743de63")
        #expect(merged?["SharingDevices"] as? [String] == ["en0"])
    }

    @Test("Merging onto nothing still produces a usable configuration")
    func emptyBaseStillWorks() {
        let merged = nat(config.natPreferences())
        #expect(merged?["Enabled"] as? Int == 1)
        #expect(merged?["PrimaryService"] as? String == "5F2E593C-4D8D-4175-AC49-2A8C56C10587")
    }
}

// A Mac whose PrimaryInterface was already destroyed by the very defect above
// has nothing to merge forward. It must still be repairable from the app, or
// the only route back is System Settings — which is the manual step the helper
// exists to remove.
@Suite("Regression: a destroyed PrimaryInterface is rebuilt, not merely enabled")
struct SharingRepairRegressionTests {

    private var config: AccessPointConfiguration {
        AccessPointConfiguration(
            ssid: "UpLink-c743de63",
            passphrase: "PqXxRUJef4Do8qigDKs7zqVKzVgdagLw",
            sourceServiceID: "5F2E593C-4D8D-4175-AC49-2A8C56C10587",
            sharingDeviceKey: "en0",
            sourceName: "UpLink Route",
            sourceDevice: "utun5"
        )
    }

    /// This Mac's real state after the bad write: PrimaryInterface simply gone.
    private var damaged: [String: Any] {
        ["NAT": [
            "AirPort": ["Enabled": 1, "NetworkName": "UpLink-c743de63"] as [String: Any],
            "Enabled": 1,
            "PrimaryService": "5F2E593C-4D8D-4175-AC49-2A8C56C10587",
            "SharingDevices": ["en0"],
        ] as [String: Any]]
    }

    @Test("The source is named again, so configd can resolve it")
    func rebuildsTheName() {
        let nat = config.natPreferences(mergedOnto: damaged)["NAT"] as? [String: Any]
        let primary = nat?["PrimaryInterface"] as? [String: Any]
        #expect(primary?["PrimaryUserReadable"] as? String == "UpLink Route")
        #expect(primary?["Enabled"] as? Int == 1)
    }

    @Test("An existing name is never overwritten by ours")
    func doesNotClobberAName() {
        var withName = damaged
        var nat = withName["NAT"] as! [String: Any]
        nat["PrimaryInterface"] = ["PrimaryUserReadable": "Something The User Chose", "Enabled": 0]
        withName["NAT"] = nat

        let merged = config.natPreferences(mergedOnto: withName)["NAT"] as? [String: Any]
        let primary = merged?["PrimaryInterface"] as? [String: Any]
        #expect(primary?["PrimaryUserReadable"] as? String == "Something The User Chose")
        #expect(primary?["Enabled"] as? Int == 1)
    }
}

// SYMPTOM, on hardware 2026-08-20, and the worst shape of failure available:
// it looked like it was working. Internet Sharing launched, the Wi-Fi radio was
// taken (en0 went inactive), and configd then said:
//
//     AP stopped
//     external interface: (null)
//     sharing started on 0 interfaces
//
// The Mac spent the whole time hunting for networks that no longer existed,
// because its radio was gone and nothing had replaced it.
//
// The source is a VPN service, and a VPN has no static device —
// preferences.plist records `Type: VPN, DeviceName: None`. PrimaryInterface's
// Device therefore cannot be carried forward from stored configuration. It
// exists only at runtime, in State:/Network/Service/<id>/IPv4 → InterfaceName.

@Suite("Regression: the source's live device, or the radio goes nowhere")
struct SharingSourceDeviceRegressionTests {

    private var config: AccessPointConfiguration {
        AccessPointConfiguration(
            ssid: "UpLink-c743de63",
            passphrase: "PqXxRUJef4Do8qigDKs7zqVKzVgdagLw",
            sourceServiceID: "5F2E593C-4D8D-4175-AC49-2A8C56C10587",
            sharingDeviceKey: "en0",
            sourceName: "UpLink Route",
            sourceDevice: "utun5"
        )
    }

    private func primary(_ base: [String: Any]) -> [String: Any]? {
        (config.natPreferences(mergedOnto: base)["NAT"] as? [String: Any])?["PrimaryInterface"] as? [String: Any]
    }

    @Test("The live device is written")
    func deviceIsWritten() {
        #expect(primary([:])?["Device"] as? String == "utun5")
    }

    // The exact state this Mac was left in: a stored Device of "" that reads
    // like a real value and resolves to nothing.
    @Test("A stored empty Device is overwritten, not merged forward")
    func emptyStoredDeviceIsReplaced() {
        let stale: [String: Any] = ["NAT": ["PrimaryInterface": [
            "Device": "", "Enabled": 1, "HardwareKey": "",
            "PrimaryUserReadable": "UpLink Route",
        ] as [String: Any]] as [String: Any]]
        #expect(primary(stale)?["Device"] as? String == "utun5")
    }

    @Test("A stale device from a previous tunnel is replaced too")
    func staleDeviceIsReplaced() {
        let stale: [String: Any] = ["NAT": ["PrimaryInterface": [
            "Device": "utun3", "Enabled": 1,
            "PrimaryUserReadable": "UpLink Route",
        ] as [String: Any]] as [String: Any]]
        #expect(primary(stale)?["Device"] as? String == "utun5")
    }
}

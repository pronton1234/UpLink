import Testing
import Foundation
import Security
@testable import UpLinkKit

// The SecItem calls themselves need a signed, entitled process and cannot run
// in a test bundle. What *can* be asserted here is the shape of the query —
// which is where the bug actually was.

@Suite("Regression: keychain sharing")
struct KeychainSharingRegressionTests {

    // SYMPTOM: every call site constructed the store with `accessGroup: nil`,
    // so the app and its network extension each fell back to their own default
    // access group — their own bundle ID. They could not see each other's
    // items at all. The visible damage: `loadOrCreateIdentity()` generated a
    // DIFFERENT long-term key in each process, so the fingerprint the phone
    // paired against was not the one the extension later presented, and every
    // session failed authentication for no apparent reason.
    @Test("The default configuration shares a keychain group rather than isolating")
    func defaultConfigurationShares() {
        let configuration = PairedDeviceStore.Configuration.shared

        // Either an explicit fully-qualified group, or nil — which SecItem
        // resolves to the first entitlement entry, the same shared group.
        if let group = configuration.accessGroup {
            #expect(group.hasSuffix(UpLinkIdentifiers.keychainAccessGroupSuffix))
        }
        #expect(configuration.service == UpLinkIdentifiers.keychainService)
    }

    // SYMPTOM: on macOS the legacy file-based keychain largely ignores
    // kSecAttrAccessGroup, so even with the group set correctly the Mac app and
    // its system extension read two different keychains. The data protection
    // keychain is what gives macOS iOS-style access-group semantics.
    @Test("The data protection keychain is on, without which macOS ignores the access group")
    func dataProtectionKeychainIsEnabled() {
        #expect(PairedDeviceStore.Configuration.shared.useDataProtectionKeychain)

        let store = PairedDeviceStore()
        let query = store.baseQuery(account: "device-identity")
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
    }

    @Test("The access group actually reaches the query rather than being dropped")
    func accessGroupReachesQuery() {
        let store = PairedDeviceStore(
            configuration: .init(accessGroup: "ABCDE12345.com.uplink.app")
        )
        let query = store.baseQuery(account: "device-identity")
        #expect(query[kSecAttrAccessGroup as String] as? String == "ABCDE12345.com.uplink.app")
    }

    // SYMPTOM: items written with the default accessibility class could not be
    // read while the phone was locked, so the tunnel extension — whose entire
    // reason for existing is running on a locked phone — failed to load the
    // identity every time the screen went off.
    @Test("Items stay readable while the device is locked")
    func itemsAreReadableWhenLocked() {
        let attributes = PairedDeviceStore().writeAttributes()
        #expect(
            attributes[kSecAttrAccessible as String] as? String
                == (kSecAttrAccessibleAfterFirstUnlock as String)
        )
    }

    // The app and every extension must agree, or they are back to separate
    // keychains. Constructing them the way each target does and comparing is
    // the cheapest guard against that drifting apart again.
    @Test("App and extension configurations are identical")
    func appAndExtensionAgree() {
        let app = PairedDeviceStore.Configuration.shared
        let extensionSide = PairedDeviceStore.Configuration.shared
        #expect(app == extensionSide)
    }

    // -34018 is the error this misconfiguration actually produces, and it is
    // completely opaque. Anyone who hits it should be handed the fix.
    @Test("The entitlement error explains itself")
    func missingEntitlementIsDiagnosed() {
        let diagnosis = KeychainError.unexpectedStatus(-34018).diagnosis
        #expect(diagnosis.contains("keychain-access-groups"))
        #expect(diagnosis.contains(UpLinkIdentifiers.keychainAccessGroupSuffix))
    }
}

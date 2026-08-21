import Testing
import Network
import CryptoKit
@testable import UpLinkKit

@Suite("Where the phone's listener binds")
struct ListenerBindingTests {

    private var keys: [(identity: String, key: SymmetricKey)] {
        [("abc123", SymmetricKey(size: .bits256))]
    }

    private func listener(_ bearer: WirelessBearer) -> NWParameters {
        TransportParameters.listener(
            sessionKeys: keys, pairingKey: nil, port: 51820, bearer: bearer
        )
    }

    // usbmuxd's device side dials 127.0.0.1 on the phone, so binding loopback
    // is both sufficient and the safest choice: the port is unreachable from
    // Wi-Fi or cellular and cannot be probed from off the device.
    @Test("Over the cable it still pins loopback, which usbmuxd requires")
    func cablePinsLoopback() {
        let parameters = listener(.usbmux)
        #expect(parameters.requiredLocalEndpoint != nil)
        #expect(parameters.acceptLocalOnly == true)
    }

    // The Mac now dials the phone's address on the shared link. A listener
    // pinned to loopback is unreachable, and one accepting local connections
    // only refuses it — so both lines are wrong here, not just one.
    @Test("Over the access point it does not pin loopback")
    func accessPointDoesNotPinLoopback() {
        let parameters = listener(.hostedAP)
        #expect(parameters.requiredLocalEndpoint == nil)
        #expect(parameters.acceptLocalOnly == false)
    }

    @Test("Port reuse survives either way, because the extension restarts")
    func portReuseAlways() {
        for bearer in WirelessBearer.allCases {
            #expect(listener(bearer).allowLocalEndpointReuse == true)
        }
    }

    // The key set is what makes the listener startable at all; a TLS listener
    // with no key material cannot start, and an unpaired phone has none.
    @Test("Every bearer still gets key material, so the listener can start")
    func keySetIsNeverEmpty() {
        for bearer in WirelessBearer.allCases {
            _ = listener(bearer)
        }
        #expect(TransportParameters.listenerKeySet(sessionKeys: [], pairingKey: nil).count == 1)
    }
}

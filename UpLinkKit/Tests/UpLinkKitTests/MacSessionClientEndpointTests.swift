import Testing
import Network
@testable import UpLinkKit

@Suite("The Mac dials where the phone actually is")
struct MacSessionClientEndpointTests {

    // The cable's endpoint keeps a name rather than staying a literal, so the
    // USB path is still legible while both bearers exist — and so Task 12 has
    // one symbol to delete rather than a shape to hunt for.
    @Test("A loopback port still builds the loopback endpoint")
    func loopbackEndpointForCable() {
        #expect(MacSessionClient.loopbackEndpoint(port: 51820)
            == .hostPort(host: .ipv4(.loopback), port: 51820))
    }

    // The whole point of the bearer swap: an address discovered on the shared
    // link is dialled as-is. Rewriting it to loopback is the failure this
    // guards, and it would present as a bridge that connects to nothing.
    @Test("A discovered endpoint survives the round trip unchanged")
    func discoveredEndpointIsUsedVerbatim() {
        let discovered = NWEndpoint.hostPort(host: "192.168.2.2", port: 51820)
        let discovery = PeerDiscovery(stalenessWindow: 10)
        discovery.record(discovered)
        #expect(discovery.current() == discovered)
        #expect(discovery.current() != MacSessionClient.loopbackEndpoint(port: 51820))
    }
}

@Suite("How a peer link is named")
struct PeerDescriptionTests {

    // verify-cellular.sh decides whether a run proved anything by reading this
    // string. A description that says "usb" for a link running over the air is
    // the exact class of false evidence that script exists to refuse.
    @Test("The cable is still named as the cable")
    func cableIsNamed() {
        #expect(MacSessionClient.describe(MacSessionClient.loopbackEndpoint(port: 51820))
            == "usb:127.0.0.1:51820")
    }

    @Test("A link over the air is not named as a cable")
    func airIsNotNamedAsCable() {
        let described = MacSessionClient.describe(
            .hostPort(host: "192.168.2.2", port: 51820)
        )
        #expect(!described.contains("usb"))
        #expect(described.contains("192.168.2.2"))
    }
}

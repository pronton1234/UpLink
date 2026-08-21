import Testing
import Network
@testable import UpLinkKit

@Suite("Which interfaces a bearer forbids for egress")
struct WirelessBearerTests {

    @Test("The hosted access point forbids Wi-Fi, because the peer link IS Wi-Fi")
    func hostedAPForbidsWiFi() {
        #expect(WirelessBearer.hostedAP.prohibitedEgressInterfaces.contains(.wifi))
    }

    @Test("Every bearer still forbids wired, which is the cable hazard")
    func everyBearerForbidsWired() {
        for bearer in WirelessBearer.allCases {
            #expect(bearer.prohibitedEgressInterfaces.contains(.wiredEthernet))
        }
    }

    @Test("No bearer forbids cellular, which is the only path that may carry data")
    func noBearerForbidsCellular() {
        for bearer in WirelessBearer.allCases {
            #expect(!bearer.prohibitedEgressInterfaces.contains(.cellular))
        }
    }

    @Test("No bearer forbids loopback, which the integration suites depend on")
    func noBearerForbidsLoopback() {
        for bearer in WirelessBearer.allCases {
            #expect(!bearer.prohibitedEgressInterfaces.contains(.loopback))
        }
    }

    @Test("The hosted access point is preferred, and the cable is last")
    func preferenceOrder() {
        #expect(WirelessBearer.preferenceOrder == [.hostedAP, .peerToPeer, .usbmux])
    }
}

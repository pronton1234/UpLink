import Testing
import Network
@testable import UpLinkKit

// SYMPTOM (anticipated, and the reason this test exists before the defect):
// with the phone associated to an access point the Mac hosts, a destination
// dial satisfied over Wi-Fi leaves the phone, crosses the access point, and
// arrives back at the Mac. The user bypasses nothing, and the egress report
// says `.wifi` only after the fact.
//
// This is the same defect the cable already had and already guards against,
// one interface over. `requiredInterfaceType` does not prevent it: it is
// documented as a preference Network.framework may fall back from, which is
// precisely how a Wi-Fi fallback was once observed being reported as a
// successful cellular dial. Prohibiting the interface outright is the half
// that cannot be negotiated away.

@Suite("Regression: a destination dial can never re-enter the Mac")
struct EgressLoopRegressionTests {

    private let destination = StreamOpen(proto: .tcp, host: "example.com", port: 443)

    @Test("Over the hosted access point, Wi-Fi is prohibited outright")
    func hostedAPProhibitsWiFi() {
        let parameters = CellularDialer.parameters(
            for: destination, requiredInterface: .cellular, bearer: .hostedAP
        )
        #expect(parameters.prohibitedInterfaceTypes?.contains(.wifi) == true)
    }

    @Test("Cellular is still required, which is the product's whole claim")
    func cellularIsStillRequired() {
        let parameters = CellularDialer.parameters(
            for: destination, requiredInterface: .cellular, bearer: .hostedAP
        )
        #expect(parameters.requiredInterfaceType == .cellular)
    }

    @Test("Loopback stays reachable, so the integration suites still run")
    func loopbackIsNotProhibited() {
        let parameters = CellularDialer.parameters(
            for: destination, requiredInterface: nil, bearer: .hostedAP
        )
        #expect(parameters.prohibitedInterfaceTypes?.contains(.loopback) != true)
    }

    @Test("The cable's prohibition is unchanged, so nothing regresses on USB")
    func cableStillProhibitsWiredOnly() {
        let parameters = CellularDialer.parameters(
            for: destination, requiredInterface: .cellular, bearer: .usbmux
        )
        #expect(parameters.prohibitedInterfaceTypes?.contains(.wiredEthernet) == true)
        #expect(parameters.prohibitedInterfaceTypes?.contains(.wifi) != true)
    }
}

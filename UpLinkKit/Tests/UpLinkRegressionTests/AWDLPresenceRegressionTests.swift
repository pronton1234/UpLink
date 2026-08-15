import Testing
import Foundation
import Network
@testable import UpLinkKit

// Address parsing for `AWDLPresence`, which is the part that can be wrong
// silently. Holding the wrong address costs nothing visible — no error, no log
// the user would notice — and simply fails to prevent the 110-second recovery
// it exists to prevent.
//
// The endpoint description for a scoped IPv6 peer is
// `fe80::2063:e4ff:fed6:7ce0%awdl0.53632`. The port is separated by a DOT, not
// a colon, so `CapturePolicy.host(of:)` — which splits on the last colon —
// returns `fe80::2063:e4ff:fed6` here. That is a different, valid-looking
// address, which is exactly the kind of wrong that does not announce itself.

@Suite("Regression: AWDL presence targets the right peer")
struct AWDLPresenceRegressionTests {

    // THE FORMAT THAT ACTUALLY REACHES THIS. `MacSessionHost.describe` builds
    // "\(host):\(port)" for a .hostPort endpoint, so the separator is a COLON.
    // The first version of this suite only tested the dot form — the one
    // visible in the `accept:` log line — so it was green against an input the
    // code never receives, while production held towards a host with ":52540"
    // glued on. Observed in the log as:
    //   holding AWDL open towards fe80::2063:e4ff:fed6:7ce0%awdl0:52540
    @Test("The colon-separated form MacSessionHost actually produces")
    func parsesColonSeparatedAddress() {
        #expect(
            AWDLPresence.awdlHost(in: "fe80::2063:e4ff:fed6:7ce0%awdl0:52540")
                == "fe80::2063:e4ff:fed6:7ce0%awdl0"
        )
    }

    @Test("A scoped IPv6 peer keeps its scope and loses its port")
    func parsesScopedAddress() {
        #expect(
            AWDLPresence.awdlHost(in: "fe80::2063:e4ff:fed6:7ce0%awdl0.53632")
                == "fe80::2063:e4ff:fed6:7ce0%awdl0"
        )
    }

    // A bare literal has no port, and is full of colons. "Split on the last
    // colon" would return `fe80:` here, which is why the search starts after
    // the scope rather than at the end of the string.
    @Test("A bare scoped literal is not mistaken for having a port")
    func bareLiteralKeepsItsTail() {
        #expect(
            AWDLPresence.awdlHost(in: "fe80::1%awdl0") == "fe80::1%awdl0"
        )
    }

    @Test("An address with no port is left alone")
    func parsesWithoutPort() {
        #expect(
            AWDLPresence.awdlHost(in: "fe80::2063:e4ff:fed6:7ce0%awdl0")
                == "fe80::2063:e4ff:fed6:7ce0%awdl0"
        )
    }

    // The colon-splitting helper this deliberately does not reuse. Pinned so
    // nobody "simplifies" one into the other later.
    @Test("Splitting on the last colon would produce a different address")
    func colonSplittingIsWrong() {
        let description = "fe80::2063:e4ff:fed6:7ce0%awdl0.53632"
        #expect(
            CapturePolicy.host(of: description) != AWDLPresence.awdlHost(in: description),
            "if these ever agree, the port-separator assumption has changed and this guard is worthless"
        )
    }

    // Non-AWDL peers must be refused. Over USB or a shared network the kernel is
    // not making the scheduling decision, so an extra socket buys nothing and
    // the heartbeat is pure cost.
    @Test("Non-AWDL peers are not held")
    func refusesNonAWDLPeers() {
        #expect(AWDLPresence.awdlHost(in: "169.254.203.164:55881") == nil)
        #expect(AWDLPresence.awdlHost(in: "fe80::c04:fd44:fcd1:743f%en9.52344") == nil)
        #expect(AWDLPresence.awdlHost(in: "192.168.1.185:443") == nil)
    }

    @Test("A hold can be taken and released")
    func holdLifecycle() async {
        let presence = AWDLPresence(queue: DispatchQueue(label: "regression.presence"))
        #expect(await presence.isHolding == false)

        await presence.hold(peerDescription: "fe80::2063:e4ff:fed6:7ce0%awdl0.53632")
        #expect(await presence.isHolding, "hold did not take")

        await presence.release()
        #expect(await presence.isHolding == false, "release did not clear the hold")
    }

    @Test("Holding a non-AWDL peer leaves no socket behind")
    func refusedHoldLeavesNothing() async {
        let presence = AWDLPresence(queue: DispatchQueue(label: "regression.presence.2"))
        await presence.hold(peerDescription: "192.168.1.185:443")
        #expect(await presence.isHolding == false, "held a peer the kernel is not scheduling for")
    }
}

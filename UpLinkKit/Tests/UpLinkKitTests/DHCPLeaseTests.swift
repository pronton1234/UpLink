import Testing
@testable import UpLinkKit

@Suite("Finding the phone on the network the Mac hosts")
struct DHCPLeaseTests {

    // Verbatim from this Mac, 2026-08-20, after the phone joined.
    private let real = """
    {
    \tname=iPhone
    \tip_address=192.168.2.2
    \thw_address=1,56:b3:4e:5c:e8:ec
    \tidentifier=1,56:b3:4e:5c:e8:ec
    \tlease=0x6a87e20d
    }
    """

    @Test("The phone's address is read from a real lease file")
    func readsTheRealLease() {
        let leases = DHCPLease.parse(real)
        #expect(leases.count == 1)
        #expect(leases.first?.address == "192.168.2.2")
        #expect(leases.first?.name == "iPhone")
    }

    @Test("Several leases are all read, in file order")
    func readsSeveral() {
        let two = real + "\n{\n\tname=Other\n\tip_address=192.168.2.3\n}"
        let leases = DHCPLease.parse(two)
        #expect(leases.map(\.address) == ["192.168.2.2", "192.168.2.3"])
    }

    // The Mac is the gateway. Handing its own address to the dialler would mean
    // the extension dialling the machine it is running on.
    @Test("A lease without an address is skipped rather than yielding a blank")
    func skipsAddressless() {
        #expect(DHCPLease.parse("{\n\tname=Ghost\n}").isEmpty)
    }

    @Test("An empty or absent file is no leases, not a crash")
    func handlesEmpty() {
        #expect(DHCPLease.parse("").isEmpty)
        #expect(DHCPLease.parse("garbage that is not a lease").isEmpty)
    }

    // The lease file survives the network going away, so a stale entry from a
    // previous session reads exactly like a live one. Choosing the most recent
    // is the best this file supports — the real confirmation is the dial.
    @Test("The newest lease is preferred when several exist")
    func prefersNewest() {
        let older = "{\n\tname=A\n\tip_address=192.168.2.5\n\tlease=0x1\n}"
        let newer = "{\n\tname=B\n\tip_address=192.168.2.9\n\tlease=0xff\n}"
        #expect(DHCPLease.mostRecent(in: older + "\n" + newer)?.address == "192.168.2.9")
        #expect(DHCPLease.mostRecent(in: newer + "\n" + older)?.address == "192.168.2.9")
    }

    @Test("With no leases there is no peer, rather than a guess")
    func noLeases() {
        #expect(DHCPLease.mostRecent(in: "") == nil)
    }
}

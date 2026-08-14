import Testing
import Foundation
@testable import UpLinkKit

// SYMPTOM: with the bridge up and carrying traffic correctly, nothing loaded.
// Every hostname failed after ~30 seconds:
//
//     curl -w '...' https://speed.cloudflare.com/__down?bytes=1000000
//     dns=0.000000s connect=0.000000s total=29.761757s size=0    (exit 6)
//
// while the same transfer to a raw IP crossed the bridge at full speed — 10 MB
// in 0.51s. So the bridge was fine and name resolution was totally broken,
// which presents as "the bridge is unusably slow" because every connection
// begins with a lookup. Confusingly, `dig` and `dscacheutil` both worked.
//
// CAUSE: `DNSRedirect` held ONE `NWEndpoint`. Redirected queries overwrote each
// other, so replies were re-addressed to whichever resolver happened to be
// remembered last. A resolver client discards an answer that did not come from
// the address it queried, so the mismatched reply was dropped and the lookup
// retried until timeout.
//
// It needed two things at once to bite, which is why single-query tools looked
// healthy: two configured resolvers (here 2001:db8:1:2::1 and
// 192.168.1.254) and concurrent queries — `getaddrinfo` issues A and AAAA
// together, which is exactly what curl does and what dig does not.

@Suite("Regression: concurrent DNS queries must not swap return addresses")
struct DNSRedirectRegressionTests {

    /// Builds a DNS message with a given transaction ID. Only the first two
    /// bytes matter here; the rest is plausible header padding.
    private func message(id: UInt16) -> Data {
        var data = Data([UInt8(id >> 8), UInt8(id & 0xFF)])
        data.append(contentsOf: [0x81, 0x80, 0, 1, 0, 1, 0, 0, 0, 0])
        return data
    }

    /// The exact field failure: A and AAAA in flight together, aimed at two
    /// different resolvers.
    @Test("Two concurrent queries each get their own resolver back")
    func concurrentQueriesKeepTheirOwnEndpoints() {
        var table = DNSRedirectTable()

        table.remember(query: message(id: 0x1234), endpoint: "192.168.1.254:53")
        table.remember(query: message(id: 0xABCD), endpoint: "[2001:db8:1:2::1]:53")

        // Replies arrive in the opposite order, as they routinely do.
        #expect(table.original(forReply: message(id: 0xABCD)) == "[2001:db8:1:2::1]:53")
        #expect(table.original(forReply: message(id: 0x1234)) == "192.168.1.254:53")
    }

    /// The single-slot version passed this one — which is why the bug survived.
    @Test("A single query still round-trips")
    func singleQueryRoundTrips() {
        var table = DNSRedirectTable()
        table.remember(query: message(id: 0x0001), endpoint: "192.168.1.254:53")
        #expect(table.original(forReply: message(id: 0x0001)) == "192.168.1.254:53")
    }

    /// A reply for something we never redirected must not borrow another
    /// query's address — that would misdirect an unrelated answer.
    @Test("An unknown transaction returns nothing")
    func unknownTransactionIsNotGuessed() {
        var table = DNSRedirectTable()
        table.remember(query: message(id: 0x1111), endpoint: "192.168.1.254:53")
        #expect(table.original(forReply: message(id: 0x2222)) == nil)
        // …and the real one is still intact.
        #expect(table.original(forReply: message(id: 0x1111)) == "192.168.1.254:53")
    }

    /// Answered once. A late duplicate must not resurrect the mapping.
    @Test("A transaction is consumed by its reply")
    func replyConsumesTheMapping() {
        var table = DNSRedirectTable()
        table.remember(query: message(id: 0x7777), endpoint: "192.168.1.254:53")
        #expect(table.original(forReply: message(id: 0x7777)) != nil)
        #expect(table.original(forReply: message(id: 0x7777)) == nil)
        #expect(table.count == 0)
    }

    /// A retransmitted query takes the newer destination.
    @Test("A repeated transaction ID overwrites")
    func retransmissionOverwrites() {
        var table = DNSRedirectTable()
        table.remember(query: message(id: 0x5555), endpoint: "192.168.1.254:53")
        table.remember(query: message(id: 0x5555), endpoint: "[2001:db8:1:2::1]:53")
        #expect(table.original(forReply: message(id: 0x5555)) == "[2001:db8:1:2::1]:53")
        #expect(table.count == 0)
    }

    /// Bounded, because this lives in an extension with a hard 50 MB budget and
    /// a client that never reads its answers would otherwise grow it forever.
    @Test("The table is bounded and evicts oldest first")
    func tableIsBounded() {
        var table = DNSRedirectTable()
        for i in 0 ... (DNSRedirectTable.maxPending + 50) {
            table.remember(query: message(id: UInt16(i % 65536)), endpoint: "r\(i):53")
        }
        #expect(table.count <= DNSRedirectTable.maxPending)
        // The oldest are gone; the newest survive.
        let newest = UInt16((DNSRedirectTable.maxPending + 50) % 65536)
        #expect(table.original(forReply: message(id: newest)) != nil)
    }

    /// A stray datagram that is not a DNS message must be ignored rather than
    /// trapping — this runs on every UDP datagram the Mac sends.
    @Test("A too-short datagram is ignored")
    func shortDatagramIsIgnored() {
        var table = DNSRedirectTable()
        table.remember(query: Data([0x01]), endpoint: "192.168.1.254:53")
        #expect(table.count == 0)
        #expect(table.original(forReply: Data()) == nil)
    }
}

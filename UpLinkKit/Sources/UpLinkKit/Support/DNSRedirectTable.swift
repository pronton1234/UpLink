import Foundation

/// Remembers which resolver each redirected DNS query was originally aimed at,
/// so the reply can be handed back wearing the right return address.
///
/// **Why a table and not a variable.** A resolver client checks that an answer
/// came from the address it asked, and silently discards anything else. The
/// bridge redirects queries aimed at the Mac's own resolvers to a public one
/// (see ``UpLinkDNS``), so every reply has to be re-addressed on the way back.
/// An earlier version kept a single `NWEndpoint` and overwrote it on each
/// query, which is only correct if queries are strictly one at a time.
///
/// They are not. `getaddrinfo` issues the A and AAAA lookups *concurrently*,
/// and a Mac commonly has two resolvers configured — here
/// `2001:db8:1:2::1` and `192.168.1.254`. So the second query overwrote
/// the first's address, both replies came back labelled with whichever resolver
/// was remembered last, mDNSResponder discarded the mismatched one, and the
/// lookup sat there retrying until it timed out.
///
/// The user-visible result was total: every hostname failed to resolve after
/// roughly 30 seconds, so nothing loaded at all, while raw-IP traffic crossed
/// the bridge at full speed. It reads as a catastrophically slow bridge and is
/// really a name-resolution bug.
///
/// Keying on the DNS transaction ID fixes it, because that is the one field
/// guaranteed to be echoed from query to reply (RFC 1035 §4.1.1).
public struct DNSRedirectTable: Sendable {

    /// Bounds memory. A resolver has at most a handful of queries in flight;
    /// this is far above that and still small. Without a cap, a peer that sends
    /// queries and never reads answers would grow this without limit inside an
    /// extension with a hard 50 MB budget.
    public static let maxPending = 512

    private var pending: [UInt16: Entry] = [:]
    /// Insertion order, so the oldest entry is the one evicted.
    private var order: [UInt16] = []
    private var clock: UInt64 = 0

    private struct Entry {
        let endpoint: String
        let sequence: UInt64
    }

    public init() {}

    public var count: Int { pending.count }

    /// The transaction ID of a DNS message: the first two bytes, big-endian.
    ///
    /// Returns nil for anything too short to be a DNS header, which is the
    /// correct answer for a stray datagram rather than a reason to trap.
    public static func transactionID(of message: Data) -> UInt16? {
        guard message.count >= 2 else { return nil }
        let base = message.startIndex
        return UInt16(message[base]) << 8 | UInt16(message[base + 1])
    }

    /// Records where a query was really headed. `endpoint` is a description
    /// rather than an `NWEndpoint` so this stays a plain value type that tests
    /// can exercise without Network framework.
    ///
    /// A repeated transaction ID overwrites — that is a retransmission of the
    /// same query, and the newer destination is the right one.
    public mutating func remember(query: Data, endpoint: String) {
        guard let id = Self.transactionID(of: query) else { return }
        clock += 1
        if pending[id] == nil { order.append(id) }
        pending[id] = Entry(endpoint: endpoint, sequence: clock)
        evictIfNeeded()
    }

    /// Takes back the original destination for a reply, if we redirected it.
    ///
    /// Consuming rather than peeking: a transaction is answered once, and
    /// leaving it behind would let an unrelated later reply reuse the mapping.
    public mutating func original(forReply reply: Data) -> String? {
        guard let id = Self.transactionID(of: reply),
              let entry = pending.removeValue(forKey: id)
        else { return nil }
        order.removeAll { $0 == id }
        return entry.endpoint
    }

    private mutating func evictIfNeeded() {
        while order.count > Self.maxPending {
            let oldest = order.removeFirst()
            pending.removeValue(forKey: oldest)
        }
    }
}

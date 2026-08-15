import Foundation

/// A device that has been unpaired but has not yet been told.
///
/// The full record is kept, not just the fingerprint, because the public key is
/// what derives the session PSK — and the whole point is that the peer can still
/// complete a TLS handshake, which is the only channel through which it can be
/// told anything at all.
public struct RevokedDevice: Codable, Equatable, Sendable {
    public let device: PairedDevice
    public let revokedAt: Date

    public init(device: PairedDevice, revokedAt: Date = Date()) {
        self.device = device
        self.revokedAt = revokedAt
    }
}

/// Remembers devices that were unpaired while they were not connected, so they
/// can be told the next time they appear.
///
/// ## Why this has to exist
///
/// Unpairing is announced over the live session — the `unpaired` frame rides on
/// the very connection being closed. If the peer was asleep, unreachable, or
/// simply not bridging at the time, there is no session and the notice is never
/// sent. Nothing else carries revocation state: Bonjour publishes only the Mac's
/// own fingerprint, and TLS gives the peer a generic handshake failure that is
/// indistinguishable from every other reason a connection fails.
///
/// So the stranded phone re-dials forever, holding a pairing the Mac has
/// forgotten, and the user has to notice and clean it up by hand on both
/// devices. That is the common case, because removing a device you are not
/// currently using is the normal thing to do.
///
/// A tombstone keeps the revoked device's PSK on the air for a bounded window
/// with one job: accept the connection, say `unpaired`, and close. The caller
/// must reject the session **before** it starts — a tombstone that could carry
/// traffic would be a revoked device still bridging, which is the opposite of
/// what was asked for.
public struct RevocationTombstones: Codable, Equatable, Sendable {

    /// Long enough for a phone that was off overnight, short enough that a
    /// revoked key is not on the air indefinitely.
    public static let validity: TimeInterval = 24 * 60 * 60

    /// A cap, so a long-lived Mac cannot accumulate revoked keys without bound.
    /// Oldest are dropped first; they are also the least likely to still matter.
    public static let capacity = 32

    private var entries: [RevokedDevice] = []

    public init() {}

    public init(_ entries: [RevokedDevice]) { self.entries = entries }

    public var all: [RevokedDevice] { entries }

    /// Records a device that has been unpaired without being told.
    public mutating func revoke(_ device: PairedDevice, at now: Date = Date()) {
        entries.removeAll { $0.device.fingerprint == device.fingerprint }
        entries.append(RevokedDevice(device: device, revokedAt: now))
        expire(at: now)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    /// Drops a tombstone once its notice has been delivered.
    public mutating func delivered(_ fingerprint: String) {
        entries.removeAll { $0.device.fingerprint == fingerprint }
    }

    /// A device that pairs again is no longer revoked, whatever the tombstone
    /// says. Without this the fresh pairing would be refused by its own history.
    public mutating func reinstated(_ fingerprint: String) {
        delivered(fingerprint)
    }

    public mutating func expire(at now: Date = Date()) {
        entries.removeAll { now.timeIntervalSince($0.revokedAt) >= Self.validity }
    }

    public func isRevoked(_ fingerprint: String, at now: Date = Date()) -> Bool {
        entries.contains {
            $0.device.fingerprint == fingerprint
                && now.timeIntervalSince($0.revokedAt) < Self.validity
        }
    }

    /// The devices whose PSKs must stay in the listener so they can be told.
    public func devicesToKeepOnAir(at now: Date = Date()) -> [PairedDevice] {
        entries
            .filter { now.timeIntervalSince($0.revokedAt) < Self.validity }
            .map(\.device)
    }
}

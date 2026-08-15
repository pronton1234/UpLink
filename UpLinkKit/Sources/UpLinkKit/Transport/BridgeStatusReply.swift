import Foundation

/// What an extension reports when the containing app asks for status.
///
/// Shared by both sides so the two cannot drift, and — more importantly — so
/// the parsing is testable at all. It previously lived inline in each app
/// target, where nothing could reach it, and it contained a defect that made
/// every on-device measurement untrustworthy: a `disconnected` reply was
/// treated as "no new information" and the UI carried on showing a connection
/// that had already ended. A status display that can be wrong is worse than no
/// display, because every test run afterwards is measuring an unknown state.
public enum BridgeStatusReply: Equatable, Sendable {

    /// A live session, with whatever egress the peer last observed.
    case connected(peer: String, egress: EgressInterface)
    /// The extension is running but has no session.
    case disconnected
    /// The extension has a relay to dial and is trying. Distinct from
    /// `disconnected` so the Mac can say "Connecting…" rather than "Waiting for
    /// USB connection" at a user whose cable is plainly plugged in — the whole
    /// reason the idle states were split apart.
    case connecting
    /// The peer has removed this pairing. Distinct from `disconnected`, because
    /// retrying is pointless and the user has to pair again — a state that
    /// previously presented as an endless run of ordinary connection failures.
    case unpaired(fingerprint: String?)
    /// The peer is reachable and refuses this device's key. Distinct from
    /// `disconnected`, which means "keep trying".
    case refused
    /// The reply could not be understood. Deliberately distinct from
    /// `disconnected`: garbage means "ask again", not "tear the UI down".
    case unintelligible

    /// Parses a reply of the form `connected|<peer>|<egressByte>`.
    ///
    /// Both trailing fields are optional so the two extensions can send what
    /// they have — the phone knows its egress but not a peer description, the
    /// Mac knows both.
    public static func parse(_ reply: String?) -> BridgeStatusReply {
        guard let reply, !reply.isEmpty else { return .unintelligible }

        let parts = reply.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard let head = parts.first else { return .unintelligible }
        if head == "refused" { return .refused }
        if head == "unpaired" {
            // The fingerprint is optional so the phone, which knows which Mac it
            // was talking to, can keep sending a bare "unpaired".
            return .unpaired(fingerprint: parts.count > 1 ? parts[1] : nil)
        }

        switch head {
        case "connected":
            // Field order differs between the two senders, so an egress byte is
            // recognised wherever it appears rather than by position.
            let egress = parts.dropFirst()
                .compactMap { UInt8($0).flatMap(EgressInterface.init(rawValue:)) }
                .first ?? .unknown
            let peer = parts.count > 2 ? parts[1] : ""
            return .connected(peer: peer, egress: egress)

        case "disconnected", "waiting":
            return .disconnected

        case "connecting":
            return .connecting

        default:
            return .unintelligible
        }
    }

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

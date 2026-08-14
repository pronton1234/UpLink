import Foundation
import Network

/// A Mac the phone can bridge through.
public struct DiscoveredPeer: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let endpoint: NWEndpoint
    /// Fingerprint from the TXT record, present once the Mac has an identity.
    public let fingerprint: String?
    /// Which transport this peer was found over.
    public let profile: TransportProfile

    /// Whether this peer has already been paired with.
    public var isKnown: Bool { fingerprint != nil }

    /// Normally these come only from ``PeerDiscovery``. This is public so a
    /// test or probe can aim the real client at a known endpoint and exercise
    /// the handshake without a Bonjour round trip.
    public init(
        id: String,
        name: String,
        endpoint: NWEndpoint,
        fingerprint: String?,
        profile: TransportProfile
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.fingerprint = fingerprint
        self.profile = profile
    }
}

/// Browses for UpLink Macs over Bonjour.
///
/// Discovery is not optional: AWDL only carries traffic to endpoints found via
/// Bonjour, so even when the two devices could in principle address each other
/// directly, they must meet through the browser first.
public actor PeerDiscovery {

    private var browser: NWBrowser?
    private var continuations: [UUID: AsyncStream<[DiscoveredPeer]>.Continuation] = [:]
    private var latest: [DiscoveredPeer] = []
    private let profile: TransportProfile

    public init(profile: TransportProfile) {
        self.profile = profile
    }

    /// A stream of the currently visible peers. Emits the full set on each
    /// change rather than deltas — the list is tiny and a whole-set update is
    /// far harder to get subtly wrong in the UI.
    public func peers() -> AsyncStream<[DiscoveredPeer]> {
        AsyncStream { continuation in
            let token = UUID()
            continuations[token] = continuation
            continuation.yield(latest)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(token) }
            }
        }
    }

    private func removeObserver(_ token: UUID) {
        continuations.removeValue(forKey: token)
    }

    public func start(on queue: DispatchQueue) {
        guard browser == nil else { return }

        let parameters = NWParameters()
        parameters.includePeerToPeer = profile.includesPeerToPeer

        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: UpLinkService.bonjourType,
            domain: nil
        )
        let browser = NWBrowser(for: descriptor, using: parameters)

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let peers = results.compactMap { Self.peer(from: $0, profile: self?.profile ?? .localLink) }
            Task { await self?.update(peers) }
        }

        browser.start(queue: queue)
        self.browser = browser
    }

    private func update(_ peers: [DiscoveredPeer]) {
        latest = peers.sorted { $0.name < $1.name }
        for (_, continuation) in continuations { continuation.yield(latest) }
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        for (_, continuation) in continuations { continuation.finish() }
        continuations.removeAll()
    }

    private static func peer(from result: NWBrowser.Result, profile: TransportProfile) -> DiscoveredPeer? {
        guard case let .service(name, _, _, _) = result.endpoint else { return nil }

        var fingerprint: String?
        if case let .bonjour(txt) = result.metadata {
            fingerprint = txt[UpLinkService.fingerprintKey]
        }

        return DiscoveredPeer(
            id: name,
            name: name,
            endpoint: result.endpoint,
            fingerprint: fingerprint,
            profile: profile
        )
    }
}

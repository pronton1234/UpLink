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

    /// Whether this Mac publishes an identity at all.
    ///
    /// NOT "this device has paired with it" — that was the old name and the old
    /// meaning of `isKnown`, and it was wrong in the one place it was used. The
    /// iOS list drew a green "Paired" seal from this, so EVERY UpLink Mac looked
    /// paired, including ones this phone had never seen, and including the exact
    /// case where a stale pairing was failing. Ask ``isPaired(with:)`` instead.
    public var publishesIdentity: Bool { fingerprint != nil }

    /// Whether this phone actually holds a pairing with this Mac.
    ///
    /// The only honest source is the local store, so it has to be passed in.
    public func isPaired(with paired: [PairedDevice]) -> Bool {
        guard let fingerprint else { return false }
        return paired.contains { $0.fingerprint == fingerprint }
    }

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
    /// When `latest` was last refreshed by the browser.
    ///
    /// Results are not evidence forever. `peers()` yields whatever it has the
    /// instant a caller subscribes, so a stale entry from before a radio change
    /// is returned immediately and the caller then spends the full
    /// `NWConnectionChannel.connectTimeout` — twelve seconds — dialling an
    /// endpoint that no longer exists. Every retry, at the exact moment the
    /// device is trying to recover.
    private var latestAt: ContinuousClock.Instant?
    /// Long enough for a healthy browse to refresh, short enough that a dead
    /// endpoint is not dialled twice. Injectable so the rule can be tested in
    /// milliseconds rather than by sleeping through the real window.
    private let staleAfter: Duration
    private let profile: TransportProfile
    private var queue: DispatchQueue?
    /// How many browsers have been built over this actor's life.
    ///
    /// The only externally observable difference between "the failure was
    /// noticed and a replacement was built" and "the failure was swallowed and
    /// the browser is wedged forever" — the second being the bug this file
    /// exists to prevent, and one with no other signature from outside.
    public private(set) var generation = 0

    public init(profile: TransportProfile, staleAfter: Duration = .seconds(15)) {
        self.profile = profile
        self.staleAfter = staleAfter
    }

    /// A stream of the currently visible peers. Emits the full set on each
    /// change rather than deltas — the list is tiny and a whole-set update is
    /// far harder to get subtly wrong in the UI.
    public func peers() -> AsyncStream<[DiscoveredPeer]> {
        AsyncStream { continuation in
            let token = UUID()
            continuations[token] = continuation
            continuation.yield(fresh)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(token) }
            }
        }
    }

    private func removeObserver(_ token: UUID) {
        continuations.removeValue(forKey: token)
    }

    /// `latest`, or nothing if it is too old to believe.
    private var fresh: [DiscoveredPeer] {
        guard let latestAt, latestAt.duration(to: .now) < staleAfter else { return [] }
        return latest
    }

    public func start(on queue: DispatchQueue) {
        guard browser == nil else { return }
        self.queue = queue

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

        // THE MISSING SENSOR. Without this a browser that goes `.failed` — which
        // is what happens when the interface it is scoped to is reconfigured,
        // exactly what a Wi-Fi disconnect does to AWDL — is completely
        // invisible. It stays wedged for the life of the tunnel, `firstMatch`
        // keeps returning nil, and the Mac sees no inbound connection at all.
        //
        // Measured: 100 seconds with zero `accept:` on the Mac. The phone was
        // not being refused; it was never dialling, because the only thing that
        // could have told it to look again had failed silently.
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case let .failed(error):
                Task { await self?.browserFailed(String(describing: error)) }
            case .cancelled:
                Task { await self?.browserFailed("cancelled") }
            default:
                break
            }
        }

        browser.start(queue: queue)
        self.browser = browser
        generation += 1
    }

    /// Rebuilds after a failure. A browser cannot be restarted once it has
    /// failed — only replaced.
    private func browserFailed(_ reason: String) {
        PhoneDiagnosticLog.shared.write("discovery browser failed (\(reason)) — rebuilding")
        guard let queue else { return }
        browser?.cancel()
        browser = nil
        latest = []
        latestAt = nil
        start(on: queue)
    }

    /// Tears the browser down and builds a fresh one.
    ///
    /// Called between connection attempts. A new browser re-issues the mDNS
    /// query; one that has stopped receiving cannot be made to look again, and
    /// the old code reused a single instance for the tunnel's entire lifetime.
    public func restart() {
        guard let queue else { return }
        PhoneDiagnosticLog.shared.write("discovery restart")
        browser?.cancel()
        browser = nil
        latest = []
        latestAt = nil
        start(on: queue)
    }

    /// Test seam: record an observation as though the browser had reported it.
    func observeForTesting(_ peers: [DiscoveredPeer]) { update(peers) }

    /// Test seam: drive the same path `stateUpdateHandler` drives on `.failed`.
    /// A real `NWBrowser` failure needs a radio to be reconfigured underneath
    /// it, which is precisely the event that cannot be staged in a unit test.
    func simulateBrowserFailureForTesting(_ reason: String) { browserFailed(reason) }

    private func update(_ peers: [DiscoveredPeer]) {
        latest = peers.sorted { $0.name < $1.name }
        latestAt = .now
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

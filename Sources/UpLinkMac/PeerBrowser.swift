import Foundation
import Network
import UpLinkKit
import OSLog

/// Watches the shared link for the phone.
///
/// Thin on purpose. The decision that can be wrong — whether a sighting is
/// still current — lives in `PeerDiscovery` in the kit, where it is tested
/// against a clock rather than a radio. This type is the wiring.
///
/// Two failures from the 2026-08-14 hardware round are designed in rather than
/// rediscovered, both recorded in docs/REGRESSIONS.md.
@MainActor
final class PeerBrowser {

    private let log = Logger(subsystem: UpLinkIdentifiers.logSubsystem, category: "browse")
    private let queue = DispatchQueue(label: "com.uplink.app.browse")

    /// The current sighting, with its expiry. Read by whoever is about to dial.
    let discovery = PeerDiscovery()

    private var browser: NWBrowser?
    private var restarting = false

    var currentPeer: NWEndpoint? { discovery.current() }

    func start() {
        guard browser == nil else { return }
        build()
    }

    func stop() {
        browser?.cancel()
        browser = nil
        discovery.forget()
    }

    private func build() {
        let parameters = NWParameters.tcp
        // Bonjour over the access-point link. Not peer-to-peer: AWDL is not the
        // bearer, and asking for it here would invite the kernel to satisfy the
        // browse over a radio that is idle whenever the Mac is unassociated.
        parameters.includePeerToPeer = false

        let browser = NWBrowser(
            for: .bonjour(type: UpLinkIdentifiers.bonjourServiceType, domain: nil),
            using: parameters
        )

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            guard let result = results.first else {
                // An empty result set is not a stale peer's death certificate —
                // it may simply be a browse in progress — so nothing is
                // forgotten here. Expiry is what retires a sighting.
                return
            }
            Task { @MainActor in
                self.discovery.record(result.endpoint)
            }
        }

        // WITHOUT THIS THE BROWSER IS UNDETECTABLY WEDGED. Measured on hardware
        // 2026-08-14: the browser had no state handler at all, so one that
        // failed when its interface was reconfigured could never be noticed —
        // and the lookup returned nil for the entire life of the tunnel, with
        // the phone sitting right there.
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case let .failed(error):
                Task { @MainActor in self?.rebuild(because: "failed: \(error)") }
            case .cancelled:
                // Only a deliberate stop cancels, and stop() clears the
                // reference first — so anything arriving here with a browser
                // still held is a death, not a shutdown. Reading a deliberate
                // shutdown as a death is how a previous fix put the Mac back on
                // the air after the user quit.
                Task { @MainActor in
                    guard self?.browser != nil else { return }
                    self?.rebuild(because: "cancelled unexpectedly")
                }
            default:
                break
            }
        }

        browser.start(queue: queue)
        self.browser = browser
    }

    /// Replaces a browser that cannot recover.
    ///
    /// Debounced. One radio change produces a burst of terminal states, and
    /// rebuilding per event makes the browse flap rather than settle — which is
    /// the shape the advertisement side of this already had to be fixed for.
    private func rebuild(because reason: String) {
        guard !restarting else { return }
        restarting = true
        log.error("browser \(reason, privacy: .public) — rebuilding")

        browser?.cancel()
        browser = nil
        // A radio change invalidates every cached endpoint at once, and the new
        // browser takes time to say so. Dialling a corpse costs the full
        // connect timeout at exactly the wrong moment.
        discovery.forget()

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.restarting = false
            self?.build()
        }
    }
}

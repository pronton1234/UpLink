import Testing
import Foundation
import Network
import CryptoKit
@testable import UpLinkKit

// SYMPTOM, Mac side: after the Wi-Fi disconnect the phone browsed for a hundred
// seconds and found nothing, while the Mac logged no error at all.
//
// The reason it logged nothing is that it had no sensor. `restartListener()`
// was reachable only from `start()` and `setPairingCode()`, so once the Mac was
// up it never re-advertised for any reason whatsoever. There was no
// `NWPathMonitor` anywhere in the kit. The listener's `stateUpdateHandler`
// handled `.failed` alone, and all it did was emit an event that nothing in the
// codebase acted on.
//
// So a listener that survived the radio change but stopped being advertised on
// the re-derived `awdl0` was, from the Mac's point of view, working perfectly.
//
// These tests pin the sensor and the debounce. The debounce matters as much as
// the trigger: a Wi-Fi disconnect produces a burst of path updates, and
// re-advertising on each one is its own failure — the port changes every rebuild
// (`NWListener` will not rebind a port it just released), so a browser watching
// would see the service flap rather than settle.

@Suite("Regression: the Mac must stay findable across a radio change")
struct AdvertisementRecoveryRegressionTests {

    private func makeHost(debounce: Duration) -> MacSessionHost {
        MacSessionHost(
            identity: Curve25519.KeyAgreement.PrivateKey(),
            deviceName: "Path Test",
            store: InMemoryDeviceDirectory(),
            queue: DispatchQueue(label: "regression.path"),
            profile: .localLink,
            pathDebounce: debounce,
            // The real monitor would report this machine's actual network on
            // its own schedule and prime the signature before any synthetic
            // change, making every assertion below a race against the room.
            monitorsPath: false
        )
    }

    /// Waits for the generation to exceed `baseline`, up to a bound, so the test
    /// neither sleeps a fixed pessimistic interval nor races the debounce.
    private func awaitGeneration(
        above baseline: Int,
        on host: MacSessionHost,
        within limit: Duration = .milliseconds(2000)
    ) async -> Int {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            let generation = await host.listenerGeneration
            if generation > baseline { return generation }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await host.listenerGeneration
    }

    @Test("A material path change puts the Mac back on the air")
    func pathChangeRebuildsAdvertisement() async throws {
        let host = makeHost(debounce: .milliseconds(50))
        try await host.start()
        defer { Task { await host.stop() } }

        let before = await host.listenerGeneration
        #expect(before == 1, "start should have built exactly one listener")

        // The first observation is the state the listener was already built
        // for; it must not trigger anything.
        await host.pathChanged(PathSignature(status: "satisfied", interfaces: ["en0", "awdl0"]))
        try await Task.sleep(for: .milliseconds(150))
        #expect(
            await host.listenerGeneration == before,
            "the first path observation re-advertised for no reason"
        )

        // Wi-Fi leaves its network: the interface set changes.
        await host.pathChanged(PathSignature(status: "unsatisfied", interfaces: ["awdl0"]))

        let after = await awaitGeneration(above: before, on: host)
        #expect(
            after > before,
            "the Mac did not re-advertise after the path changed — the phone will browse and find nothing, and the Mac will log no error because it never noticed"
        )

        // And it must actually be ACCEPTING afterwards, not merely counted as
        // rebuilt. A re-advertisement that leaves no socket behind is worse
        // than none: the phone finds the service, dials it, and is refused.
        //
        // Polled rather than checked once, because the generation is stamped
        // inside `restartListener()` and the bind completes just after it.
        let port = await awaitBoundPort(on: host)
        #expect(port != nil, "re-advertised but never bound a port")
        if let port {
            #expect(await isAccepting(port), "re-advertised on a port that refuses connections")
        }
    }

    private func awaitBoundPort(
        on host: MacSessionHost,
        within limit: Duration = .milliseconds(2000)
    ) async -> NWEndpoint.Port? {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if let port = await host.listeningPort, port.rawValue != 0 { return port }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    /// A bare TCP connect. TLS is deliberately not involved — the question is
    /// whether a socket exists, not whether a handshake succeeds.
    private func isAccepting(_ port: NWEndpoint.Port) async -> Bool {
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        defer { connection.cancel() }

        return await withCheckedContinuation { continuation in
            let once = OnceFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: true) }
                case .failed, .waiting:
                    if once.claim() { continuation.resume(returning: false) }
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "regression.path.probe"))
        }
    }

    @Test("A burst of path updates produces one re-advertisement, not a burst")
    func pathChangesAreDebounced() async throws {
        let host = makeHost(debounce: .milliseconds(250))
        try await host.start()
        defer { Task { await host.stop() } }

        // Prime, so the first-observation guard is out of the way.
        await host.pathChanged(PathSignature(status: "satisfied", interfaces: ["en0", "awdl0"]))
        let before = await host.listenerGeneration

        // What one Wi-Fi disconnect actually looks like from NWPathMonitor.
        for interfaces in [["en0"], [], ["awdl0"], ["awdl0", "utun0"], ["awdl0"]] {
            await host.pathChanged(PathSignature(status: "unsatisfied", interfaces: interfaces))
            try await Task.sleep(for: .milliseconds(30))
        }

        let after = await awaitGeneration(above: before, on: host)
        #expect(
            after == before + 1,
            "five path updates produced \(after - before) rebuilds — the port changes on every one, so a watching browser sees the service flap rather than settle"
        )
    }

    @Test("An unchanged path signature is not a change")
    func identicalSignatureIsIgnored() async throws {
        let host = makeHost(debounce: .milliseconds(50))
        try await host.start()
        defer { Task { await host.stop() } }

        let signature = PathSignature(status: "satisfied", interfaces: ["en0", "awdl0"])
        await host.pathChanged(signature)
        let before = await host.listenerGeneration

        // NWPathMonitor fires on DHCP renewals and metric updates too. Those are
        // not reachability changes and must not cost an advertisement.
        for _ in 0 ..< 5 { await host.pathChanged(signature) }
        try await Task.sleep(for: .milliseconds(200))

        #expect(
            await host.listenerGeneration == before,
            "a repeated identical path signature re-advertised — every DHCP renewal would now flap the service"
        )
    }

    // Found by reading the log of the tests above, which showed
    // `listener died (cancelled) — rebuilding` firing during `stop()`.
    //
    // `stop()` cancels the listener, and cancelling a listener is exactly what
    // `.cancelled` reports — so the new "rebuild on a terminal state" rule read
    // a deliberate shutdown as a death and immediately put the Mac back on the
    // air. A host that cannot be stopped keeps a Bonjour advertisement and a
    // bound socket alive after the user quits.
    @Test("Stopping the host does not resurrect the listener")
    func stopDoesNotRebuild() async throws {
        let host = makeHost(debounce: .milliseconds(50))
        try await host.start()

        let before = await host.listenerGeneration
        await host.stop()

        // Generously longer than the rebuild path takes, so a resurrection has
        // every chance to happen if it is going to.
        try await Task.sleep(for: .milliseconds(400))

        #expect(
            await host.listenerGeneration == before,
            "stop() rebuilt the listener — cancelling it was mistaken for it dying, so the Mac stays advertised after the user quits"
        )
        #expect(await host.listeningPort == nil, "still listening after stop()")
    }

    @Test("Interface ordering is not mistaken for a change")
    func interfaceOrderingIsNormalised() {
        // The framework makes no ordering guarantee, and an unstable order
        // would make every single update look material.
        #expect(
            PathSignature(status: "satisfied", interfaces: ["en0", "awdl0"])
                == PathSignature(status: "satisfied", interfaces: ["awdl0", "en0"])
        )
        #expect(
            PathSignature(status: "satisfied", interfaces: ["en0"])
                != PathSignature(status: "unsatisfied", interfaces: ["en0"])
        )
    }
}

import Testing
import Foundation
import Network
import CryptoKit
@testable import UpLinkKit

// SYMPTOM: found while building the loopback pairing harness, which dialled the
// port it had read a moment earlier and got ECONNREFUSED. Showing a pairing
// code rebuilds the listener — the pairing PSK has to be baked into the TLS
// options — and the replacement lands on a *different* ephemeral port. Anything
// holding the previously advertised address is then talking to nothing.
//
// The port cannot be preserved: NWListener will not rebind a port it just
// released (EADDRINUSE), and `allowLocalEndpointReuse` does not permit two
// listeners on one port, so overlapping them fails too. What CAN be guaranteed,
// and is what actually matters, is that the rebuild is finished — the Mac
// reachable again, Bonjour re-advertised — before the operation that triggered
// it returns. These tests pin that guarantee.

@Suite("Regression: listener availability across rebuilds")
struct ListenerPortRegressionTests {

    private func makeHost() -> (MacSessionHost, InMemoryDeviceDirectory) {
        let store = InMemoryDeviceDirectory()
        let host = MacSessionHost(
            identity: Curve25519.KeyAgreement.PrivateKey(),
            deviceName: "Port Test",
            store: store,
            queue: DispatchQueue(label: "regression.port"),
            profile: .localLink
        )
        return (host, store)
    }

    /// Opens a bare TCP connection to prove something is actually accepting
    /// there. TLS is deliberately not involved: the question is whether the
    /// socket exists, not whether a handshake succeeds.
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
            connection.start(queue: DispatchQueue(label: "regression.probe"))
        }
    }

    @Test("The Mac is listening again by the time a code is shown")
    func listeningAfterShowingACode() async throws {
        let (host, _) = makeHost()
        try await host.start()
        defer { Task { await host.stop() } }

        try await host.setPairingCode(PairingCode.random())

        let port = try #require(await host.listeningPort)
        #expect(port.rawValue != 0)
        #expect(await isAccepting(port), "nothing is accepting after the code was shown")
    }

    @Test("The Mac is listening again by the time a code is cleared")
    func listeningAfterClearingACode() async throws {
        let (host, _) = makeHost()
        try await host.start()
        defer { Task { await host.stop() } }

        try await host.setPairingCode(PairingCode.random())
        try await host.setPairingCode(nil)

        let port = try #require(await host.listeningPort)
        #expect(await isAccepting(port))
    }

    // What a user toggling the pairing sheet actually does. Each rebuild must
    // leave a working listener, not just the first.
    @Test("Repeated rebuilds always leave a working listener")
    func repeatedRebuildsStayUp() async throws {
        let (host, _) = makeHost()
        try await host.start()
        defer { Task { await host.stop() } }

        for _ in 0 ..< 5 {
            try await host.setPairingCode(PairingCode.random())
            let up = try #require(await host.listeningPort)
            #expect(await isAccepting(up))

            try await host.setPairingCode(nil)
            let down = try #require(await host.listeningPort)
            #expect(await isAccepting(down))
        }
    }
}

/// Guards a continuation against a second resume from `stateUpdateHandler`.
///
/// File-scope rather than `private` because more than one regression suite
/// probes a listener the same way.
final class OnceFlag: @unchecked Sendable {
    private var used = false
    private let lock = NSLock()

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

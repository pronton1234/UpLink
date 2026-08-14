import Foundation
import Network
import CryptoKit
import UpLinkKit

// Usage:  pair-probe <six-digit-code>
//
// Browses for the Mac's _uplink._tcp service, prints exactly what it found
// (name, fingerprint, endpoint), then runs the real PairingClient against it.
// Every step is printed, because "pairing failed" without knowing which step
// failed is what made this hard on the phone.

let arguments = CommandLine.arguments
let queue = DispatchQueue(label: "pair-probe")

// --tls compares TLS-PSK option sets head to head, with no UpLinkKit framing,
// actors, or Bonjour in the way.
if arguments.count == 2, arguments[1] == "--tls" {
    for variant in PSKVariant.allCases {
        let outcome = await probeTLS(variant: variant)
        print("\(variant.rawValue.padding(toLength: 22, withPad: " ", startingAt: 0)) \(outcome)")
    }
    exit(0)
}

// --loopback runs BOTH sides in this process against 127.0.0.1. No Bonjour, no
// phone, no code to read off a screen: it answers "can this listener pair with
// a correct client at all?" in under a second.
if arguments.count == 2, arguments[1] == "--loopback" {
    func step(_ text: String) { print("· \(text)"); fflush(stdout) }

    let hostIdentity = Curve25519.KeyAgreement.PrivateKey()
    let store = InMemoryDeviceDirectory()
    let host = MacSessionHost(
        identity: hostIdentity,
        deviceName: "Loopback Mac",
        store: store,
        queue: DispatchQueue(label: "pair-probe.host"),
        profile: .localLink
    )

    step("starting listener")
    try await host.start()

    func awaitPort() async throws -> NWEndpoint.Port? {
        for _ in 0 ..< 100 {
            if let port = await host.listeningPort, port.rawValue != 0 { return port }
            try await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    guard let first = try await awaitPort() else {
        print("FAIL: listener never bound a port")
        exit(1)
    }
    step("listening on 127.0.0.1:\(first.rawValue)")

    let code = PairingCode.random()
    try await host.setPairingCode(code)
    step("pairing code set: \(code.digits)")

    // Read the port AGAIN: setting a code rebuilds the listener, and dialing
    // the pre-rebuild port gets ECONNREFUSED.
    guard let port = try await awaitPort() else {
        print("FAIL: listener never rebound after the code was set")
        exit(1)
    }
    if port != first { step("listener moved to port \(port.rawValue) when the code was set") }

    let target = DiscoveredPeer(
        id: "loopback",
        name: "Loopback Mac",
        endpoint: .hostPort(host: "127.0.0.1", port: port),
        fingerprint: await host.fingerprint,
        profile: .localLink
    )
    step("dialing as a phone would")

    let work = Task {
        try await PairingClient(queue: queue, deviceName: "Loopback Phone")
            .pair(with: target, code: code, localIdentity: .init())
    }
    let guardTask = Task {
        try await Task.sleep(for: .seconds(25))
        print("FAIL: the handshake hung for 25s with no error")
        exit(1)
    }

    do {
        let device = try await work.value
        guardTask.cancel()
        step("client paired with \(device.name) fp=\(device.fingerprint)")
        let saved = (try? store.pairedDevices()) ?? []
        step("host recorded \(saved.count) device(s): \(saved.map(\.name).joined(separator: ", "))")
        print(saved.count == 1 ? "OK: loopback pairing works" : "FAIL: host did not record the phone")
        exit(saved.count == 1 ? 0 : 1)
    } catch {
        guardTask.cancel()
        print("FAIL: \(error)")
        exit(1)
    }
}

guard arguments.count == 2, let code = try? PairingCode(digits: arguments[1]) else {
    FileHandle.standardError.write(Data("usage: pair-probe <six-digit-code> | --loopback\n".utf8))
    exit(2)
}

func findPeer(profile: TransportProfile) async -> DiscoveredPeer? {
    let discovery = PeerDiscovery(profile: profile)
    await discovery.start(on: queue)
    defer { Task { await discovery.stop() } }

    let deadline = Date().addingTimeInterval(6)
    for await peers in await discovery.peers() {
        if let peer = peers.first { return peer }
        if Date() > deadline { return nil }
    }
    return nil
}

// The phone browses with the peer-to-peer profile; match it so the endpoint and
// interface selection are the same ones the real client would use.
let profile = TransportProfile.preferenceOrder.first ?? .localLink
print("browsing for \(UpLinkService.bonjourType) (profile: \(profile.rawValue))…")

guard let peer = await findPeer(profile: profile) else {
    print("FAIL: no UpLink Mac found over Bonjour")
    exit(1)
}

print("found:       \(peer.name)")
print("endpoint:    \(peer.endpoint)")
print("fingerprint: \(peer.fingerprint ?? "<none — TXT record missing>")")

guard let fingerprint = peer.fingerprint else {
    print("FAIL: no fingerprint in the TXT record, so no salt can be derived")
    exit(1)
}

// Printed so a salt mismatch is visible rather than inferred: this is the exact
// value both sides must hash, byte for byte.
let salt = Data(SHA256.hash(data: Data(fingerprint.utf8)))
print("salt:        \(salt.map { String(format: "%02x", $0) }.joined().prefix(16))… (SHA256 of the fingerprint)")

// A throwaway identity: this probe is not a device anyone should stay paired
// with, and using the real store would pollute the Mac's own keychain.
let identity = Curve25519.KeyAgreement.PrivateKey()
print("pairing as:  pair-probe (throwaway identity)")

do {
    let device = try await PairingClient(queue: queue, deviceName: "pair-probe").pair(
        with: peer,
        code: code,
        localIdentity: identity
    )
    print("OK: paired with \(device.name) fp=\(device.fingerprint)")
    print()
    print("The Mac's listener and the shared pairing code path are both correct.")
    print("Remember to unpair 'pair-probe' from the Devices window.")
    exit(0)
} catch {
    print("FAIL: \(error)")
    print()
    print("This is the same code path the iOS app runs, so the fault is in the")
    print("Mac listener or in UpLinkKit — not in the phone's build.")
    exit(1)
}

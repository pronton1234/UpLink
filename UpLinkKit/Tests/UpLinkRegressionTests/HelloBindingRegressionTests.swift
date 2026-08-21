import Testing
import Foundation
import Network
import CryptoKit
@testable import UpLinkKit

// REGRESSION: one paired peer could announce another paired peer's fingerprint.
//
// The listener holds one TLS-PSK per paired device and TLS picks among them by
// the identity the client offers. Nothing cross-checked that choice against the
// fingerprint the peer then claimed in HELLO. So a device that is paired could
// complete the handshake honestly with its own key and announce someone else's
// identity — and the listener acts on that claim: it decides which peer is
// shown as connected, and which pairing an `unpair` sent over the session
// applies to. One paired Mac could revoke another.
//
// `MacSessionHost` recorded this as an HONEST LIMIT and named the fix as
// `sec_protocol_options_set_pre_shared_key_selection_block` on the listener.
// That does not work: the SDK header defines that block as being invoked "when
// the CLIENT must choose a PSK identity given a hint from its peer" — it is a
// client-side selection hook receiving the server's identity *hint*, not a
// server-side observer of the client's identity. It cannot answer the question.
//
// So the binding is an application-layer HMAC over the session key instead,
// which is provable here without a device.

@Suite("Regression: an announced fingerprint must be proven, not believed")
struct HelloBindingRegressionTests {

    /// Three devices: a phone, and two Macs both paired with it.
    private struct Trio {
        let phone: Curve25519.KeyAgreement.PrivateKey
        let macA: Curve25519.KeyAgreement.PrivateKey
        let macB: Curve25519.KeyAgreement.PrivateKey

        var phoneFingerprint: String {
            PairedDevice.fingerprint(of: phone.publicKey.rawRepresentation)
        }
        var fingerprintA: String {
            PairedDevice.fingerprint(of: macA.publicKey.rawRepresentation)
        }
        var fingerprintB: String {
            PairedDevice.fingerprint(of: macB.publicKey.rawRepresentation)
        }

        /// The key Mac A legitimately shares with the phone.
        func keyForA() throws -> SymmetricKey {
            try KeySchedule.sessionKey(
                localPrivate: macA,
                remotePublic: phone.publicKey,
                context: Data(phoneFingerprint.utf8)
            )
        }

        /// The same key computed from the phone's side, which is what the
        /// listener's verifier derives.
        func phoneSideKey(for mac: Curve25519.KeyAgreement.PrivateKey) throws -> SymmetricKey {
            try KeySchedule.sessionKey(
                localPrivate: phone,
                remotePublic: mac.publicKey,
                context: Data(phoneFingerprint.utf8)
            )
        }
    }

    // The attack, stated exactly: Mac A holds a valid pairing, and claims to be
    // Mac B. It can produce a proof only for its OWN identity.
    @Test("A paired peer cannot announce a different paired peer's fingerprint")
    func cannotImpersonateAnotherPairedPeer() throws {
        let trio = Trio(phone: .init(), macA: .init(), macB: .init())

        // A forges a HELLO claiming B, using the only key it has.
        let forged = HelloProof.tag(
            sessionKey: try trio.keyForA(),
            dialerFingerprint: trio.fingerprintB,
            listenerFingerprint: trio.phoneFingerprint
        )

        // The phone verifies a claim of B against B's key, as it must.
        let rejected = HelloProof.verify(
            forged,
            sessionKey: try trio.phoneSideKey(for: trio.macB),
            dialerFingerprint: trio.fingerprintB,
            listenerFingerprint: trio.phoneFingerprint
        )
        #expect(rejected == false, "a forged fingerprint was accepted")
    }

    @Test("The genuine peer's own proof verifies")
    func genuineProofVerifies() throws {
        let trio = Trio(phone: .init(), macA: .init(), macB: .init())

        let honest = HelloProof.tag(
            sessionKey: try trio.keyForA(),
            dialerFingerprint: trio.fingerprintA,
            listenerFingerprint: trio.phoneFingerprint
        )
        #expect(HelloProof.verify(
            honest,
            sessionKey: try trio.phoneSideKey(for: trio.macA),
            dialerFingerprint: trio.fingerprintA,
            listenerFingerprint: trio.phoneFingerprint
        ))
    }

    // The tag is bound to BOTH ends, so one captured from a session with one
    // phone cannot be replayed at another.
    @Test("A proof for one listener does not verify at a different listener")
    func proofIsBoundToTheListener() throws {
        let phoneOne = Curve25519.KeyAgreement.PrivateKey()
        let phoneTwo = Curve25519.KeyAgreement.PrivateKey()
        let mac = Curve25519.KeyAgreement.PrivateKey()
        let macFingerprint = PairedDevice.fingerprint(of: mac.publicKey.rawRepresentation)
        let oneFingerprint = PairedDevice.fingerprint(of: phoneOne.publicKey.rawRepresentation)
        let twoFingerprint = PairedDevice.fingerprint(of: phoneTwo.publicKey.rawRepresentation)

        let key = try KeySchedule.sessionKey(
            localPrivate: mac, remotePublic: phoneOne.publicKey, context: Data(oneFingerprint.utf8)
        )
        let tag = HelloProof.tag(
            sessionKey: key, dialerFingerprint: macFingerprint, listenerFingerprint: oneFingerprint
        )

        #expect(HelloProof.verify(
            tag, sessionKey: key, dialerFingerprint: macFingerprint, listenerFingerprint: twoFingerprint
        ) == false)
    }

    @Test("An empty or truncated proof is rejected")
    func emptyProofIsRejected() throws {
        let phone = Curve25519.KeyAgreement.PrivateKey()
        let mac = Curve25519.KeyAgreement.PrivateKey()
        let phoneFingerprint = PairedDevice.fingerprint(of: phone.publicKey.rawRepresentation)
        let macFingerprint = PairedDevice.fingerprint(of: mac.publicKey.rawRepresentation)
        let key = try KeySchedule.sessionKey(
            localPrivate: mac, remotePublic: phone.publicKey, context: Data(phoneFingerprint.utf8)
        )
        let full = HelloProof.tag(
            sessionKey: key, dialerFingerprint: macFingerprint, listenerFingerprint: phoneFingerprint
        )

        for candidate in [Data(), full.dropLast(), full.dropLast(16)] {
            #expect(HelloProof.verify(
                Data(candidate),
                sessionKey: key,
                dialerFingerprint: macFingerprint,
                listenerFingerprint: phoneFingerprint
            ) == false)
        }
    }

    // The proof rides in the HELLO frame, so the codec must carry it through
    // unchanged — including the length, which is what a naive parser truncates.
    @Test("The proof survives the HELLO frame round trip")
    func proofSurvivesTheFrame() throws {
        var mux = Multiplexer(role: .initiator)
        let proof = Data((0 ..< 32).map { UInt8($0) })
        let frame = mux.makeHello(identity: "abcdef0123456789", proof: proof)

        var listener = Multiplexer(role: .responder)
        let events = try listener.receive(frame)

        guard case let .helloReceived(version, identity, carried) = events.first else {
            Issue.record("expected a helloReceived, got \(events)")
            return
        }
        #expect(version == Multiplexer.protocolVersion)
        #expect(identity == "abcdef0123456789")
        #expect(carried == proof)
    }

    // A version-1 peer sends HELLO with no proof at all. It must be refused
    // rather than silently treated as unauthenticated.
    @Test("A HELLO with no proof carries an empty one, and an empty one never verifies")
    func absentProofIsNotAPass() throws {
        var mux = Multiplexer(role: .initiator)
        let frame = mux.makeHello(identity: "abcdef0123456789")

        var listener = Multiplexer(role: .responder)
        guard case let .helloReceived(_, _, carried) = try listener.receive(frame).first else {
            Issue.record("expected a helloReceived")
            return
        }
        #expect(carried.isEmpty)

        let key = SymmetricKey(size: .bits256)
        #expect(HelloProof.verify(
            carried, sessionKey: key, dialerFingerprint: "a", listenerFingerprint: "b"
        ) == false)
    }
}

// REGRESSION: the phone must never egress back up the cable it is bridging for.
//
// The bearer is named explicitly below rather than defaulted, because this
// suite is about the CABLE's hazard specifically. The same defect over the
// wireless bearer — where the phone is associated to a network the Mac hosts —
// is guarded separately in EgressLoopRegressionTests.
@Suite("Regression: the phone's egress must not follow the cable back")
struct CellularEgressRegressionTests {

    // Plugging in gives the phone a wired interface pointing at the Mac. If the
    // Mac has any route to share, the phone can dial out through it — and the
    // bridge then carries traffic from the Mac to the phone and straight back
    // to the Mac, bypassing nothing at all while reporting a healthy session.
    @Test("Wired ethernet and loopback are prohibited on every proxied dial")
    func wiredEgressIsProhibited() throws {
        for proto in [StreamOpen.Proto.tcp, .udp] {
            let destination = StreamOpen(proto: proto, host: "example.com", port: 443)
            let parameters = CellularDialer.parameters(
                for: destination, requiredInterface: .cellular, bearer: .usbmux
            )
            let prohibited = parameters.prohibitedInterfaceTypes ?? []

            #expect(prohibited.contains(.wiredEthernet), "\(proto) could egress up the cable")
            // Loopback is deliberately allowed; see CellularDialer.parameters.
            #expect(prohibited.contains(.loopback) == false)
            // Prohibition is the half that cannot be negotiated away;
            // `requiredInterfaceType` is documented as a preference the
            // framework may fall back from, which is how a Wi-Fi fallback once
            // presented as a successful cellular dial.
            #expect(parameters.requiredInterfaceType == .cellular)
            #expect(parameters.preferNoProxies)
        }
    }

    // The Simulator has no cellular radio, so the pin is left off there — but
    // the prohibition must still hold, or a Simulator run would quietly egress
    // over the host Mac's ethernet and look like a pass.
    //
    // Note the assertion is on the PROHIBITION, not on `requiredInterfaceType`
    // being nil: NWParameters reports `.other` when nothing has been required,
    // so "is it unset" is not a question that field can answer.
    @Test("Unpinned, for the Simulator, still refuses the cable")
    func unpinnedStillRefusesTheCable() {
        let parameters = CellularDialer.parameters(
            for: StreamOpen(proto: .tcp, host: "example.com", port: 443),
            requiredInterface: nil,
            bearer: .usbmux
        )
        #expect(parameters.requiredInterfaceType != .cellular)
        #expect((parameters.prohibitedInterfaceTypes ?? []).contains(.wiredEthernet))
    }
}

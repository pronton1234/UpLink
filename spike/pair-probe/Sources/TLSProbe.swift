import Foundation
import Network
import CryptoKit

// Isolates the TLS-PSK handshake from everything UpLinkKit wraps around it.
//
// The loopback pairing probe hangs with no error, which is what a handshake
// that never negotiates looks like. This narrows the question to one thing:
// with a given set of TLS options, do a listener and a client sharing one PSK
// actually reach .ready?

enum PSKVariant: String, CaseIterable {
    /// What the app shipped: TLS 1.3 floor, no explicit ciphersuite.
    case tls13Only
    /// Apple's own PSK sample configuration: a TLS 1.2 PSK ciphersuite,
    /// appended explicitly.
    case tls12PSKCiphersuite
    /// A TLS 1.3 floor *and* the PSK ciphersuite — does naming the suite
    /// rescue 1.3?
    case tls13PlusPSKCiphersuite
    /// A TLS 1.3 floor with a TLS 1.3 AEAD suite named explicitly.
    case tls13PlusAES128GCM
    /// No version floor and no ciphersuite: whatever the stack picks.
    case defaults
    /// The PSK suite with the floor left at the system default, but the
    /// ceiling pinned to 1.2 so negotiation cannot drift upward.
    case tls12PinnedPSKCiphersuite
    /// ECDHE-PSK with ChaCha20-Poly1305: AEAD *and* forward secrecy, which
    /// plain PSK suites do not provide.
    case ecdhePSKChaCha20
    /// ECDHE-PSK ChaCha20 pinned to 1.2, matching the pinning that made the
    /// plain PSK suite deterministic.
    case ecdhePSKChaCha20Pinned
    /// The strongest plain-PSK AEAD suite, as a fallback if ECDHE-PSK is not
    /// negotiable.
    case psk256GCM

    func options(psk: SymmetricKey, identity: String) -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        let keyData = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityData = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }

        sec_protocol_options_add_pre_shared_key(
            tls.securityProtocolOptions,
            keyData as __DispatchData,
            identityData as __DispatchData
        )

        let pskSuite = tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!

        switch self {
        case .tls13Only:
            sec_protocol_options_set_min_tls_protocol_version(
                tls.securityProtocolOptions, .TLSv13
            )
        case .tls12PSKCiphersuite:
            sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, pskSuite)
        case .tls13PlusPSKCiphersuite:
            sec_protocol_options_set_min_tls_protocol_version(
                tls.securityProtocolOptions, .TLSv13
            )
            sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, pskSuite)
        case .tls13PlusAES128GCM:
            sec_protocol_options_set_min_tls_protocol_version(
                tls.securityProtocolOptions, .TLSv13
            )
            sec_protocol_options_append_tls_ciphersuite(
                tls.securityProtocolOptions, .AES_128_GCM_SHA256
            )
        case .defaults:
            break
        case .tls12PinnedPSKCiphersuite:
            sec_protocol_options_set_max_tls_protocol_version(
                tls.securityProtocolOptions, .TLSv12
            )
            sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, pskSuite)
        case .ecdhePSKChaCha20:
            sec_protocol_options_append_tls_ciphersuite(
                tls.securityProtocolOptions,
                tls_ciphersuite_t(rawValue: UInt16(TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256))!
            )
        case .ecdhePSKChaCha20Pinned:
            sec_protocol_options_set_max_tls_protocol_version(
                tls.securityProtocolOptions, .TLSv12
            )
            sec_protocol_options_append_tls_ciphersuite(
                tls.securityProtocolOptions,
                tls_ciphersuite_t(rawValue: UInt16(TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256))!
            )
        case .psk256GCM:
            sec_protocol_options_set_max_tls_protocol_version(
                tls.securityProtocolOptions, .TLSv12
            )
            sec_protocol_options_append_tls_ciphersuite(
                tls.securityProtocolOptions,
                tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_256_GCM_SHA384))!
            )
        }
        return tls
    }
}

/// Brings up a listener and a client with the same PSK and reports whether the
/// connection reaches .ready within `timeout` seconds.
func probeTLS(variant: PSKVariant, timeout: Double = 6) async -> String {
    let psk = SymmetricKey(size: .bits256)
    let identity = "probe"
    let queue = DispatchQueue(label: "tls-probe.\(variant.rawValue)")

    let listenerParameters = NWParameters(
        tls: variant.options(psk: psk, identity: identity),
        tcp: NWProtocolTCP.Options()
    )
    listenerParameters.allowLocalEndpointReuse = true

    guard let listener = try? NWListener(using: listenerParameters) else {
        return "listener could not be created"
    }

    // Held so the inbound connection is not deallocated mid-handshake.
    let inbound = Box<NWConnection?>(nil)
    listener.newConnectionHandler = { connection in
        inbound.value = connection
        connection.start(queue: queue)
    }
    listener.start(queue: queue)

    for _ in 0 ..< 100 {
        if let port = listener.port, port.rawValue != 0 { break }
        try? await Task.sleep(for: .milliseconds(50))
    }
    guard let port = listener.port else { return "listener never bound" }
    defer { listener.cancel() }

    let clientParameters = NWParameters(
        tls: variant.options(psk: psk, identity: identity),
        tcp: NWProtocolTCP.Options()
    )
    let client = NWConnection(host: "127.0.0.1", port: port, using: clientParameters)
    defer { client.cancel() }

    let result = Box<String?>(nil)
    let signal = DispatchSemaphore(value: 0)
    client.stateUpdateHandler = { state in
        switch state {
        case .ready:
            if result.value == nil { result.value = "READY"; signal.signal() }
        case let .failed(error):
            if result.value == nil { result.value = "failed: \(error)"; signal.signal() }
        case let .waiting(error):
            if result.value == nil { result.value = "waiting: \(error)"; signal.signal() }
        default:
            break
        }
    }
    client.start(queue: queue)

    return await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            if signal.wait(timeout: .now() + timeout) == .timedOut {
                continuation.resume(returning: "HUNG — no state change in \(timeout)s")
            } else {
                continuation.resume(returning: result.value ?? "unknown")
            }
        }
    }
}

/// Minimal mutable holder for use inside escaping callbacks.
final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

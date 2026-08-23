import Foundation
import NetworkExtension
import UpLinkKit
import OSLog

/// Joins the Mac's network on the user's behalf.
///
/// **This is the difference between "a couple of button presses" and a trip to
/// Settings.** `NEHotspotConfiguration` lets the app associate to a named
/// network with a passphrase it already holds, so the user taps Connect and
/// nothing else.
///
/// The credentials come from pairing, over a channel TLS-PSK has already
/// authenticated, so the passphrase is never displayed or typed.
enum AccessPointJoin {

    private static let log = Logger(subsystem: UpLinkIdentifiers.logSubsystem, category: "join")

    enum Failure: Error, CustomStringConvertible {
        case denied
        case failed(String)

        var description: String {
            switch self {
            case .denied:
                "iPhone would not join the Mac's network — allow it when asked"
            case let .failed(reason):
                reason
            }
        }
    }

    /// Associates to the Mac's access point, returning once joined.
    ///
    /// `joinOnce` is false so iOS remembers the network and re-joins on its own
    /// next time the Mac is in range. That is the whole point: in the car this
    /// should require no interaction at all, and a join that had to be repeated
    /// by hand would put the friction straight back.
    /// Joins using only a passphrase.
    ///
    /// There is no SSID parameter because there is no SSID to pass: the match
    /// is on a fixed prefix, and the exact name is a thing neither device can
    /// learn. Taking a full credentials value here would mean constructing one
    /// with an empty name at every call site, which reads like an oversight.
    static func join(passphrase: String) async throws {
        try await join(AccessPointCredentials(
            ssid: AccessPointCredentials.ssidPrefix, passphrase: passphrase
        ))
    }

    static func join(_ credentials: AccessPointCredentials) async throws {
        // JOINED BY PREFIX, NOT BY EXACT NAME, and that is forced rather than
        // preferred.
        //
        // MEASURED 2026-08-20: the Mac's hosted network name cannot be set
        // programmatically. Writing NAT:AirPort:NetworkName is accepted and
        // ignored — the field read "UpLink-c743de63" while the radio broadcast
        // "UpLink-Spike" — and the live software-AP configuration lives in
        // com.apple.airport.preferences.plist, which SIP makes unreadable even
        // to root. So no amount of privilege lets the Mac tell the phone what
        // it is called.
        //
        // Prefix matching sidesteps the whole problem: the user names the
        // network once in System Settings, anything beginning with "UpLink"
        // matches, and the exact name never has to travel between the devices.
        let configuration = NEHotspotConfiguration(
            ssidPrefix: credentials.ssidPrefix,
            passphrase: credentials.passphrase,
            isWEP: false
        )
        configuration.joinOnce = false

        do {
            try await NEHotspotConfigurationManager.shared.apply(configuration)
            log.info("joined \(credentials.ssid, privacy: .public)")
        } catch let error as NSError {
            // "Already associated" is success wearing an error's clothes, and
            // treating it as a failure would make every reconnect look broken.
            // NAMED, not described. `localizedDescription` for this domain is
            // very often the empty string, which reached the diagnostic log as
            // "join FAILED: <unknown>" and said nothing at all — while the
            // phone silently stayed off the network and every downstream
            // symptom looked like an unreachable listener.
            let reason = Self.describe(error)
            if error.domain == NEHotspotConfigurationErrorDomain,
               error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
                // Logged as its own outcome. Treating it as success is right,
                // but it hid a real failure for an entire evening: every
                // "join: OK" was this, because the network had been joined by
                // hand, and the moment it was not the join failed outright.
                PhoneDiagnosticLog.shared.write("join: already associated")
                return
            }
            if error.domain == NEHotspotConfigurationErrorDomain,
               error.code == NEHotspotConfigurationError.userDenied.rawValue {
                throw Failure.denied
            }
            log.error("join failed: \(reason, privacy: .public)")
            throw Failure.failed(reason)
        }
    }

    /// Turns an `NEHotspotConfiguration` error into something worth reading.
    ///
    /// The framework's `localizedDescription` is frequently empty here, so the
    /// domain and code are spelled out and the known cases are named.
    private static func describe(_ error: NSError) -> String {
        guard error.domain == NEHotspotConfigurationErrorDomain else {
            let text = error.localizedDescription
            return text.isEmpty ? "\(error.domain) \(error.code)" : text
        }
        let name: String
        switch NEHotspotConfigurationError(rawValue: error.code) {
        case .invalidWPAPassphrase: name = "the network password is wrong"
        case .invalidSSID: name = "no network name matched"
        case .userDenied: name = "you declined the join"
        case .pending: name = "a join is already in progress"
        case .systemConfiguration: name = "iOS refused the configuration"
        case .unknown: name = "iOS reported an unspecified failure"
        case .joinOnceNotSupported: name = "joinOnce is not supported here"
        case .alreadyAssociated: name = "already on this network"
        case .applicationIsNotInForeground:
            name = "the app must be in the foreground to join"
        case .invalidSSIDPrefix: name = "the network-name prefix was rejected"
        default: name = "code \(error.code)"
        }
        return "\(name) [NEHotspotConfigurationError \(error.code)]"
    }

    /// Forgets the Mac's network.
    ///
    /// Bounded to our own SSID: this API can only remove configurations this
    /// app installed, but naming it explicitly keeps that true if the app ever
    /// installs more than one.
    static func leave(_ credentials: AccessPointCredentials) {
        leave()
    }

    /// Leaves the Mac's network, whatever it turned out to be called.
    ///
    /// **Asks iOS which networks we configured rather than guessing one.** The
    /// old version removed `credentials.ssid` — the name this app would have
    /// chosen — while the join matches a PREFIX, because the Mac's real network
    /// name cannot be set or read (see `join`). So it removed a network that
    /// was never joined and left the real one in place: the phone stayed on an
    /// access point with no internet behind it after the user pressed Stop,
    /// which is the worst state available, and it looked like Stop had done
    /// nothing.
    ///
    /// Every configured network carrying our prefix is removed, not just the
    /// first. Repeated joins under different names are exactly what this
    /// product produces.
    static func leave() {
        NEHotspotConfigurationManager.shared.getConfiguredSSIDs { ssids in
            let ours = ssids.filter { $0.hasPrefix(AccessPointCredentials.ssidPrefix) }
            guard !ours.isEmpty else {
                PhoneDiagnosticLog.shared.write("leave: nothing configured to remove")
                return
            }
            for ssid in ours {
                NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
            }
            PhoneDiagnosticLog.shared.write("leave: removed \(ours.joined(separator: ", "))")
        }
    }
}

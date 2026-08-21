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
            if error.domain == NEHotspotConfigurationErrorDomain,
               error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
                log.info("already on \(credentials.ssid, privacy: .public)")
                return
            }
            if error.domain == NEHotspotConfigurationErrorDomain,
               error.code == NEHotspotConfigurationError.userDenied.rawValue {
                throw Failure.denied
            }
            log.error("join failed: \(error.localizedDescription, privacy: .public)")
            throw Failure.failed(error.localizedDescription)
        }
    }

    /// Forgets the Mac's network.
    ///
    /// Bounded to our own SSID: this API can only remove configurations this
    /// app installed, but naming it explicitly keeps that true if the app ever
    /// installs more than one.
    static func leave(_ credentials: AccessPointCredentials) {
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: credentials.ssid)
    }
}

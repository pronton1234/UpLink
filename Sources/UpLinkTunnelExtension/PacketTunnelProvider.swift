import NetworkExtension
import Foundation
import CryptoKit
import OSLog
import UpLinkKit

/// Hosts the phone's side of the bridge.
///
/// **The phone listens now.** `usbmuxd` carries connections in one direction
/// only — the Mac dials a port on the device — so the roles that held over AWDL
/// are reversed. This extension binds `127.0.0.1:UpLinkUSB.extensionPort` and
/// waits; the Mac's menu-bar app pumps the cable into it.
///
/// It still routes nothing. `includedRoutes = []` and the default route
/// explicitly excluded: this is a process host, not a capture mechanism. We are
/// proxying the *Mac's* traffic, not this phone's. What the packet tunnel buys
/// is survival — the extension keeps running while the phone is locked and the
/// app is backgrounded, which a foreground app cannot do and which is the whole
/// reason the listener lives here rather than in the app.
///
/// Unlike the Mac's system extension, this one CAN reach the keychain: on iOS
/// an app extension shares the app's `keychain-access-groups`, and the items
/// are stored `kSecAttrAccessibleAfterFirstUnlock` so they are readable while
/// locked. So there is no seeding dance and no polling merge here — the
/// extension and the app read and write the same durable store.
final class PacketTunnelProvider: NEPacketTunnelProvider {

    private let log = Logger(subsystem: UpLinkIdentifiers.logSubsystem, category: "tunnel")

    /// The phone's own account of what happened, readable without a cable.
    ///
    /// Kept even though the cable is now always present — reading the unified
    /// log needs the device unlocked and a `devicectl` session, and the whole
    /// point of the Diagnostics screen is that the user can read it themselves.
    private let diagnostics = PhoneDiagnosticLog.shared
    private let queue = DispatchQueue(label: "com.uplink.app.tunnel")
    private let store = PairedDeviceStore()

    /// All mutable state, behind an actor.
    ///
    /// `NEPacketTunnelProvider` is not `Sendable`, so a `Task` that touches a
    /// stored property on `self` is a data race the compiler rejects. Keeping
    /// the state here rather than on the provider is what makes every callback
    /// below expressible at all.
    private let bridge = PhoneBridge()

    // Completion-handler form rather than the async override: the async
    // variant receives a non-Sendable `[String: NSObject]?` across an isolation
    // boundary, which Swift 6 rejects.
    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        log.error("startTunnel")
        diagnostics.write("=== startTunnel (diagnostic log available: \(PhoneDiagnosticLog.shared.isAvailable)) ===")

        // Route-less settings. See the type's note: this is a process host.
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.55.0.2"], subnetMasks: ["255.255.255.255"])
        ipv4.includedRoutes = []                       // capture nothing
        ipv4.excludedRoutes = [NEIPv4Route.default()]  // and explicitly exclude everything
        settings.ipv4Settings = ipv4
        settings.mtu = 1500

        // NO CONFIGURATION IS REQUIRED TO START, and that is deliberate.
        //
        // The tunnel used to refuse to start without a paired Mac in its
        // provider configuration. That is now a deadlock: the Mac dials, so
        // something must already be listening on this phone before the first
        // pairing can happen — and nothing could be, because there was no
        // pairing yet. An unpaired phone listens and refuses every handshake,
        // which is exactly the right behaviour and is what
        // `TransportParameters.listenerKeySet`'s placeholder key exists for.
        let identity: Curve25519.KeyAgreement.PrivateKey
        do {
            identity = try store.loadOrCreateIdentity()
        } catch {
            log.error("no device identity: \(String(describing: error), privacy: .public)")
            diagnostics.write("FAILED to load a device identity: \(error)")
            completionHandler(BridgeStartupError.notConfigured)
            return
        }

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error {
                completionHandler(error)
                return
            }
            guard let self else {
                completionHandler(BridgeStartupError.notConfigured)
                return
            }
            let bridge = self.bridge
            let store = self.store
            let queue = self.queue
            let done = UncheckedSendableBox(completionHandler)
            Task {
                do {
                    try await bridge.start(identity: identity, store: store, queue: queue)
                    done.value(nil)
                } catch {
                    done.value(error)
                }
            }
        }
    }


    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        log.error("stopTunnel: \(String(describing: reason), privacy: .public)")
        diagnostics.write("stopTunnel: \(reason)")
        let done = UncheckedSendableBox(completionHandler)
        let bridge = self.bridge
        Task {
            await bridge.stop()
            done.value()
        }
    }

    /// Requests from the containing app.
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let request = String(data: messageData, encoding: .utf8) else {
            completionHandler?(nil)
            return
        }
        let reply = UncheckedSendableBox(completionHandler)

        // Arming the listener with a pairing code.
        //
        // The user reads six digits off the MAC and types them here; that is
        // what puts the matching PSK into this listener's TLS options so the
        // Mac's dial can succeed. Who displays and who types is independent of
        // who dials, so this half of the flow is unchanged from the user's
        // point of view even though the transport reversed underneath it.
        if request.hasPrefix("pair:") {
            let digits = String(request.dropFirst("pair:".count))
            let bridge = self.bridge
            Task { reply.value?(Data(await bridge.setPairingCode(digits).utf8)) }
            return
        }

        // Forgetting a Mac must reach that Mac.
        //
        // `unpair:<fingerprint>` names which one. Acting on whichever session
        // happens to be live is how deleting one Mac could revoke another.
        if request.hasPrefix("unpair") {
            let wanted = request.hasPrefix("unpair:")
                ? String(request.dropFirst("unpair:".count))
                : nil
            let bridge = self.bridge
            Task { reply.value?(Data(await bridge.unpair(wanted).utf8)) }
            return
        }

        switch request {
        case "diagnostics":
            // Answered synchronously: it is a file read, and the point is to be
            // able to get it out even when the session machinery is wedged.
            //
            // The header is not padding. Last time this produced nothing, the
            // question "did the extension never run, or did it run and fail to
            // write?" could not be answered — and those have completely
            // different fixes.
            let log = PhoneDiagnosticLog.shared
            var report = "extension running, pid \(ProcessInfo.processInfo.processIdentifier)\n"
            report += "log available: \(log.isAvailable)\n"
            if !log.diagnosis.isEmpty { report += "log unavailable because: \(log.diagnosis)\n" }
            report += "listening on 127.0.0.1:\(UpLinkUSB.extensionPort) (\(UpLinkUSB.describe(port: UpLinkUSB.extensionPort)))\n"
            report += "---\n"
            report += log.contents()
            completionHandler?(Data(report.utf8))

        case "status":
            let bridge = self.bridge
            Task { reply.value?(Data(await bridge.status().utf8)) }

        default:
            completionHandler?(nil)
        }
    }

    /// The name the Mac shows for this phone.
    ///
    /// `UIDevice.name` is gated behind an entitlement since iOS 16 and returns
    /// a generic model string without it, so it is not worth reaching for from
    /// an extension. `PairingClient.defaultDeviceName` is the same value the
    /// pairing handshake would have sent, which keeps the two consistent.
    static func deviceName() -> String {
        PairingClient.defaultDeviceName
    }
}

/// Everything mutable about the phone's side of the bridge.
///
/// An actor, because `NEPacketTunnelProvider` is not `Sendable` and every entry
/// point here is a framework callback that hands work to a `Task`. Holding the
/// state on the provider would be a data race the compiler rejects — the same
/// reason the old dialling code kept its state in `PhoneSessionState`.
actor PhoneBridge {

    private let log = Logger(subsystem: UpLinkIdentifiers.logSubsystem, category: "tunnel")
    private let diagnostics = PhoneDiagnosticLog.shared

    private var host: PhoneSessionHost?
    private var store: PairedDeviceStore?
    private var eventTask: Task<Void, Never>?

    /// Carries "the Mac has forgotten this phone" to the app's next poll.
    /// Sticky across the session ending, and cleared when a new session is
    /// established — see ``UnpairNotice`` for why both halves matter.
    private let unpaired = UnpairNotice()

    func start(
        identity: Curve25519.KeyAgreement.PrivateKey,
        store: PairedDeviceStore,
        queue: DispatchQueue
    ) async throws {
        self.store = store
        let host = PhoneSessionHost(
            identity: identity,
            deviceName: PacketTunnelProvider.deviceName(),
            store: store,
            // Where traffic actually leaves the phone: an ordinary app socket
            // pinned to the cellular radio, so the carrier sees app data.
            dialer: CellularDialer(queue: queue, requiredInterface: .cellular),
            queue: queue,
            port: UpLinkUSB.extensionPort,
            // So a Mac revoked while it was unplugged is still told after this
            // extension is relaunched — which iOS does often.
            tombstoneStore: TombstoneStore()
        )
        self.host = host

        let events = await host.events()
        eventTask = Task { [weak self] in
            for await event in events { await self?.handle(event) }
        }

        do {
            try await host.start()
        } catch {
            log.error("listener failed to start: \(String(describing: error), privacy: .public)")
            diagnostics.write("listener FAILED to start: \(error)")
            throw error
        }
        diagnostics.write("listening on 127.0.0.1:\(UpLinkUSB.extensionPort) — waiting for the Mac to dial over the cable")
    }

    func stop() async {
        eventTask?.cancel()
        eventTask = nil
        await host?.stop()
        host = nil
    }

    private func handle(_ event: SessionHostEvent) async {
        switch event {
        case let .sessionStarted(fingerprint, peerDescription):
            // A peer accepting our handshake is proof the pairing is live, so
            // any earlier revocation is stale. Without this the app's first
            // poll after a re-pair deletes the pairing it just made.
            await unpaired.sessionEstablished()
            log.error("session started with \(fingerprint, privacy: .public) from \(peerDescription, privacy: .public)")
            // The endpoint in this line is how a device run tells the cable
            // apart from anything else. Over usbmux it reads as loopback,
            // because the Mac's relay is what dialled us — an `awdl0` or a
            // global address here would mean the wired path is not being used.
            diagnostics.write("session started with \(fingerprint) — accept: \(peerDescription)")

        case let .sessionEnded(fingerprint):
            log.error("session ENDED with \(fingerprint, privacy: .public)")
            diagnostics.write("session ENDED with \(fingerprint)")

        case let .peerUnpaired(fingerprint):
            await unpaired.note(fingerprint: fingerprint)
            diagnostics.write("the Mac \(fingerprint) unpaired us")

        case let .paired(device):
            diagnostics.write("paired with \(device.name) (\(device.fingerprint))")

        case let .egressObserved(interface):
            diagnostics.write("egress: \(interface.displayName)")

        case let .failed(message):
            log.error("host FAILED: \(message, privacy: .public)")
            diagnostics.write("host FAILED: \(message)")
        }
    }

    func setPairingCode(_ digits: String) async -> String {
        do {
            if digits == "off" {
                try await host?.setPairingCode(nil)
            } else {
                try await host?.setPairingCode(try PairingCode(digits: digits))
            }
            return "ok"
        } catch {
            return "error|\(error)"
        }
    }

    /// Forgetting a Mac must reach that Mac.
    ///
    /// Announce over the live session, then tear down: the other order
    /// guarantees the notice is never delivered, since it travels on the
    /// connection being closed.
    func unpair(_ wanted: String?) async -> String {
        let live = await host?.activeFingerprint

        // THE GUARD ONLY GATES THE TEARDOWN, NOT THE REMOVAL.
        //
        // It used to return "wrong-peer" outright, which was fine while the app
        // only sent this message for the live device. Now that it always sends
        // it — because removing a Mac that is NOT connected is exactly the case
        // that needs a tombstone — returning early meant removing Mac B while
        // Mac A was bridging did nothing at all: no removal, no tombstone, no
        // rebuild, so B was never told and the listener went on offering B's
        // key. That is the case this whole path exists for, broken whenever any
        // other Mac happened to be live.
        let isLivePeer = wanted != nil && wanted == live
        if isLivePeer {
            // Announce over the session, THEN tear down: the notice travels on
            // the connection being closed, so the other order never delivers it.
            await host?.announceUnpaired()
            await host?.endSession()
        } else if let wanted, live != nil {
            log.error("ipc: unpairing \(wanted, privacy: .public) while \(live ?? "?", privacy: .public) is live — the session stays up")
        }
        if let wanted, let store {
            // Captured BEFORE the removal: the tombstone needs the public key,
            // which is the only way that Mac can still reach us to be told.
            let removed = (try? store.pairedDevices())?.first { $0.fingerprint == wanted }
            try? store.remove(fingerprint: wanted)
            if let removed {
                if isLivePeer {
                    // Told directly over the session above, so no tombstone is
                    // needed — but the listener must still stop offering its
                    // key, and only a rebuild re-reads the key set.
                    await host?.rebuildAfterRemoval(of: wanted)
                } else {
                    // Nothing carried the notice. Keep its key on the air just
                    // long enough for its next dial to be told. `revoke`
                    // rebuilds the listener itself.
                    await host?.revoke(removed)
                }
            }
        }
        return "ok"
    }

    func status() async -> String {
        // Checked before anything else, and consumed by the read.
        if let fingerprint = await unpaired.take() {
            return "unpaired|\(fingerprint)"
        }
        guard let host, let fingerprint = await host.activeFingerprint else {
            return "disconnected"
        }
        // A real observation, not an assumption of cellular. Same shape the
        // Mac's proxy extension uses, so both UIs read the truth.
        let egress = await host.responder?.observedEgress ?? .unknown
        return "connected|\(fingerprint)|\(egress.rawValue)"
    }
}

/// Carries a non-`Sendable` value into a task.
///
/// NetworkExtension's completion handlers predate strict concurrency and are
/// not annotated `@Sendable`, yet the framework's own contract is simply that
/// each is invoked exactly once — which is what the call sites here do.
struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

enum BridgeStartupError: Error {
    case notConfigured
}

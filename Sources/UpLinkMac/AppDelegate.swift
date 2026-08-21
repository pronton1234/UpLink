import AppKit
import SwiftUI
import Network
import UserNotifications
import OSLog
import UpLinkKit

/// The Mac's entry point.
///
/// Everything here is passive by design. The app launches at login, installs
/// its status item, advertises itself, and waits — the user drives every
/// session from their phone, so the Mac never needs to be touched. That is the
/// whole of the "works completely backgrounded" requirement on this side.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let log = Logger(subsystem: UpLinkIdentifiers.logSubsystem, category: "app")

    private var statusItem: NSStatusItem?
    private var devicesWindow: NSWindow?

    private let model = MenuBarModel()
    private let accessPoint = AccessPointHost()
    private var beacon: AccessPointBeacon?
    /// Last known access-point state, refreshed off the main thread. The menu
    /// is rebuilt on every open, and asking the helper synchronously there
    /// would block the menu on an XPC round trip.
    private var accessPointIsUp = false
    private var accessPointBusy = false

    static func main() {
        let delegate = AppDelegate()
        NSApplication.shared.delegate = delegate
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        requestNotificationPermission()

        // Idempotent, so it is safe on every launch. The user approves the
        // helper once, in the same System Settings panel that already approves
        // the network extension — one more switch in a flow that already has
        // one, rather than a new kind of ceremony.
        //
        // Registering does not raise the access point. That is deliberate:
        // installing the app should not silently take over the Wi-Fi radio.
        accessPoint.register()
        // Before anything asks the helper to do work, make sure it is the
        // helper this build shipped. See `replaceIfStale`.
        Task { @MainActor in
            await accessPoint.replaceIfStale()
            refreshAccessPointState()
            hostAccessPointIfNeeded()
        }

        // THE NETWORK IS ALWAYS UP, and that is the design rather than a
        // convenience. The phone cannot ask the Mac to start hosting, because
        // asking requires the very network that is not up yet — so a Mac that
        // waits to be asked can never be reached, and every session begins with
        // the user walking to the laptop, which is the friction this product
        // exists to remove.
        //
        // The Mac does not sleep and has no other network to return to, so
        // there is nothing being taken away by hosting continuously. Stopping
        // stays available in the menu for when the user genuinely wants the
        // radio back.
        startBeaconUnlessItCrashedLastTime()

        // TELLING THE EXTENSION WHERE THE PHONE IS, which is a different job
        // from hosting and must not share a timer with it again.
        //
        // These two lived in one block, and deleting that block to stop the
        // access point being re-raised on a schedule silently took this with
        // it. The Mac then never announced a peer, so the extension never
        // dialled, so there was no session, so the proxy claimed no flows and
        // every packet fell into the dead-end route tunnel — "route: packets
        // 101 — flows the proxy did NOT claim". The bridge looked connected
        // from the phone and carried nothing.
        //
        // This one is safe to repeat where the other was not: it sends an IPC
        // message naming an address, and the extension ignores a repeat of what
        // it is already dialling. Nothing is torn down and rebuilt.
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshAccessPointState()
                await self.model.announcePeerIfPossible()
            }
        }
    }

    /// Starts the Bluetooth doorbell, at most once per build if it aborts.
    ///
    /// **A TCC abort cannot be caught.** Creating a `CBPeripheralManager` here
    /// once killed the process at launch — SIGABRT, "must contain an
    /// NSBluetoothAlwaysUsageDescription key" — with that key present in the
    /// installed Info.plist, the signature valid, nothing for `tccutil` to
    /// reset, and a clean reinstall making no difference. Whatever the cause,
    /// the failure mode is fatal and silent, and an app that dies at launch has
    /// no menu bar, hosts nothing, and announces no peer: every symptom then
    /// looks like a bridge fault. An hour was spent there.
    ///
    /// So the attempt is recorded before it is made and confirmed after it
    /// succeeds. A build that crashed on its last attempt does not try again —
    /// the doorbell is lost, which costs "start the Mac from the phone", and
    /// the app runs, which costs nothing. One crash is a fact to investigate;
    /// a crash loop is a machine that cannot be used.
    private func startBeaconUnlessItCrashedLastTime() {
        let defaults = UserDefaults.standard
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"

        if defaults.string(forKey: "UpLinkBeaconAttempted") == build,
           defaults.string(forKey: "UpLinkBeaconSurvived") != build {
            logAccessPoint.error("beacon aborted on its last attempt in this build — not retrying")
            return
        }

        // Written and flushed BEFORE the risky call, because the process may
        // not survive to write anything afterwards.
        defaults.set(build, forKey: "UpLinkBeaconAttempted")
        defaults.removeObject(forKey: "UpLinkBeaconSurvived")
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)

        startBeacon()

        // Reaching here means CoreBluetooth was constructed without aborting.
        defaults.set(build, forKey: "UpLinkBeaconSurvived")
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
    }


    // MARK: The doorbell

    /// Publishes the Bluetooth control channel the phone uses to start us.
    ///
    /// This is what makes the whole thing work from the phone alone. Everything
    /// else the phone needs travels over the access point, and the access point
    /// is the one thing that cannot be asked for that way.
    private func startBeacon() {
        let beacon = AccessPointBeacon(
            onCommand: { [weak self] command in
                guard let self else { return }
                switch command {
                case .raiseAccessPoint:
                    // Clears an earlier Stop: the phone asking is unambiguously
                    // "host again", and refusing on the strength of a switch
                    // flipped hours ago would be the wrong kind of loyalty.
                    accessPointStoppedByUser = false
                    hostAccessPointIfNeeded()
                case .lowerAccessPoint:
                    guard accessPointIsUp else { return }
                    toggleAccessPoint()
                }
            },
            accessPointIsUp: { TransportParameters.hostedNetworkAddress() != nil }
        )
        beacon.start()
        self.beacon = beacon

        // Quiet while a bridge is live. Nothing needs the doorbell once the
        // door is open.
        model.observe { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                beacon.setSessionLive(self.model.status.isConnected)
            }
        }
    }

    // MARK: The access point

    /// Brings the network up unless the user switched it off by hand.
    ///
    /// Deliberately not the same thing as `toggleAccessPoint`: this one never
    /// takes the radio back from a user who asked for it, which is the
    /// difference between a product that heals itself and one that fights you.
    private func hostAccessPointIfNeeded() {
        guard !accessPointStoppedByUser, !accessPointBusy else { return }
        // NEVER while a session is live. Raising re-applies the Internet
        // Sharing configuration, which restarts the access point and drops
        // every client on it — so a re-host during a working bridge does not
        // repair anything, it destroys the thing it was meant to protect.
        guard !model.status.isConnected else { return }
        if let lastRaise, Date().timeIntervalSince(lastRaise) < Self.raiseCooldown {
            // Observed 00:14:33 and 00:14:37 — two raises four seconds apart,
            // each restarting sharing, so the access point never had time to
            // finish coming up before it was torn down again.
            logAccessPoint.error("access point was raised recently — not raising again yet")
            return
        }
        Task { @MainActor in
            guard await !accessPoint.isUp() else {
                if !accessPointIsUp { accessPointIsUp = true; refreshStatusItem() }
                return
            }

            // NO "IS IT REALLY DOWN?" CHECK ANY MORE, and removing it was
            // required rather than tidy.
            //
            // It existed to stop the periodic re-host from acting on a blip —
            // the access point flaps briefly when the first client associates.
            // With the timer gone, both remaining callers are somebody asking:
            // the app launching, and the phone pressing Connect. Making a
            // person ask twice is not caution, it is a bug, and this guard
            // would have silently stopped the Mac hosting at launch at all.
            accessPointBusy = true
            lastRaise = Date()
            refreshStatusItem()
            let failure = await accessPoint.raise()
            accessPointBusy = false
            if let failure {
                // Not an alert. This runs unattended and on a timer; a modal
                // every thirty seconds would be worse than the fault.
                logAccessPoint.error("auto-host failed: \(failure, privacy: .public)")
            }
            await settle(expecting: true)
        }
    }

    private let logAccessPoint = Logger(subsystem: UpLinkIdentifiers.logSubsystem, category: "ap")
    /// Set only by an explicit Stop, so automatic hosting never overrides a
    /// deliberate choice.
    private var accessPointStoppedByUser = false
    /// When the access point was last asked to come up.
    ///
    /// Raising is not idempotent: it re-applies the sharing configuration and
    /// macOS rebuilds the access point from scratch, dropping every client. So
    /// two raises close together are strictly worse than one, and there are now
    /// three callers — the launch, the timer, and the phone's doorbell — that
    /// can all fire within seconds of each other.
    private var lastRaise: Date?
    /// Long enough to cover a raise actually completing: measured at about ten
    /// seconds from the helper being asked to `bridge100` appearing, with the
    /// interface settling for a few seconds after that.
    private static let raiseCooldown: TimeInterval = 45

    /// Raises or lowers the Mac's network.
    ///
    /// Hosting takes the Wi-Fi radio, so this is never done implicitly — not on
    /// launch, not on pairing. It is one deliberate action with one obvious
    /// inverse, which is the same rule Disconnect had to learn: an action with
    /// no inverse in the UI is a bug, not a missing feature.
    @objc private func toggleAccessPoint() {
        guard !accessPointBusy else { return }
        let wasUp = accessPointIsUp
        // Remembered, so the thirty-second re-host does not undo a Stop the
        // user just asked for.
        accessPointStoppedByUser = wasUp
        accessPointBusy = true
        refreshStatusItem()

        Task { @MainActor in
            let failure = wasUp ? await accessPoint.lower() : await accessPoint.raise()
            accessPointBusy = false

            if let failure {
                // Said out loud rather than logged and swallowed. "Not
                // bridging" with no cause is the failure LinkStatus exists to
                // prevent, and this is the one cause the user can act on.
                let alert = NSAlert()
                alert.messageText = wasUp
                    ? "Could not stop the UpLink network"
                    : "Could not start the UpLink network"
                alert.informativeText = failure
                alert.runModal()
            }

            // Read back from the interfaces rather than assuming the call did
            // what it said. The preference file is input, not output, and has
            // been observed disagreeing with what is actually running.
            //
            // AND WAIT FOR IT. Measured on hardware 2026-08-20: the helper
            // returns as soon as configd accepts the change, but `bridge100`
            // took a further EIGHT SECONDS to appear (raise logged at
            // 20:53:36, address at 20:53:44). Reading once, immediately, always
            // saw "down" — so the menu kept offering Start for a network that
            // was already up, and the logs show it being clicked five times.
            await settle(expecting: !wasUp)
        }
    }

    /// Polls until the access point reaches the expected state, or gives up.
    ///
    /// Gives up rather than waiting forever, and shows whatever is true when it
    /// does: a button stuck on "Working…" is worse than one that admits the
    /// state it can actually see.
    private func settle(expecting expected: Bool) async {
        for _ in 0 ..< 20 {
            let up = await accessPoint.isUp()
            if up != accessPointIsUp {
                accessPointIsUp = up
                refreshStatusItem()
            }
            if up == expected { return }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Asks for the password the user set on the network in System Settings.
    ///
    /// It cannot be discovered. `com.apple.airport.preferences.plist` holds the
    /// live software-AP configuration and SIP makes it unreadable even to root,
    /// so there is no privilege level at which the Mac can look this up. The
    /// phone needs it to join, so someone has to say it once — and once is the
    /// whole of it, because it is stored and travels over the pairing channel
    /// from then on.
    @objc private func setNetworkPassword() {
        let alert = NSAlert()
        alert.messageText = "UpLink network password"
        alert.informativeText =
            "Type the password you set for Internet Sharing in System Settings → "
            + "General → Sharing → Internet Sharing → Wi-Fi Options.\n\n"
            + "macOS does not let any app read it, so UpLink cannot find it for you. "
            + "Your iPhone needs it to join the network on its own."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = accessPoint.credentials.passphrase
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let typed = field.stringValue
        // WPA2 refuses anything outside 8...63 characters, and it refuses it
        // deep inside Internet Sharing rather than here — so it is caught here.
        guard (8 ... 63).contains(typed.count) else {
            let problem = NSAlert()
            problem.messageText = "That password will not work"
            problem.informativeText =
                "A Wi-Fi password has to be between 8 and 63 characters. "
                + "That is a WPA2 rule, not UpLink's."
            problem.runModal()
            return
        }
        accessPoint.setPassphrase(typed)
    }

    private func refreshAccessPointState() {
        Task { @MainActor in
            let up = await accessPoint.isUp()
            guard up != accessPointIsUp else { return }
            accessPointIsUp = up
            refreshStatusItem()
        }
    }

    // MARK: Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Template image so the system tints it correctly for light, dark, and
        // selected menu bars, per the HIG.
        let image = NSImage(systemSymbolName: "personalhotspot", accessibilityDescription: "UpLink")
        image?.isTemplate = true
        item.button?.image = image
        item.menu = buildMenu()
        statusItem = item
    }

    private func refreshStatusItem() {
        statusItem?.menu = buildMenu()
        // Reflect a degraded bridge in the menu bar itself, not just inside the
        // menu — the user should not have to open it to find out.
        // The glyph distinguishes "no cable" from "cable, something else
        // wrong", because those need different things from the user and the
        // whole point of a menu bar icon is to answer at a glance.
        let symbol: String
        switch model.status {
        case .connected(_, .cellular): symbol = "personalhotspot"
        case .connected: symbol = "exclamationmark.triangle"
        case .accessPointDown: symbol = "wifi.slash"
        case .waitingForPhone: symbol = "wifi"
        case .waitingForCable: symbol = "cable.connector.slash"
        case .deviceNotResponding, .deviceNotPaired: symbol = "cable.connector"
        case .connecting: symbol = "cable.connector"
        case .pairingLost: symbol = "exclamationmark.triangle"
        case .failed, .needsApproval: symbol = "exclamationmark.triangle"
        case .switchedOff: symbol = "personalhotspot.slash"
        case .installingExtension: symbol = "personalhotspot.slash"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "UpLink")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    /// A menu, not a popover — the HIG is explicit about this for menu bar
    /// extras, and anything that genuinely needs richer UI lives in the
    /// Devices window instead.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: model.statusHeadline, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if let detail = model.statusDetail {
            let item = NSMenuItem(title: detail, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.attributedTitle = NSAttributedString(
                string: detail,
                attributes: [
                    .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            )
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // Disconnect needs an inverse. Without one it was a one-way door: the
        // only route back to a working bridge was to unplug the cable and plug
        // it in again, which nothing on screen suggested.
        if model.userDisconnected {
            menu.addItem(
                NSMenuItem(title: "Reconnect", action: #selector(reconnect), keyEquivalent: "")
            )
        } else if model.status.isConnected {
            menu.addItem(
                NSMenuItem(title: "Disconnect", action: #selector(disconnect), keyEquivalent: "")
            )
        }

        // The access point is the one thing in this menu the user can act on
        // that is not about the phone. It is listed first for that reason:
        // with the network down, nothing else in here can work.
        let apTitle: String
        if accessPointBusy {
            apTitle = "Working…"
        } else if accessPointIsUp {
            apTitle = "Stop “\(accessPoint.credentials.ssid)”"
        } else {
            apTitle = "Start “\(accessPoint.credentials.ssid)”"
        }
        let apItem = NSMenuItem(
            title: apTitle, action: #selector(toggleAccessPoint), keyEquivalent: ""
        )
        apItem.isEnabled = !accessPointBusy
        menu.addItem(apItem)

        // The password cannot be read from the system either — same protected
        // store as the name — so it is asked for once rather than guessed at.
        menu.addItem(NSMenuItem(
            title: "Set Network Password…", action: #selector(setNetworkPassword), keyEquivalent: ""
        ))

        menu.addItem(.separator())

        let codeItem = NSMenuItem(
            title: "Show Pairing Code…", action: #selector(showPairingCode), keyEquivalent: ""
        )
        menu.addItem(codeItem)

        menu.addItem(
            NSMenuItem(title: "Devices…", action: #selector(showDevices), keyEquivalent: ",")
        )

        menu.addItem(.separator())

        // The privacy badge from the spec: a plain statement, always visible.
        let privacy = NSMenuItem(title: "Traffic is routed locally to your iPhone only", action: nil, keyEquivalent: "")
        privacy.isEnabled = false
        privacy.attributedTitle = NSAttributedString(
            string: "Routed locally to your iPhone — no servers involved",
            attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
        )
        menu.addItem(privacy)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit UpLink", action: #selector(quit), keyEquivalent: "q"))

        for item in menu.items where item.action != nil {
            item.target = self
        }
        return menu
    }

    // MARK: Actions

    @objc private func reconnect() {
        model.reconnect()
    }

    @objc private func disconnect() {
        model.disconnect()
    }

    @objc private func showPairingCode() {
        model.beginPairing()
        showDevices()
    }

    @objc private func showDevices() {
        if devicesWindow == nil {
            let hosting = NSHostingController(rootView: DevicesView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "UpLink"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 460, height: 420))
            window.isReleasedWhenClosed = false
            window.center()
            devicesWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        devicesWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        model.stop()
        NSApplication.shared.terminate(nil)
    }

    // MARK: Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
            if let error { self.log.error("notification auth: \(error.localizedDescription, privacy: .public)") }
            else { self.log.info("notification auth granted: \(granted)") }
        }
    }

    /// Told once when the cable comes out mid-session.
    ///
    /// Replaces the Wi-Fi watchdog, which warned that Wi-Fi had been available
    /// for two minutes and it was time to stop draining the phone. That advice
    /// no longer applies: the bridge runs over the cable, which is also
    /// charging the phone, so there is nothing to preserve by disconnecting.
    /// What the user does need telling is the opposite — the link they were
    /// using has physically gone.
    private func notifyCableRemoved() {
        let content = UNMutableNotificationContent()
        content.title = "iPhone disconnected"
        content.body = "UpLink stopped bridging when the cable came out."
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: "uplink.cable-removed",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

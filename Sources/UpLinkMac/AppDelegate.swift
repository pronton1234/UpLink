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
        refreshAccessPointState()

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
        hostAccessPointIfNeeded()

        // Also on a timer: the access point can go down for reasons of its own
        // — a reboot, a network change, someone switching it off in System
        // Settings — and a Mac in the back of a car cannot be asked to notice.
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.hostAccessPointIfNeeded() }
        }

        model.onCableRemoved = { [weak self] in
            self?.notifyCableRemoved()
        }

        model.observe { [weak self] in
            Task { @MainActor in self?.refreshStatusItem() }
        }

        model.start()

        // The access point can be turned on or off in System Settings without
        // us, and a menu still offering "Start" for a running network is how
        // the user ends up clicking it five times. Cheap enough to just ask.
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAccessPointState()
                // The phone can join at any moment, and joining is the only
                // signal that it is reachable. Re-announcing is idempotent —
                // the extension ignores a repeat of what it is already dialling.
                await self?.model.announcePeerIfPossible()
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
        Task { @MainActor in
            guard await !accessPoint.isUp() else {
                if !accessPointIsUp { accessPointIsUp = true; refreshStatusItem() }
                return
            }
            accessPointBusy = true
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

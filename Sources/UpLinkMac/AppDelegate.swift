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

    static func main() {
        let delegate = AppDelegate()
        NSApplication.shared.delegate = delegate
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        requestNotificationPermission()

        model.onCableRemoved = { [weak self] in
            self?.notifyCableRemoved()
        }

        model.observe { [weak self] in
            Task { @MainActor in self?.refreshStatusItem() }
        }

        model.start()
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

import SwiftUI
import UpLinkKit

@main
struct UpLinkApp: App {
    @State private var controller = BridgeController()

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
        }
    }
}

/// The main screen.
///
/// Deliberately one decision per screen. The HIG's onboarding guidance is to
/// defer non-essential configuration and let people act immediately, so there
/// is no setup wizard: the primary control is visible on launch, and the VPN
/// permission prompt appears at the moment the user first asks to connect —
/// where its purpose is obvious — rather than on a cold splash screen.
struct ContentView: View {

    @Environment(\.scenePhase) private var scenePhase

    @Bindable var controller: BridgeController

    var body: some View {
        NavigationStack {
            ZStack {
                backgroundGradient.ignoresSafeArea()

                VStack(spacing: 28) {
                    Spacer(minLength: 12)
                    StatusDial(state: controller.state)
                    StatusCaption(state: controller.state)
                    Spacer(minLength: 0)
                    primaryControl
                    peerSection
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            // No navigation title: the status dial already says what this
            // screen is, and a title bar competes with it for the eye.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        PairedDevicesView(controller: controller)
                    } label: {
                        Image(systemName: "iphone.and.arrow.forward")
                    }
                    .accessibilityLabel("Paired Macs")
                }
            }
        }
        .task {
            await controller.prepare()
        }
        .onChange(of: scenePhase) { _, phase in
            // See `refreshFromStore`: a launch before the device's first unlock
            // reads an empty keychain and nothing looked again.
            if phase == .active { controller.refreshFromStore() }
        }
        .sheet(isPresented: $controller.isPairing) {
            PairingSheet(controller: controller)
        }
    }

    private var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: controller.state.isConnected
                ? [Color(red: 0.05, green: 0.22, blue: 0.16), Color(red: 0.02, green: 0.08, blue: 0.07)]
                : [Color(red: 0.07, green: 0.09, blue: 0.16), Color(red: 0.02, green: 0.03, blue: 0.06)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// ONE SWITCH, TWO WORDS.
    ///
    /// This used to be three branches with three labels, and the first two were
    /// the same action: "Stop Bridging" while a Mac was connected, "Turn Off"
    /// while merely listening, both calling `disconnect()`. Worse, the second
    /// branch was keyed on the tunnel's `NEVPNStatus` rather than on `state`, so
    /// tapping "Stop Bridging" flipped the label to "Turn Off" for the second or
    /// two the tunnel took to actually stop — making one action look like two
    /// presses of two different buttons.
    ///
    /// Whether a Mac is connected is status. It is on the dial. It is not a
    /// second mode needing its own verb.
    @ViewBuilder
    private var primaryControl: some View {
        let control = controller.control
        let button = Button(role: control.isDestructive ? .destructive : nil) {
            if control.switchesOn {
                Task { await controller.startBridge() }
            } else {
                controller.disconnect()
            }
        } label: {
            Text(control.label)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        // The ONLY thing branched on here is styling. The label and the action
        // both come from `PhoneControl`, so they cannot drift apart — one
        // action acquiring three different labels across three duplicated
        // branches is precisely what went wrong.
        if control.isDestructive {
            button.buttonStyle(.bordered)
        } else {
            button.buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var peerSection: some View {
        if !controller.state.isConnected {
            VStack(alignment: .leading, spacing: 8) {
                Text("Paired Macs")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)

                if controller.pairedDevices.isEmpty {
                    Text("No Macs yet. Connect the cable and pair to get started.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                } else {
                    ForEach(controller.pairedDevices) { device in
                        HStack {
                            Image(systemName: "laptopcomputer")
                            Text(device.name)
                            Spacer()
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                                .accessibilityLabel("Paired")
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }

                Button("Pair a Mac…") { controller.isPairing = true }
                    .font(.footnote.weight(.semibold))
                    .padding(.top, 2)
            }
        }
    }
}

/// The big circular indicator. Colour and label are driven by the *reported*
/// egress, never by the fact that a connection exists — a bridge routing over
/// Wi-Fi must not look like a bridge routing over cellular.
struct StatusDial: View {

    let state: BridgeState

    var body: some View {
        ZStack {
            Circle()
                .stroke(ringColor.opacity(0.25), lineWidth: 14)
            Circle()
                .trim(from: 0, to: state.isConnected ? 1 : 0.12)
                .stroke(ringColor, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.6), value: state)

            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 44, weight: .light))
                Text(headline)
                    .font(.title3.weight(.semibold))
            }
            .foregroundStyle(.white)
        }
        .frame(width: 200, height: 200)
    }

    private var symbol: String {
        switch state {
        case .connected(_, .cellular): "antenna.radiowaves.left.and.right"
        // Nothing has been dialled yet, so nothing is known. That is not a
        // fault and must not look like one — see `headline`.
        case .connected(_, .unknown): "antenna.radiowaves.left.and.right"
        case .connected: "exclamationmark.triangle"
        case .waitingForMac: "cable.connector"
        case .failed: "exclamationmark.triangle"
        case .needsPermission: "lock.shield"
        case .idle: "personalhotspot"
        }
    }

    private var headline: String {
        switch state {
        case .connected(_, .cellular): "Cellular"
        // "Unknown" meant two different things and showed the alarming one.
        // The egress is only observed when a destination is actually dialled,
        // so a healthy session that has carried nothing yet reported `.unknown`
        // and drew a warning triangle reading "Unknown" — indistinguishable
        // from the real warning, which is "we looked, and it is NOT cellular".
        case .connected(_, .unknown): "Connected"
        case let .connected(_, egress): egress.displayName
        case .waitingForMac: "Waiting"
        case .failed: "Problem"
        case .needsPermission: "Setup"
        case .idle: "Ready"
        }
    }

    private var ringColor: Color {
        switch state {
        case .connected(_, .cellular): .green
        case .connected(_, .unknown): .blue   // connected, nothing measured yet
        case .connected: .orange              // measured, and NOT cellular
        case .failed: .red
        default: .blue
        }
    }
}

/// The honest one-liner under the dial.
struct StatusCaption: View {

    let state: BridgeState

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var title: String {
        switch state {
        case let .connected(peer, .cellular): "Bridging \(peer)"
        case let .connected(peer, .unknown): "Connected to \(peer)"
        case let .connected(peer, egress): "Bridging \(peer) over \(egress.displayName)"
        case .waitingForMac: "Waiting for your Mac"
        case .idle: "Not bridging"
        case .needsPermission: "One-time setup needed"
        case .failed: "Couldn't bridge"
        }
    }

    private var detail: String? {
        switch state {
        case .connected(_, .cellular):
            "Your Mac's traffic is going out over cellular. You can lock your phone."
        case .connected(_, .unknown):
            "Waiting for your Mac to send something. The route is only reported once real traffic goes out."
        case .connected:
            // The warning that makes the whole egress-reporting path worth it.
            "Traffic is not going over cellular, so you're not bypassing anything. Check that cellular data is on."
        case .waitingForMac:
            // The one instruction that matters, and the one the old copy got
            // wrong: nothing is "found automatically" any more. The cable is
            // the whole mechanism.
            "Connect this iPhone to your Mac with a cable. You can lock your phone once it's bridging."
        case .idle:
            "Turn UpLink on, then connect the cable to your Mac."
        case .needsPermission:
            "iOS needs your permission to add a VPN configuration. UpLink uses it to keep running while the phone is locked — it does not send your traffic to a server."
        case let .failed(message):
            message
        }
    }
}

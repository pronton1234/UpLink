import SwiftUI
import UpLinkKit

/// The Mac's real window.
///
/// The HIG warns against relying on a menu bar extra as an app's only UI —
/// people can hide it, and a menu is the wrong place for anything that needs
/// more than a click. Pairing codes and device management live here.
struct DevicesView: View {

    @Bindable var model: MenuBarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.activePairingCode != nil {
                pairingCard
                Divider()
            }
            deviceList
        }
        .frame(minWidth: 440, minHeight: 400)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: headerSymbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(headerTint)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.statusHeadline).font(.headline)
                if let detail = model.statusDetail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(16)
    }

    /// Mirrors the menu bar glyph: the cable's presence is the first thing to
    /// read off this window.
    private var headerSymbol: String {
        switch model.status {
        case .connected(_, .cellular): "personalhotspot"
        case .connected: "exclamationmark.triangle"
        case .waitingForCable: "cable.connector.slash"
        default: "cable.connector"
        }
    }

    private var headerTint: Color {
        switch model.status {
        case .connected(_, .cellular): .green
        case .connected: .orange
        case .failed: .red
        case .waitingForCable: .secondary
        default: .accentColor
        }
    }

    private var pairingCard: some View {
        VStack(spacing: 10) {
            Text("Enter this code on your iPhone")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(formattedCode)
                .font(.system(size: 42, weight: .semibold, design: .monospaced))
                .tracking(6)
                .textSelection(.enabled)

            if let expiry = model.pairingExpiresAt {
                Text("Expires \(expiry, style: .relative) · single use")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(.quaternary.opacity(0.35))
    }

    private var formattedCode: String {
        guard let digits = model.activePairingCode?.digits else { return "······" }
        let middle = digits.index(digits.startIndex, offsetBy: 3)
        return "\(digits[digits.startIndex ..< middle]) \(digits[middle...])"
    }

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Paired iPhones")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Show Pairing Code") { model.beginPairing() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if model.pairedDevices.isEmpty {
                ContentUnavailableView(
                    "No Paired iPhones",
                    systemImage: "iphone.slash",
                    description: Text("Show a pairing code, then enter it in UpLink on your iPhone.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.pairedDevices) { device in
                        HStack {
                            Image(systemName: "iphone")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                Text(device.fingerprint)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove") { model.unpair(device) }
                                .controlSize(.small)
                        }
                        .padding(.vertical, 3)
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            Text("UpLink routes every app's TCP and UDP traffic through your iPhone. Nothing is sent to a server \u{2014} traffic goes directly between this Mac and your phone over the local link.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(12)
        }
    }
}

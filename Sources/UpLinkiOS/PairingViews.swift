import SwiftUI
import UpLinkKit

/// Code entry, shown the first time this phone meets a given Mac.
///
/// One job per screen, and it explains *why* before asking for anything — the
/// user has to walk to their Mac, so the instruction has to be unambiguous.
struct PairingSheet: View {

    let peer: DiscoveredPeer
    @Bindable var controller: BridgeController

    @State private var code = ""
    @State private var isSubmitting = false
    @Environment(\.dismiss) private var dismiss

    private var isValid: Bool { code.count == PairingCode.length }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(.blue)
                    .padding(.top, 24)

                VStack(spacing: 8) {
                    Text("Pair with \(peer.name)")
                        .font(.title2.weight(.semibold))
                    Text("Click UpLink in your Mac's menu bar and choose **Show Pairing Code**, then enter the six digits here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                TextField("000000", text: $code)
                    .textFieldStyle(.plain)
                    .font(.system(size: 40, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .padding(.vertical, 12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                    .onChange(of: code) { _, new in
                        // Keep it to six digits without making the field feel
                        // like it is fighting the user.
                        code = String(new.filter(\.isNumber).prefix(PairingCode.length))
                    }

                Text("The code is good for one minute and can only be used once.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Spacer()

                Button {
                    isSubmitting = true
                    Task {
                        await controller.completePairing(peer: peer, code: code)
                        isSubmitting = false
                    }
                } label: {
                    if isSubmitting {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Pair").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!isValid || isSubmitting)
            }
            .padding(24)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        controller.pendingPairingPeer = nil
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Manage which Macs this phone will bridge for.
struct PairedDevicesView: View {

    @Bindable var controller: BridgeController

    var body: some View {
        List {
            Section {
                if controller.pairedDevices.isEmpty {
                    ContentUnavailableView(
                        "No Paired Macs",
                        systemImage: "laptopcomputer.slash",
                        description: Text("Pair a Mac to share this iPhone's cellular connection with it.")
                    )
                } else {
                    ForEach(controller.pairedDevices) { device in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(device.name).font(.body)
                            Text(device.fingerprint)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { indexes in
                        for index in indexes {
                            controller.unpair(controller.pairedDevices[index])
                        }
                    }
                }
            } footer: {
                Text("Only paired Macs can route traffic through this iPhone. Removing one takes effect immediately.")
            }
        }
        .navigationTitle("Paired Macs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
    }
}

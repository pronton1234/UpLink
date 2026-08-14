import SwiftUI

/// Shows the tunnel extension's own log, on the phone.
///
/// ## Why this is in the product rather than in a script
///
/// The configuration this product exists for — no cable, no Wi-Fi network — is
/// exactly the configuration in which the phone cannot be read. Every route out
/// has a catch:
///
///   - `os.Logger` needs a cable to read live, and attaching the cable changes
///     the thing under test, because it gives the Mac a second path to the phone
///     and the peer link stops being AWDL.
///   - The file the extension writes needs `devicectl` and therefore a cable.
///   - `log collect --device-udid` needs root and fights devicectl for the
///     device: "failed to create archive: Device not configured (6)".
///
/// So every round of debugging has been inference from the Mac's silence, which
/// cannot distinguish "the phone never dialled" from "the phone dialled and was
/// refused" — opposite causes with identical symptoms. Reading the log on the
/// phone needs no cable, no root, and nothing to be plugged in mid-test.
struct DiagnosticsView: View {

    let controller: BridgeController

    @State private var text = "Loading…"
    @State private var isRefreshing = false

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isRefreshing)
                .accessibilityLabel("Refresh")
            }
            ToolbarItem(placement: .bottomBar) {
                // The log is long and the interesting part is a timeline, so
                // copying it out beats reading it on a phone screen.
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        isRefreshing = true
        text = await controller.fetchDiagnostics()
        isRefreshing = false
    }
}

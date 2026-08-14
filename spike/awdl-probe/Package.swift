// swift-tools-version: 6.0
import PackageDescription

// THROWAWAY. This exists to answer one question — does AWDL survive inside an
// iOS Network Extension with the phone locked — and should be deleted once
// docs/device-test-log.md records the answer. Nothing in UpLink depends on it.
let package = Package(
    name: "awdl-probe",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "awdl-probe", path: "Sources")
    ]
)

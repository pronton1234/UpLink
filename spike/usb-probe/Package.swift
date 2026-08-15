// swift-tools-version: 6.0
import PackageDescription

// Throwaway. Answers the one assumption the wired transport rests on, then
// gets deleted once docs/device-test-log.md records the answer.
let package = Package(
    name: "usb-probe",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../UpLinkKit")],
    targets: [
        .executableTarget(
            name: "usb-probe",
            dependencies: [.product(name: "UpLinkKit", package: "UpLinkKit")]
        )
    ]
)

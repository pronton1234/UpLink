// swift-tools-version: 6.0
import PackageDescription

// UpLinkKit is deliberately a standalone SwiftPM package rather than an Xcode
// target. Everything that carries real correctness risk — the wire protocol,
// the multiplexer's flow control, the pairing key schedule — lives here and is
// pure Swift, so `swift test` exercises it in seconds without xcodebuild, a
// simulator, or a device. The four app/extension targets in ../project.yml
// depend on this package and stay as thin as possible.
let package = Package(
    name: "UpLinkKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "UpLinkKit", targets: ["UpLinkKit"]),
    ],
    targets: [
        .target(
            name: "UpLinkKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Ordinary unit + loopback integration coverage.
        .testTarget(
            name: "UpLinkKitTests",
            dependencies: ["UpLinkKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // One permanent test per defect. Kept in its own target so that
        // refactors which legitimately delete a unit test can never quietly
        // delete the proof that a bug stays fixed. See docs/REGRESSIONS.md.
        .testTarget(
            name: "UpLinkRegressionTests",
            dependencies: ["UpLinkKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)

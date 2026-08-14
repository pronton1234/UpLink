// swift-tools-version: 6.0
import PackageDescription

// A "fake phone" that runs the real PairingClient against the real Mac
// listener, from the Mac itself.
//
// Why this exists: a failed pairing on a physical iPhone gives one bit of
// information — it did not work — and every hypothesis costs a rebuild, a
// reinstall, and a walk to the phone. This binary uses the SAME UpLinkKit code
// the iOS app uses, so it isolates the question: does the Mac's listener pair
// with a correct client at all? If this succeeds and the phone does not, the
// fault is on the phone (stale build, different identity). If this fails the
// same way, the fault is in shared kit code and can be fixed in seconds.
let package = Package(
    name: "pair-probe",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../UpLinkKit")],
    targets: [
        .executableTarget(
            name: "pair-probe",
            dependencies: [.product(name: "UpLinkKit", package: "UpLinkKit")],
            path: "Sources",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)

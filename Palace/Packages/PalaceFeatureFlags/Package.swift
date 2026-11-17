// swift-tools-version: 6.0
import PackageDescription

// Layer-0 leaf package: typed feature-flag names (raw values are Firebase
// Remote Config wire keys) and the read protocol `FeatureFlagProviding`.
// Has no dependencies: the Firebase-backed `RemoteFeatureFlags` lives in the
// app target, and no package imports Firebase.
// Tests live in PalaceTests; an empty test target breaks `swift build` (#1133).
let package = Package(
    name: "PalaceFeatureFlags",
    platforms: [
        .iOS(.v17),
        // macOS host floor 13 matches the modernized-package convention
        // (host-build only; shipping app is iOS 17).
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "PalaceFeatureFlags",
            targets: ["PalaceFeatureFlags"]
        )
    ],
    targets: [
        .target(
            name: "PalaceFeatureFlags",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)

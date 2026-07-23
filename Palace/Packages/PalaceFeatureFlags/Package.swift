// swift-tools-version: 6.0
import PackageDescription

// Layer-0 leaf package (god-class decomposition Wave 1b): the typed
// feature-flag names (PalaceFeatureFlag — raw values are Firebase Remote
// Config wire keys) and the consolidated read protocol (FeatureFlagProviding).
// Depends on NOTHING and must stay that way — the Firebase-backed
// implementation (RemoteFeatureFlags) lives in the app target; NO package
// may ever import Firebase (plan §2.3 "Nothing below Application knows
// Firebase").
// No in-package test target: behavior tests live in the app's PalaceTests
// bundle (RemoteFeatureFlagsTests etc. — PalaceNetwork/PalaceCatalog
// precedent, and a phantom test target breaks standalone `swift build`, #1133).
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

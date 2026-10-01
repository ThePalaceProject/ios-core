// swift-tools-version: 6.0
import PackageDescription

// Layer-0 leaf package: the UserDefaults-backed preferences store
// (TPPSettings), its DI protocol, and the settings-change notification names.
// Has no dependencies; anything needing Accounts/UI/network belongs app-side.
// Tests live in PalaceTests (PalacePreferencesSettingsRoundTripTests, Settings/).
let package = Package(
    name: "PalacePreferences",
    platforms: [
        .iOS(.v17),
        // macOS host floor 13 to match the convention the other modernized
        // packages established (host-build only; shipping app is iOS 17).
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "PalacePreferences",
            targets: ["PalacePreferences"]
        )
    ],
    targets: [
        .target(
            name: "PalacePreferences",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)

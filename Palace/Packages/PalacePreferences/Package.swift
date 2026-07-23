// swift-tools-version: 6.0
import PackageDescription

// Layer-0 leaf package (god-class decomposition Wave 1a): the UserDefaults-
// backed key-value preferences store (TPPSettings), its DI protocol, and the
// two settings-change Notification.Names. Depends on NOTHING — keep it that
// way; anything needing Accounts/UI/network types belongs app-side.
// No in-package test target: the characterization pack lives in
// PalaceTests/Decomp/PalacePreferencesSettingsRoundTripTests.swift plus
// PalaceTests/Settings/* (PalaceNetwork precedent — tests stay in the app's
// test bundle).
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

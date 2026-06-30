// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PalaceAuth",
    platforms: [
        .iOS(.v16),
        // macOS host floor 13 to match the PalaceLogging dependency
        // (OSAllocatedUnfairLock, macOS 13+). Host-build only; shipping app is
        // iOS 16. Same floor the other modernized packages established.
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "PalaceAuth",
            targets: ["PalaceAuth"]
        )
    ],
    dependencies: [
        .package(path: "../PalaceLogging"),
        .package(path: "../PalaceNetwork"),
        .package(path: "../PalaceCatalog")
    ],
    targets: [
        // Source target → Swift 6 (race-checked). Test target stays v5 to avoid
        // test-infra churn (XCTestCase isn't Sendable). Same split as #1130.
        .target(
            name: "PalaceAuth",
            dependencies: ["PalaceLogging", "PalaceNetwork", "PalaceCatalog"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PalaceAuthTests",
            dependencies: ["PalaceAuth"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

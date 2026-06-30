// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PalaceReadingPosition",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "PalaceReadingPosition",
            targets: ["PalaceReadingPosition"]
        )
    ],
    dependencies: [
        .package(path: "../PalaceLogging")
    ],
    targets: [
        .target(
            name: "PalaceReadingPosition",
            dependencies: ["PalaceLogging"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PalaceReadingPositionTests",
            dependencies: ["PalaceReadingPosition"],
            // Source target is Swift 6 (race-checked); test target stays v5 to
            // avoid test-infra churn (XCTestCase isn't Sendable). See #1130.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

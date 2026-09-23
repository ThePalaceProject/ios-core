// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PalaceKeychain",
    platforms: [
        .iOS(.v17),
        .macOS(.v11)
    ],
    products: [
        .library(
            name: "PalaceKeychain",
            targets: ["PalaceKeychain"]
        )
    ],
    dependencies: [
        .package(path: "../PalaceLogging")
    ],
    targets: [
        .target(
            name: "PalaceKeychain",
            dependencies: ["PalaceLogging"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PalaceKeychainTests",
            dependencies: ["PalaceKeychain"],
            // Source target is Swift 6 (race-checked); the test target stays v5
            // to avoid test-infrastructure churn (XCTestCase isn't Sendable, so
            // v6 flags benign `self`-sends in async tests). Production code — the
            // point of the migration — is fully v6.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

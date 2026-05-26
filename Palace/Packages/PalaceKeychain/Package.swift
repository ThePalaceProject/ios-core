// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PalaceKeychain",
    platforms: [
        .iOS(.v16),
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
            dependencies: ["PalaceLogging"]
        ),
        .testTarget(
            name: "PalaceKeychainTests",
            dependencies: ["PalaceKeychain"]
        )
    ]
)

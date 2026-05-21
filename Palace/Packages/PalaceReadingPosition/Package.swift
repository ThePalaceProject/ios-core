// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PalaceReadingPosition",
    platforms: [
        .iOS(.v16),
        .macOS(.v11)
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
            dependencies: ["PalaceLogging"]
        ),
        .testTarget(
            name: "PalaceReadingPositionTests",
            dependencies: ["PalaceReadingPosition"]
        )
    ]
)

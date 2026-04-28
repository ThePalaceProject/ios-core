// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PalaceLogging",
    platforms: [
        .iOS(.v16),
        .macOS(.v11)
    ],
    products: [
        .library(
            name: "PalaceLogging",
            targets: ["PalaceLogging"]
        )
    ],
    targets: [
        .target(
            name: "PalaceLogging"
        ),
        .testTarget(
            name: "PalaceLoggingTests",
            dependencies: ["PalaceLogging"]
        )
    ]
)

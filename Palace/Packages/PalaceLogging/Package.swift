// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PalaceLogging",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "PalaceLogging",
            targets: ["PalaceLogging"]
        )
    ],
    targets: [
        .target(
            name: "PalaceLogging",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PalaceLoggingTests",
            dependencies: ["PalaceLogging"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)

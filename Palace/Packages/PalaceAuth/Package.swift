// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PalaceAuth",
    platforms: [
        .iOS(.v16),
        .macOS(.v12)
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
        .target(
            name: "PalaceAuth",
            dependencies: ["PalaceLogging", "PalaceNetwork", "PalaceCatalog"]
        ),
        .testTarget(
            name: "PalaceAuthTests",
            dependencies: ["PalaceAuth"]
        )
    ]
)

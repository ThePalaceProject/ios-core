// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PalaceCatalog",
    platforms: [
        .iOS(.v16),
        .macOS(.v11)
    ],
    products: [
        .library(
            name: "PalaceCatalog",
            targets: ["PalaceCatalog"]
        )
    ],
    dependencies: [
        .package(path: "../PalaceLogging"),
        .package(path: "../PalaceNetwork")
    ],
    targets: [
        .target(
            name: "PalaceCatalog",
            dependencies: ["PalaceLogging", "PalaceNetwork"]
        ),
        .testTarget(
            name: "PalaceCatalogTests",
            dependencies: ["PalaceCatalog"]
        )
    ]
)

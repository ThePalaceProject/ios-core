// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PalaceNetwork",
    platforms: [
        .iOS(.v16),
        .macOS(.v11)
    ],
    products: [.library(name: "PalaceNetwork", targets: ["PalaceNetwork"])],
    dependencies: [
        .package(path: "../PalaceLogging")
    ],
    targets: [
        .target(name: "PalaceNetwork", dependencies: ["PalaceLogging"]),
        .testTarget(name: "PalaceNetworkTests", dependencies: ["PalaceNetwork"])
    ]
)

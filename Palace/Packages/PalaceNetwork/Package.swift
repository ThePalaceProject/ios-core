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
        // NOTE: PalaceNetwork has no in-package Tests/ directory — its tests live
        // in the app's `PalaceTests` target (e.g. TPPNetworkExecutorTests,
        // TPPNetworkResponder*Tests). The previous `.testTarget` declaration was
        // phantom (no `Tests/PalaceNetworkTests` dir), which broke standalone
        // `swift build` / `swift test`. Dropped so the package resolves + builds
        // on its own.
        .target(name: "PalaceNetwork", dependencies: ["PalaceLogging"])
    ]
)

// swift-tools-version: 6.0
import PackageDescription
// Swift 6 modernization (fan-out from #1129). tools-version 6.0 puts the
// `PalaceNetwork` source target in Swift 6 language mode by default. There is no
// in-package test target (tests live in the app's PalaceTests target), so no
// `.v5` test override is needed here (cf. the playbook's source→.v6 / test→.v5).

let package = Package(
    name: "PalaceNetwork",
    platforms: [
        .iOS(.v16),
        // macOS host floor 13 to match the PalaceLogging dependency
        // (OSAllocatedUnfairLock, macOS 13+). Host-build only; shipping app is
        // iOS 16. Latent floor gap from #1133 — only bites standalone builds.
        .macOS(.v13)
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

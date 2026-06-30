// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PalaceCatalog",
    platforms: [
        .iOS(.v16),
        // macOS host floor 13 to match the PalaceLogging dependency (it needs
        // OSAllocatedUnfairLock, macOS 13+). Host-build only — the shipping app
        // is iOS 16. Same floor PalaceLogging/PalaceKeychain established.
        .macOS(.v13)
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
        )
        // No in-package test target: PalaceCatalog's tests live in the app's
        // `PalaceTests` target (there is no `Tests/` dir here). The phantom
        // `.testTarget(name: "PalaceCatalogTests")` broke standalone
        // `swift build`/`swift test` with an "overlapping sources" error — same
        // manifest bug fixed for PalaceNetwork in #1133.
    ]
)

// swift-tools-version: 6.0
import PackageDescription

// Layer-0 leaf package: TPPBook and its registry/state/bookmark value types.
// Depends only on PalaceCatalog and PalaceLogging; accounts, downloads,
// settings and UI consume this package, never the reverse.
// iOS-only: TPPBook carries UIImage/UIColor state, and #if-guarding it would
// fork the public API. Tests live in PalaceTests.
let package = Package(
    name: "PalaceBookModel",
    platforms: [.iOS(.v17)],
    products: [.library(name: "PalaceBookModel", targets: ["PalaceBookModel"])],
    dependencies: [
        .package(path: "../PalaceCatalog"),
        .package(path: "../PalaceLogging")
    ],
    targets: [
        .target(
            name: "PalaceBookModel",
            dependencies: ["PalaceCatalog", "PalaceLogging"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)

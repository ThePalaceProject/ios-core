// swift-tools-version: 6.0
import PackageDescription

// Layer-0 leaf package (god-class decomposition Wave 2a): the book model —
// TPPBook + registry record/state/location/bookmark value types, the content-
// type taxonomy, and the image-loading protocol surface the model carries.
// Depends on PalaceCatalog (the OPDS acquisition model TPPBook is built from)
// and PalaceLogging ONLY. It must never grow an edge to accounts, downloads,
// settings, or UI — those consume this package, never the reverse.
// iOS-only (deliberate deviation from the .macOS host-build convention):
// TPPBook carries UIImage/UIColor @Published state and ImageLoading has
// UIImage in its requirements — #if-guarding stored properties and protocol
// requirements would fork the public API, so there is no macOS build.
// No in-package test target: tests live in PalaceTests (PalaceNetwork precedent).
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

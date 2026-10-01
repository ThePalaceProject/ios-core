// swift-tools-version: 6.0
import PackageDescription

// The book-registry engine: the `TPPBookRegistry` facade and its collaborators
// (store, loans-feed sync, bookmarks, file recovery).
// Account scope arrives through the value-only `AccountScopeProviding`, and
// downloads, the loans fetch, sideload exemptions, directory layout and the
// availability hook through `RegistryExternalDependencies`, so this package has
// no edge to accounts, downloads, settings or AppContainer.
// Needs PalaceCatalog for TPPOPDSFeed and the OPDSFeedFetching seam; does not
// need PalacePreferences. iOS-only, Swift 6 mode. Tests live in PalaceTests.
let package = Package(
    name: "PalaceBookRegistry",
    platforms: [.iOS(.v17)],
    products: [.library(name: "PalaceBookRegistry", targets: ["PalaceBookRegistry"])],
    dependencies: [
        .package(path: "../PalaceBookModel"),
        .package(path: "../PalaceCatalog"),
        .package(path: "../PalaceLogging")
    ],
    targets: [
        .target(
            name: "PalaceBookRegistry",
            dependencies: ["PalaceBookModel", "PalaceCatalog", "PalaceLogging"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)

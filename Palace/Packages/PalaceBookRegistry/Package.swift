// swift-tools-version: 6.0
import PackageDescription

// God-class decomposition Wave 2b (keystone-second-half): the book-registry
// engine — the `TPPBookRegistry` facade + its three collaborators
// (`BookRegistryStore`, `BookRegistrySync`, `BookmarkManager`) + `RegistryFileRecovery`.
// It owns the in-memory record dictionary, disk load/save, server loans-feed
// reconciliation, orphan recovery, and bookmark/location CRUD.
//
// The Accounts dependency is INVERTED here: the engine consumes account scope
// through the value-only `AccountScopeProviding` protocol (declared in-package,
// adapted app-side over `AccountsManager`), never an Account/AccountsManager/
// TPPUserAccount type. Downloads, the OPDS loans fetch, the sideload-exemption
// set, the on-disk directory layout, and the availability-change notification
// are all injected via `RegistryExternalDependencies` — so this package has
// ZERO edge to accounts, downloads, settings, NotificationService, or the app's
// AppContainer. Those consume this package, never the reverse.
//
// Deps (deliberate deviation from the ADR DAG, which named PalacePreferences):
// the cluster has zero TPPSettings references, so no PalacePreferences dep; it
// DOES need PalaceCatalog (TPPOPDSFeed/TPPOPDSEntry + the OPDSFeedFetching seam
// live there — PalaceBookModel already depends on PalaceCatalog, so this is
// layer-clean).
//
// iOS-only + `.swiftLanguageMode(.v6)` (PalaceBookModel precedent). No in-package
// test target: tests live in PalaceTests.
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

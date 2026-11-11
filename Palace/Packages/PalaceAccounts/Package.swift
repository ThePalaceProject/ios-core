// swift-tools-version: 6.0
import PackageDescription

// PalaceAccounts holds the account-registry leaf types: the on-disk catalog
// cache, the registry store, the crawl state record and the network seam the
// account code calls through. It depends on PalaceLogging only. It must not
// depend on the app target or on Firebase; the app supplies the `Account`
// type (through `AccountRegistryEntry`) and the network executor (through
// `AccountNetworking`). Design: docs/architecture/god-class-decomposition-plan.md.
let package = Package(
    name: "PalaceAccounts",
    platforms: [
        .iOS(.v17),
        // macOS 13 host floor, matching the sibling packages, so `swift test`
        // runs this suite on a CI macOS runner.
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "PalaceAccounts",
            targets: ["PalaceAccounts"]
        )
    ],
    dependencies: [
        .package(path: "../PalaceLogging")
    ],
    targets: [
        // Source target in Swift 6 mode; the test target stays v5 because
        // XCTestCase is not Sendable. Same split as the sibling packages.
        .target(
            name: "PalaceAccounts",
            dependencies: [
                .product(name: "PalaceLogging", package: "PalaceLogging")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PalaceAccountsTests",
            dependencies: ["PalaceAccounts"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

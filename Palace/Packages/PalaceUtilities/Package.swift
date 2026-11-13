// swift-tools-version: 6.0
import PackageDescription

// PalaceUtilities is a LEAF: it declares no package dependencies, and it must
// keep declaring none.
//
// The constraint is structural, not stylistic. PalaceCatalog still parks six
// general-purpose helpers of its own (TPPXML, TPPNull, TPPAsync,
// String+HTMLEntities, String+TPPStringAdditions, Date+TPPDateAdditions)
// because at extraction time there was nowhere else to put them. Reuniting
// them here later needs the edge PalaceCatalog -> PalaceUtilities, and SwiftPM
// resolves that only while this package depends on nothing that reaches
// PalaceCatalog back. One dependency added here — PalaceBookModel, say, which
// an ImageCacheType move would force — pulls in
// PalaceBookModel -> PalaceCatalog -> {PalaceLogging, PalaceNetwork,
// PalaceFeatureFlags} and turns that future edge into a manifest-resolution
// error, permanently.
//
// So: a file that needs PalaceLogging (GeneralCache, ImageCache,
// TPPBackgroundExecutor, URL+BackupExclusion) stays in the app target until
// there is a reason to spend the leaf property on it.
let package = Package(
    name: "PalaceUtilities",
    platforms: [
        .iOS(.v17),
        // macOS 13 host floor, matching the sibling packages. Host-build only;
        // the shipping app is iOS 17. The floor is what lets `swift test` run
        // this package's suite on a CI macOS runner, which is why every file
        // in it is Foundation-only — see check-package-tests-wired.sh.
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "PalaceUtilities",
            targets: ["PalaceUtilities"]
        )
    ],
    dependencies: [],
    targets: [
        // Source target -> Swift 6 (race-checked). Test target stays v5 to
        // avoid test-infra churn (XCTestCase isn't Sendable). Same split the
        // other modernized packages use.
        .target(
            name: "PalaceUtilities",
            dependencies: [],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PalaceUtilitiesTests",
            dependencies: ["PalaceUtilities"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

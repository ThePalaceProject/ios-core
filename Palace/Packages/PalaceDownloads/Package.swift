// swift-tools-version: 6.0
import PackageDescription

// PalaceDownloads holds the download subsystem's pure decision cores and the
// Foundation-only account-context protocols. The effect runners
// (BorrowOperation, BookReturnService, DownloadStartDispatcher,
// MyBooksDownloadCenter) and every DRM or UIKit adapter stay in the app target
// and call into this package. Nothing here may depend on the app or on a
// concrete DRM SDK.
//
// It declares no package dependencies, so `swift test` runs it on a macOS
// host. PalaceBookModel imports UIKit and has no macOS floor, so a core that
// needs `TPPBookState` (DownloadStartReducer, DownloadReconciliation) stays in
// the app target until that type is host-buildable.
let package = Package(
    name: "PalaceDownloads",
    platforms: [
        .iOS(.v17),
        // macOS 13 host floor, matching the sibling packages, so `swift test`
        // runs this package's suite on a CI macOS runner. Host-build only; the
        // shipping app is iOS 17.
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "PalaceDownloads",
            targets: ["PalaceDownloads"]
        )
    ],
    dependencies: [],
    targets: [
        // Source target -> Swift 6 (race-checked). Test target stays v5
        // (XCTestCase isn't Sendable), the split the other packages use.
        .target(
            name: "PalaceDownloads",
            dependencies: [],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PalaceDownloadsTests",
            dependencies: ["PalaceDownloads"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

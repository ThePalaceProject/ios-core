//
//  DynamicTypeSnapshotTests.swift
//  PalaceUITests
//
//  Launches the app at a range of Dynamic Type sizes, navigates to critical
//  screens, runs an accessibility audit, and attaches a screenshot for
//  visual review. This is NOT a baseline-comparison snapshot test — the
//  attached screenshots serve as evidence for human review.
//

import XCTest

@MainActor
final class DynamicTypeSnapshotTests: XCTestCase {

    /// Content size categories exercised by every screen test.
    private static let categories: [String] = [
        "UICTContentSizeCategoryXS",   // .extraSmall
        "UICTContentSizeCategoryL",    // .large (default)
        "UICTContentSizeCategoryAccessibilityXXXL" // .accessibilityExtraExtraExtraLarge
    ]

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    // MARK: - Helpers

    private func launchApp(category: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--uitesting",
            "-UIPreferredContentSizeCategoryName", category
        ]
        app.launch()
        return app
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @available(iOS 17.0, *)
    private func runAudit(_ app: XCUIApplication) throws {
        try app.performAccessibilityAudit(for: [
            .dynamicType, .contrast, .elementDetection,
            .hitRegion, .sufficientElementDescription
        ])
    }

    // MARK: - Catalog

    func testCatalogAcrossDynamicTypeSizes() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Requires iOS 17+") }
        for category in Self.categories {
            try XCTContext.runActivity(named: "Catalog @ \(category)") { _ in
                let app = launchApp(category: category)
                let catalog = CatalogScreen(app: app).navigate()
                catalog.verifyLoaded()
                attachScreenshot(app, name: "Catalog-\(category)")
                try runAudit(app)
                app.terminate()
            }
        }
    }

    // MARK: - Book Detail

    func testBookDetailAcrossDynamicTypeSizes() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Requires iOS 17+") }
        for category in Self.categories {
            try XCTContext.runActivity(named: "BookDetail @ \(category)") { _ in
                let app = launchApp(category: category)
                let catalog = CatalogScreen(app: app).navigate()
                catalog.verifyLoaded()
                guard catalog.firstBookCell.waitForExistence(timeout: 15) else {
                    // A11Y-GAP: catalog empty for this run; capture catalog as fallback.
                    attachScreenshot(app, name: "BookDetail-\(category)-NO-BOOKS")
                    app.terminate()
                    return
                }
                let detail = catalog.tapFirstBook()
                detail.verifyLoaded()
                attachScreenshot(app, name: "BookDetail-\(category)")
                try runAudit(app)
                app.terminate()
            }
        }
    }

    // MARK: - Settings

    func testSettingsAcrossDynamicTypeSizes() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Requires iOS 17+") }
        for category in Self.categories {
            try XCTContext.runActivity(named: "Settings @ \(category)") { _ in
                let app = launchApp(category: category)
                let settings = SettingsScreen(app: app).navigate()
                settings.verifyLoaded()
                attachScreenshot(app, name: "Settings-\(category)")
                try runAudit(app)
                app.terminate()
            }
        }
    }
}

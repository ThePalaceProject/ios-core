//
//  AccessibilityAuditTests.swift
//  PalaceUITests
//
//  Per-screen accessibility audits using XCUIApplication.performAccessibilityAudit
//  (iOS 17+). Each test launches the app fresh, navigates via the existing
//  Screen object pattern, and runs the default audit. Audit failures are
//  auto-attached to the test report by XCTest — no extra logging required.
//

import XCTest

@MainActor
final class AccessibilityAuditTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments.append("--uitesting")
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
        try super.tearDownWithError()
    }

    // MARK: - Per-screen audits

    func testAuditCatalogScreen() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Requires iOS 17+") }
        let catalog = CatalogScreen(app: app).navigate()
        catalog.verifyLoaded()
        try app.performAccessibilityAudit(for: [
            .dynamicType, .contrast, .elementDetection,
            .hitRegion, .sufficientElementDescription
        ])
    }

    func testAuditMyBooksScreen() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Requires iOS 17+") }
        let myBooks = MyBooksScreen(app: app).navigate()
        myBooks.verifyLoaded()
        try app.performAccessibilityAudit(for: [
            .dynamicType, .contrast, .elementDetection,
            .hitRegion, .sufficientElementDescription
        ])
    }

    func testAuditBookDetailScreen() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Requires iOS 17+") }
        let catalog = CatalogScreen(app: app).navigate()
        catalog.verifyLoaded()

        // Reach a book detail via the first available cell. If no books load
        // (offline / empty catalog), skip rather than fail the audit test.
        guard catalog.firstBookCell.waitForExistence(timeout: 15) else {
            throw XCTSkip("No catalog books available to open detail screen")
        }
        let detail = catalog.tapFirstBook()
        detail.verifyLoaded()
        try app.performAccessibilityAudit(for: [
            .dynamicType, .contrast, .elementDetection,
            .hitRegion, .sufficientElementDescription
        ])
    }

    func testAuditSignInScreen() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Requires iOS 17+") }
        // A11Y-GAP: SignInScreen has no direct navigate(); reached via Settings → Sign In.
        // If the user is already signed in this button may be absent — skip in that case.
        let settings = SettingsScreen(app: app).navigate()
        settings.verifyLoaded()
        let signInEntry = app.buttons["Sign In"]
        guard signInEntry.waitForExistence(timeout: 5) else {
            throw XCTSkip("Sign In entry not visible (likely already signed in)")
        }
        let signIn = settings.tapSignIn()
        signIn.verifyLoaded()
        try app.performAccessibilityAudit(for: [
            .dynamicType, .contrast, .elementDetection,
            .hitRegion, .sufficientElementDescription
        ])
    }

    func testAuditSettingsScreen() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Requires iOS 17+") }
        let settings = SettingsScreen(app: app).navigate()
        settings.verifyLoaded()
        try app.performAccessibilityAudit(for: [
            .dynamicType, .contrast, .elementDetection,
            .hitRegion, .sufficientElementDescription
        ])
    }

    func testAuditSearchScreen() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Requires iOS 17+") }
        let catalog = CatalogScreen(app: app).navigate()
        catalog.verifyLoaded()
        let search = catalog.tapSearch()
        search.verifyLoaded()
        try app.performAccessibilityAudit(for: [
            .dynamicType, .contrast, .elementDetection,
            .hitRegion, .sufficientElementDescription
        ])
    }

    func testAuditAudiobookPlayerScreen() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Requires iOS 17+") }
        // A11Y-GAP: Reaching the audiobook player requires a borrowed audiobook
        // and authenticated session + DRM fulfillment. Cannot be reached from
        // a fresh launch in CI without credentials.
        throw XCTSkip("Audiobook player requires borrowed audiobook + auth; not reachable from clean launch")
    }

    func testAuditEPUBReaderScreen() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Requires iOS 17+") }
        // A11Y-GAP: Reaching the EPUB reader requires a borrowed book and DRM
        // fulfillment. Additionally, Readium WKWebView content renders outside
        // the XCTest accessibility tree (per CLAUDE.md SpecterQA notes), so an
        // audit here would have very limited coverage even if reachable.
        throw XCTSkip("EPUB reader requires borrowed book + DRM; WKWebView content not in a11y tree")
    }
}

//
//  PalaceUITestCase.swift
//  PalaceUITests
//
//  Copyright 2026 The Palace Project. All rights reserved.
//

import XCTest

/// Base class for all Palace UI tests.
///
/// Provides common app launch, tab navigation helpers, and credential
/// handling so individual test files stay focused on assertions.
class PalaceUITestCase: XCTestCase {

    // MARK: - Properties

    var app: XCUIApplication!

    /// Standard timeout used for element existence checks.
    let defaultTimeout: TimeInterval = 10

    /// Extended timeout for operations that involve network requests.
    let networkTimeout: TimeInterval = 30

    // MARK: - Environment Keys

    /// Set `PALACE_TEST_BARCODE` and `PALACE_TEST_PIN` in the Xcode
    /// scheme environment to enable tests that require authentication.
    private static let barcodeEnvKey = "PALACE_TEST_BARCODE"
    private static let pinEnvKey = "PALACE_TEST_PIN"

    var testBarcode: String? {
        ProcessInfo.processInfo.environment[Self.barcodeEnvKey]
    }

    var testPin: String? {
        ProcessInfo.processInfo.environment[Self.pinEnvKey]
    }

    var hasCredentials: Bool {
        testBarcode != nil && testPin != nil
    }

    // MARK: - Lifecycle

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

    // MARK: - Tab Navigation

    func navigateToCatalog() {
        app.tabBars.buttons["Catalog"].tap()
    }

    func navigateToMyBooks() {
        app.tabBars.buttons["My Books"].tap()
    }

    func navigateToReservations() {
        app.tabBars.buttons["Reservations"].tap()
    }

    func navigateToSettings() {
        app.tabBars.buttons["Settings"].tap()
    }

    // MARK: - Authentication Helpers

    /// Skips the current test when credentials are not available.
    func skipIfNoCredentials(file: StaticString = #filePath, line: UInt = #line) throws {
        try XCTSkipUnless(hasCredentials, "No test credentials provided. Set PALACE_TEST_BARCODE and PALACE_TEST_PIN.", file: file, line: line)
    }

    // MARK: - Element Helpers

    /// Waits for an element to exist, returning the element for further assertions.
    @discardableResult
    func waitForElement(
        _ element: XCUIElement,
        timeout: TimeInterval? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> XCUIElement {
        let exists = element.waitForExistence(timeout: timeout ?? defaultTimeout)
        XCTAssertTrue(exists, "Expected element \(element.identifier) to exist within \(timeout ?? defaultTimeout)s", file: file, line: line)
        return element
    }

    /// Returns true if the element exists within the given timeout, without asserting.
    func elementExists(_ element: XCUIElement, timeout: TimeInterval? = nil) -> Bool {
        element.waitForExistence(timeout: timeout ?? defaultTimeout)
    }

    /// Pulls to refresh on a given scrollable element.
    func pullToRefresh(on element: XCUIElement) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let end = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        start.press(forDuration: 0.1, thenDragTo: end)
    }
}

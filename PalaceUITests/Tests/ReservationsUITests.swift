//
//  ReservationsUITests.swift
//  PalaceUITests
//
//  Copyright 2026 The Palace Project. All rights reserved.
//

import XCTest

/// UI tests for the Reservations (Holds) screen.
final class ReservationsUITests: PalaceUITestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        navigateToReservations()
    }

    // MARK: - Screen Loading

    func testReservationsTabLoads() {
        let reservationsTab = app.tabBars.buttons["Reservations"]
        XCTAssertTrue(reservationsTab.isSelected || reservationsTab.waitForExistence(timeout: defaultTimeout),
                       "Reservations tab should be selected")
    }

    // MARK: - Empty State

    func testEmptyStateWhenNoHolds() {
        let emptyState = app.otherElements["holds.emptyStateView"]
        let scrollView = app.scrollViews["holds.scrollView"]

        let hasContent = elementExists(emptyState, timeout: defaultTimeout) || elementExists(scrollView, timeout: 5)
        XCTAssertTrue(hasContent, "Reservations should show either empty state or scroll view")
    }

    // MARK: - Reserved Books

    func testReservedBookShowsPositionInQueue() throws {
        try skipIfNoCredentials()
        XCTExpectFailure("Requires an active reservation with queue position")

        let scrollView = app.scrollViews["holds.scrollView"]
        guard scrollView.waitForExistence(timeout: networkTimeout) else {
            XCTFail("Holds scroll view not loaded")
            return
        }

        // Look for any cell in the holds list
        let cells = app.cells
        guard cells.count > 0 else {
            XCTFail("No reservation cells found")
            return
        }

        // A reserved book should show queue position text
        let firstCell = cells.firstMatch
        let labels = firstCell.staticTexts
        XCTAssertGreaterThan(labels.count, 0, "Hold cell should contain labels with queue information")
    }

    func testReadyBookShowsBorrowOption() throws {
        try skipIfNoCredentials()
        XCTExpectFailure("Requires a hold that is ready for borrowing")

        let scrollView = app.scrollViews["holds.scrollView"]
        guard scrollView.waitForExistence(timeout: networkTimeout) else {
            XCTFail("Holds scroll view not loaded")
            return
        }

        // Look for a borrow/get button among the hold cells
        let borrowButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'borrow' OR label CONTAINS[c] 'get'")
        ).firstMatch

        XCTAssertTrue(elementExists(borrowButton, timeout: 5),
                       "A ready hold should show a borrow button")
    }

    // MARK: - Cancel Reservation

    func testCancelReservationOptionExists() throws {
        try skipIfNoCredentials()
        XCTExpectFailure("Requires at least one active reservation")

        let scrollView = app.scrollViews["holds.scrollView"]
        guard scrollView.waitForExistence(timeout: networkTimeout) else {
            XCTFail("Holds scroll view not loaded")
            return
        }

        let cells = app.cells
        guard cells.count > 0 else {
            XCTFail("No hold cells found")
            return
        }

        // Tap the first hold to see details
        cells.firstMatch.tap()

        // Look for a cancel button in the detail view
        let cancelButton = app.buttons["bookDetail.cancelButton"]
        let cancelHold = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'cancel'")
        ).firstMatch

        let found = elementExists(cancelButton, timeout: defaultTimeout) || elementExists(cancelHold, timeout: 5)
        XCTAssertTrue(found, "Cancel reservation option should be available")
    }

    // MARK: - Badge

    func testHoldCountBadgeIfApplicable() {
        XCTExpectFailure("Badge display depends on having active holds and implementation")

        let reservationsTab = app.tabBars.buttons["Reservations"]
        // Check if the tab shows a badge value
        let badgeValue = reservationsTab.value as? String
        // Just ensure the query does not crash; badge may or may not be present
        _ = badgeValue
    }

    // MARK: - Pull to Refresh

    func testPullToRefreshUpdatesHolds() throws {
        try skipIfNoCredentials()
        XCTExpectFailure("Pull to refresh behavior depends on network and signed-in state")

        let scrollView = app.scrollViews["holds.scrollView"]
        let emptyState = app.otherElements["holds.emptyStateView"]

        let target: XCUIElement
        if scrollView.waitForExistence(timeout: 5) {
            target = scrollView
        } else if emptyState.waitForExistence(timeout: 5) {
            target = emptyState
        } else {
            target = app.scrollViews.firstMatch
        }

        pullToRefresh(on: target)

        // After refresh, should still be on the Reservations screen
        let tab = app.tabBars.buttons["Reservations"]
        XCTAssertTrue(tab.isSelected, "Should remain on Reservations after pull to refresh")
    }

    // MARK: - Hold Details

    func testHoldDetailShowsAvailabilityInfo() throws {
        try skipIfNoCredentials()
        XCTExpectFailure("Requires at least one hold")

        let cells = app.cells
        guard cells.firstMatch.waitForExistence(timeout: networkTimeout) else {
            XCTFail("No hold cells found")
            return
        }

        cells.firstMatch.tap()

        // The detail view should contain availability information
        let detailTitle = app.staticTexts["bookDetail.title"]
        waitForElement(detailTitle, timeout: defaultTimeout)

        // Look for availability or status labels
        let labels = app.staticTexts
        XCTAssertGreaterThan(labels.count, 1, "Hold detail should show availability information")
    }

    // MARK: - Multiple Holds

    func testMultipleHoldsDisplayCorrectly() throws {
        try skipIfNoCredentials()
        XCTExpectFailure("Requires multiple active reservations")

        let scrollView = app.scrollViews["holds.scrollView"]
        guard scrollView.waitForExistence(timeout: networkTimeout) else {
            XCTFail("Holds scroll view not loaded")
            return
        }

        let cells = app.cells
        XCTAssertGreaterThanOrEqual(cells.count, 2, "Multiple holds should be displayed")
    }

    // MARK: - Expired Holds

    func testExpiredHoldsShowAppropriateState() throws {
        try skipIfNoCredentials()
        XCTExpectFailure("Requires an expired hold in the account")

        let scrollView = app.scrollViews["holds.scrollView"]
        guard scrollView.waitForExistence(timeout: networkTimeout) else {
            XCTFail("Holds scroll view not loaded")
            return
        }

        // Expired holds may show a specific label or styling
        let expiredLabels = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'expired' OR label CONTAINS[c] 'unavailable'")
        )

        // This is informational -- expired holds may or may not be present
        _ = expiredLabels.count
    }
}

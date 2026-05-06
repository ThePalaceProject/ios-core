//
//  StatusAnnouncementTests.swift
//  PalaceTests
//
//  PP-3673: Tests verifying VoiceOver announces status updates without
//  moving focus, covering search, borrow/download, and error workflows.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace

// MARK: - Status Announcement Integration Tests (PP-3673)

final class StatusAnnouncementTests: XCTestCase {

    // MARK: - Helpers

    private class Capture {
        var items: [String] = []
        var notifications: [UIAccessibility.Notification] = []
        var expectation: XCTestExpectation?
    }

    private func makeAnnouncer(
        capture: Capture,
        voiceOverRunning: Bool = true,
        deduplicationInterval: TimeInterval = 0.0,
        timeProvider: @escaping () -> Date = { Date() }
    ) -> TPPAccessibilityAnnouncementCenter {
        TPPAccessibilityAnnouncementCenter(
            postHandler: { notification, message in
                capture.notifications.append(notification)
                capture.items.append(message)
                capture.expectation?.fulfill()
            },
            isVoiceOverRunning: { voiceOverRunning },
            timeProvider: timeProvider,
            deduplicationInterval: deduplicationInterval
        )
    }

    // MARK: - 1. Search Workflow Announcements

    func testPP3673_searchWithResults_announcesResultsForQuery() {
        let capture = Capture()
        capture.expectation = expectation(description: "announcement")
        let announcer = makeAnnouncer(capture: capture)

        announcer.announceSearchResults(query: "fantasy", count: 15)

        waitForExpectations(timeout: 5.0)
        XCTAssertEqual(capture.items.count, 1)
        let msg = capture.items[0]
        XCTAssertTrue(msg.contains("15"), "Should mention count")
        XCTAssertTrue(msg.contains("fantasy"), "Should mention query")
    }

    func testPP3673_searchNoResults_announcesNoResults() {
        let capture = Capture()
        capture.expectation = expectation(description: "announcement")
        let announcer = makeAnnouncer(capture: capture)

        announcer.announceSearchResults(query: "zzzznotfound", count: 0)

        waitForExpectations(timeout: 5.0)
        XCTAssertEqual(capture.items.count, 1)
        let msg = capture.items[0].lowercased()
        XCTAssertTrue(msg.contains("no results"), "Should say no results")
        XCTAssertTrue(msg.contains("zzzznotfound"), "Should include query")
    }

    func testPP3673_searchFailed_announces() {
        let capture = Capture()
        capture.expectation = expectation(description: "announcement")
        let announcer = makeAnnouncer(capture: capture)

        announcer.announceSearchFailed()

        waitForExpectations(timeout: 5.0)
        XCTAssertEqual(capture.items.count, 1)
        let msg = capture.items[0].lowercased()
        XCTAssertTrue(msg.contains("search") && msg.contains("failed"))
    }

    func testPP3673_searchRerun_announcesNewStatus() {
        var currentTime = Date(timeIntervalSince1970: 100)
        let capture = Capture()
        let exp = expectation(description: "announcements")
        exp.expectedFulfillmentCount = 2
        capture.expectation = exp
        let announcer = makeAnnouncer(
            capture: capture,
            deduplicationInterval: 2.0,
            timeProvider: { currentTime }
        )

        announcer.announceSearchResults(query: "robots", count: 5)
        currentTime = currentTime.addingTimeInterval(3.0)
        announcer.announceSearchResults(query: "robots", count: 0)

        waitForExpectations(timeout: 5.0)
        XCTAssertEqual(capture.items.count, 2, "Both results and no-results should be announced")
    }

    func testPP3673_searchAnnouncement_usesAnnouncementNotification() {
        let capture = Capture()
        capture.expectation = expectation(description: "announcement")
        let announcer = makeAnnouncer(capture: capture)

        announcer.announceSearchResults(query: "test", count: 3)

        waitForExpectations(timeout: 5.0)
        XCTAssertEqual(capture.notifications.count, 1)
        XCTAssertEqual(capture.notifications[0], UIAccessibility.Notification.announcement)
    }

    // MARK: - 2. Borrow / Checkout / Download Workflow Announcements

    func testPP3673_borrowStarted_announces() {
        let capture = Capture()
        capture.expectation = expectation(description: "announcement")
        let announcer = makeAnnouncer(capture: capture)

        announcer.announceBorrowStarted(title: "Moby Dick")

        waitForExpectations(timeout: 5.0)
        XCTAssertEqual(capture.items.count, 1)
        XCTAssertTrue(capture.items[0].contains("Moby Dick"))
    }

    func testPP3673_borrowSucceeded_announcesWithoutFocusShift() {
        let capture = Capture()
        capture.expectation = expectation(description: "announcement")
        let announcer = makeAnnouncer(capture: capture)

        announcer.announceBorrowSucceeded(title: "The Odyssey")

        waitForExpectations(timeout: 5.0)
        XCTAssertEqual(capture.items.count, 1)
        XCTAssertTrue(capture.items[0].contains("The Odyssey"))
        XCTAssertEqual(capture.notifications[0], UIAccessibility.Notification.announcement,
                       "Must use .announcement to avoid moving focus")
    }

    func testPP3673_borrowFailed_announces() {
        let capture = Capture()
        capture.expectation = expectation(description: "announcement")
        let announcer = makeAnnouncer(capture: capture)

        announcer.announceBorrowFailed(title: "War and Peace")

        waitForExpectations(timeout: 5.0)
        XCTAssertEqual(capture.items.count, 1)
        XCTAssertTrue(capture.items[0].contains("War and Peace"))
        let msg = capture.items[0].lowercased()
        XCTAssertTrue(msg.contains("failed"), "Should indicate failure")
    }

    func testPP3673_downloadStarted_announces() {
        let capture = Capture()
        capture.expectation = expectation(description: "announcement")
        let announcer = makeAnnouncer(capture: capture)

        announcer.announceDownloadStarted(title: "Dune")

        waitForExpectations(timeout: 5.0)
        XCTAssertEqual(capture.items.count, 1)
        XCTAssertTrue(capture.items[0].contains("Dune"))
    }

    func testPP3673_downloadCompleted_announces() {
        let capture = Capture()
        capture.expectation = expectation(description: "announcement")
        let announcer = makeAnnouncer(capture: capture)

        announcer.announceDownloadCompleted(title: "1984")

        waitForExpectations(timeout: 5.0)
        XCTAssertEqual(capture.items.count, 1)
        XCTAssertTrue(capture.items[0].contains("1984"))
    }

    func testPP3673_downloadFailed_announces() {
        let capture = Capture()
        capture.expectation = expectation(description: "announcement")
        let announcer = makeAnnouncer(capture: capture)

        announcer.announceDownloadFailed(title: "Catch-22")

        waitForExpectations(timeout: 5.0)
        XCTAssertEqual(capture.items.count, 1)
        let msg = capture.items[0].lowercased()
        XCTAssertTrue(msg.contains("failed") || msg.contains("could not"), "Should indicate failure")
    }

    func testPP3673_borrowLifecycle_producesSequentialAnnouncements() {
        let capture = Capture()
        let exp = expectation(description: "announcements")
        exp.expectedFulfillmentCount = 2
        capture.expectation = exp
        let announcer = makeAnnouncer(capture: capture)

        announcer.announceBorrowStarted(title: "The Hobbit")
        announcer.announceBorrowSucceeded(title: "The Hobbit")

        waitForExpectations(timeout: 5.0)
        XCTAssertEqual(capture.items.count, 2,
                       "Both started and succeeded should be announced")
        XCTAssertTrue(capture.items[0].lowercased().contains("started") ||
                      capture.items[0].lowercased().contains("borrow"))
        XCTAssertTrue(capture.items[1].lowercased().contains("borrowed"))
    }

    // MARK: - 3. Error Message Announcements

    func testPP3673_errorMessage_announcedViaVoiceOver() {
        let capture = Capture()
        capture.expectation = expectation(description: "announcement")
        let announcer = makeAnnouncer(capture: capture)

        announcer.announceError("Unable to connect to server.")

        waitForExpectations(timeout: 5.0)
        XCTAssertEqual(capture.items, ["Unable to connect to server."])
    }

    func testPP3673_statusWithTitleAndMessage_isClear() {
        let capture = Capture()
        capture.expectation = expectation(description: "announcement")
        let announcer = makeAnnouncer(capture: capture)

        announcer.announceStatus(title: "Borrow Failed", message: "The book is not available.")

        waitForExpectations(timeout: 5.0)
        XCTAssertEqual(capture.items.count, 1)
        let msg = capture.items[0]
        XCTAssertTrue(msg.contains("Borrow Failed"))
        XCTAssertTrue(msg.contains("The book is not available."))
    }

    func testPP3673_errorAnnouncement_doesNotMoveFocus() {
        let capture = Capture()
        capture.expectation = expectation(description: "announcement")
        let announcer = makeAnnouncer(capture: capture)

        announcer.announceError("Network error")

        waitForExpectations(timeout: 5.0)
        XCTAssertEqual(capture.notifications.count, 1)
        XCTAssertEqual(capture.notifications[0], UIAccessibility.Notification.announcement,
                       "Error must use .announcement to avoid moving VoiceOver focus")
    }

    // MARK: - 4. Deduplication / Flood Prevention

    func testPP3673_quickSuccession_sameMessage_collapsed() {
        let currentTime = Date(timeIntervalSince1970: 1000)
        let capture = Capture()
        capture.expectation = expectation(description: "single announcement")
        let announcer = makeAnnouncer(
            capture: capture,
            deduplicationInterval: 2.0,
            timeProvider: { currentTime }
        )

        announcer.announceError("Error A")
        announcer.announceError("Error A")
        announcer.announceError("Error A")

        waitForExpectations(timeout: 5.0)
        XCTAssertEqual(capture.items.count, 1,
                       "Duplicate messages in quick succession should collapse to 1")
    }

    func testPP3673_updatedStatus_replacesOld() {
        let capture = Capture()
        let exp = expectation(description: "announcements")
        exp.expectedFulfillmentCount = 2
        capture.expectation = exp
        let announcer = makeAnnouncer(capture: capture, deduplicationInterval: 0)

        announcer.announceMessage("Loading…")
        announcer.announceSearchResults(query: "test", count: 10)

        waitForExpectations(timeout: 5.0)
        XCTAssertEqual(capture.items.count, 2,
                       "Different messages should both be announced")
    }

    func testPP3673_differentMessages_allAnnounced() {
        let capture = Capture()
        let exp = expectation(description: "announcements")
        exp.expectedFulfillmentCount = 3
        capture.expectation = exp
        let announcer = makeAnnouncer(capture: capture, deduplicationInterval: 0)

        announcer.announceBorrowStarted(title: "Book A")
        announcer.announceBorrowSucceeded(title: "Book A")
        announcer.announceDownloadStarted(title: "Book A")

        waitForExpectations(timeout: 5.0)
        XCTAssertEqual(capture.items.count, 3,
                       "All distinct messages should be announced")
    }

    // MARK: - 5. WCAG Conformance Checks

    func testPP3673_allAnnouncementTypes_areProgrammaticallyDeterminable() {
        let capture = Capture()
        let exp = expectation(description: "announcements")
        exp.expectedFulfillmentCount = 17
        capture.expectation = exp
        let announcer = makeAnnouncer(capture: capture)

        announcer.announceSearchResults(query: "test", count: 5)
        announcer.announceSearchFailed()
        announcer.announceBorrowStarted(title: "T")
        announcer.announceBorrowSucceeded(title: "T")
        announcer.announceBorrowFailed(title: "T")
        announcer.announceDownloadStarted(title: "T")
        announcer.announceDownloadCompleted(title: "T")
        announcer.announceDownloadFailed(title: "T")
        announcer.announceReturnStarted(title: "T")
        announcer.announceReturnSucceeded(title: "T")
        announcer.announceReturnFailed(title: "T")
        announcer.announceError("Error")
        announcer.announceStatus(title: "Title", message: "Msg")
        announcer.announceMessage("Custom status")
        announcer.announceRetryingBorrow(title: "T")
        announcer.announceRetryingReturn(title: "T")
        announcer.announceRetryingDownload(title: "T")

        waitForExpectations(timeout: 5.0)
        XCTAssertEqual(capture.items.count, 17, "All 17 announcement methods should produce output")

        for (index, notification) in capture.notifications.enumerated() {
            XCTAssertEqual(notification, UIAccessibility.Notification.announcement,
                           "Announcement at index \(index) must use .announcement — WCAG 4.1.2 requires no focus change")
        }
    }

    func testPP3673_voiceOverDisabled_noAnnouncements() {
        let capture = Capture()
        let announcer = makeAnnouncer(capture: capture, voiceOverRunning: false)

        announcer.announceSearchResults(query: "test", count: 5)
        announcer.announceSearchFailed()
        announcer.announceBorrowStarted(title: "T")
        announcer.announceBorrowSucceeded(title: "T")
        announcer.announceBorrowFailed(title: "T")
        announcer.announceDownloadStarted(title: "T")
        announcer.announceDownloadCompleted(title: "T")
        announcer.announceDownloadFailed(title: "T")
        announcer.announceError("Error")
        announcer.announceMessage("Status")

        XCTAssertTrue(capture.items.isEmpty, "No announcements when VoiceOver is off")
    }

    // MARK: - 6. Localized String Sanity

    func testPP3673_searchStrings_areLocalized() {
        let resultsMsg = Strings.SearchAnnouncements.searchResultsFound("test", count: 5)
        XCTAssertFalse(resultsMsg.isEmpty)
        XCTAssertTrue(resultsMsg.contains("5"))
        XCTAssertTrue(resultsMsg.contains("test"))

        let noResultsMsg = Strings.SearchAnnouncements.noSearchResults("test")
        XCTAssertFalse(noResultsMsg.isEmpty)
        XCTAssertTrue(noResultsMsg.contains("test"))

        let failedMsg = Strings.SearchAnnouncements.searchFailed()
        XCTAssertFalse(failedMsg.isEmpty)

        let additionalMsg = Strings.SearchAnnouncements.additionalResultsLoaded(10)
        XCTAssertFalse(additionalMsg.isEmpty)
        XCTAssertTrue(additionalMsg.contains("10"))
    }

    func testPP3673_statusStrings_areUnderstandable() {
        let errorMsg = Strings.StatusAnnouncements.errorOccurred("Server error")
        XCTAssertEqual(errorMsg, "Server error")

        let failedMsg = Strings.StatusAnnouncements.actionFailed(title: "Borrow Failed", message: "Try again later.")
        XCTAssertTrue(failedMsg.contains("Borrow Failed"))
        XCTAssertTrue(failedMsg.contains("Try again later."))
    }
}

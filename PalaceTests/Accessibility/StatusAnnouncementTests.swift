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

    /// Reference-type wrapper so captured closures share the same storage.
    private class Capture {
        var items: [String] = []
        var notifications: [UIAccessibility.Notification] = []
    }

    private func makeAnnouncer(
        capture: Capture,
        voiceOverRunning: Bool = true,
        deduplicationInterval: TimeInterval = 0.0
    ) -> TPPAccessibilityAnnouncementCenter {
        TPPAccessibilityAnnouncementCenter(
            postHandler: { notification, message in
                capture.notifications.append(notification)
                capture.items.append(message)
            },
            isVoiceOverRunning: { voiceOverRunning },
            deduplicationInterval: deduplicationInterval
        )
    }

    // MARK: - 1. Search Workflow Announcements

    /// PP-3673 AC 2: Search with results announces "Showing results for <query>".
    func testPP3673_searchWithResults_announcesResultsForQuery() {
        let capture = Capture()
        let announcer = makeAnnouncer(capture: capture)

        announcer.announceSearchResults(query: "fantasy", count: 15)

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertEqual(capture.items.count, 1)
        let msg = capture.items[0]
        XCTAssertTrue(msg.contains("15"), "Should mention count")
        XCTAssertTrue(msg.contains("fantasy"), "Should mention query")
    }

    /// PP-3673 AC 2: Search with no results announces "no results found".
    func testPP3673_searchNoResults_announcesNoResults() {
        let capture = Capture()
        let announcer = makeAnnouncer(capture: capture)

        announcer.announceSearchResults(query: "zzzznotfound", count: 0)

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertEqual(capture.items.count, 1)
        let msg = capture.items[0].lowercased()
        XCTAssertTrue(msg.contains("no results"), "Should say no results")
        XCTAssertTrue(msg.contains("zzzznotfound"), "Should include query")
    }

    /// PP-3673 AC 2: Search failure announces an error.
    func testPP3673_searchFailed_announces() {
        let capture = Capture()
        let announcer = makeAnnouncer(capture: capture)

        announcer.announceSearchFailed()

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertEqual(capture.items.count, 1)
        let msg = capture.items[0].lowercased()
        XCTAssertTrue(msg.contains("search") && msg.contains("failed"))
    }

    /// PP-3673 AC 2: Re-run search announces new status.
    func testPP3673_searchRerun_announcesNewStatus() {
        var currentTime = Date(timeIntervalSince1970: 100)
        let capture = Capture()
        let announcer = TPPAccessibilityAnnouncementCenter(
            postHandler: { _, message in capture.items.append(message) },
            isVoiceOverRunning: { true },
            timeProvider: { currentTime },
            deduplicationInterval: 2.0
        )

        announcer.announceSearchResults(query: "robots", count: 5)
        currentTime = currentTime.addingTimeInterval(3.0)
        announcer.announceSearchResults(query: "robots", count: 0)

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertEqual(capture.items.count, 2, "Both results and no-results should be announced")
    }

    /// PP-3673 AC 2: Announcement does NOT shift focus — uses .announcement, not .screenChanged.
    func testPP3673_searchAnnouncement_usesAnnouncementNotification() {
        let capture = Capture()
        let announcer = makeAnnouncer(capture: capture)

        announcer.announceSearchResults(query: "test", count: 3)

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertEqual(capture.notifications.count, 1)
        XCTAssertEqual(capture.notifications[0], UIAccessibility.Notification.announcement)
    }

    // MARK: - 2. Borrow / Checkout / Download Workflow Announcements

    /// PP-3673 AC 3: Borrow started is announced.
    func testPP3673_borrowStarted_announces() {
        let capture = Capture()
        let announcer = makeAnnouncer(capture: capture)

        announcer.announceBorrowStarted(title: "Moby Dick")

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertEqual(capture.items.count, 1)
        XCTAssertTrue(capture.items[0].contains("Moby Dick"))
    }

    /// PP-3673 AC 3: Borrow success is announced without focus shift.
    func testPP3673_borrowSucceeded_announcesWithoutFocusShift() {
        let capture = Capture()
        let announcer = makeAnnouncer(capture: capture)

        announcer.announceBorrowSucceeded(title: "The Odyssey")

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertEqual(capture.items.count, 1)
        XCTAssertTrue(capture.items[0].contains("The Odyssey"))
        XCTAssertEqual(capture.notifications[0], UIAccessibility.Notification.announcement,
                       "Must use .announcement to avoid moving focus")
    }

    /// PP-3673 AC 3: Borrow failure is announced.
    func testPP3673_borrowFailed_announces() {
        let capture = Capture()
        let announcer = makeAnnouncer(capture: capture)

        announcer.announceBorrowFailed(title: "War and Peace")

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertEqual(capture.items.count, 1)
        XCTAssertTrue(capture.items[0].contains("War and Peace"))
        let msg = capture.items[0].lowercased()
        XCTAssertTrue(msg.contains("failed"), "Should indicate failure")
    }

    /// PP-3673 AC 3: Download started is announced.
    func testPP3673_downloadStarted_announces() {
        let capture = Capture()
        let announcer = makeAnnouncer(capture: capture)

        announcer.announceDownloadStarted(title: "Dune")

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertEqual(capture.items.count, 1)
        XCTAssertTrue(capture.items[0].contains("Dune"))
    }

    /// PP-3673 AC 3: Download completed is announced.
    func testPP3673_downloadCompleted_announces() {
        let capture = Capture()
        let announcer = makeAnnouncer(capture: capture)

        announcer.announceDownloadCompleted(title: "1984")

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertEqual(capture.items.count, 1)
        XCTAssertTrue(capture.items[0].contains("1984"))
    }

    /// PP-3673 AC 3: Download failure is announced.
    func testPP3673_downloadFailed_announces() {
        let capture = Capture()
        let announcer = makeAnnouncer(capture: capture)

        announcer.announceDownloadFailed(title: "Catch-22")

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertEqual(capture.items.count, 1)
        let msg = capture.items[0].lowercased()
        XCTAssertTrue(msg.contains("failed") || msg.contains("could not"), "Should indicate failure")
    }

    /// PP-3673 AC 3: Full borrow lifecycle (started → succeeded) produces two distinct announcements.
    func testPP3673_borrowLifecycle_producesSequentialAnnouncements() {
        let capture = Capture()
        let announcer = makeAnnouncer(capture: capture)

        announcer.announceBorrowStarted(title: "The Hobbit")
        announcer.announceBorrowSucceeded(title: "The Hobbit")

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertEqual(capture.items.count, 2,
                       "Both started and succeeded should be announced")
        XCTAssertTrue(capture.items[0].lowercased().contains("started") ||
                      capture.items[0].lowercased().contains("borrow"))
        XCTAssertTrue(capture.items[1].lowercased().contains("borrowed"))
    }

    // MARK: - 3. Error Message Announcements

    /// PP-3673 AC 4: Error messages are announced via VoiceOver.
    func testPP3673_errorMessage_announcedViaVoiceOver() {
        let capture = Capture()
        let announcer = makeAnnouncer(capture: capture)

        announcer.announceError("Unable to connect to server.")

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertEqual(capture.items, ["Unable to connect to server."])
    }

    /// PP-3673 AC 4: Status with title and message produces a clear combined announcement.
    func testPP3673_statusWithTitleAndMessage_isClear() {
        let capture = Capture()
        let announcer = makeAnnouncer(capture: capture)

        announcer.announceStatus(title: "Borrow Failed", message: "The book is not available.")

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertEqual(capture.items.count, 1)
        let msg = capture.items[0]
        XCTAssertTrue(msg.contains("Borrow Failed"))
        XCTAssertTrue(msg.contains("The book is not available."))
    }

    /// PP-3673 AC 4: Error announcement uses .announcement to avoid focus shift.
    func testPP3673_errorAnnouncement_doesNotMoveFocus() {
        let capture = Capture()
        let announcer = makeAnnouncer(capture: capture)

        announcer.announceError("Network error")

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertEqual(capture.notifications.count, 1)
        XCTAssertEqual(capture.notifications[0], UIAccessibility.Notification.announcement,
                       "Error must use .announcement to avoid moving VoiceOver focus")
    }

    // MARK: - 4. Deduplication / Flood Prevention

    /// PP-3673 AC 1: Identical messages in quick succession are collapsed.
    func testPP3673_quickSuccession_sameMessage_collapsed() {
        let currentTime = Date(timeIntervalSince1970: 1000)
        let capture = Capture()
        let announcer = TPPAccessibilityAnnouncementCenter(
            postHandler: { _, message in capture.items.append(message) },
            isVoiceOverRunning: { true },
            timeProvider: { currentTime },
            deduplicationInterval: 2.0
        )

        announcer.announceError("Error A")
        announcer.announceError("Error A")
        announcer.announceError("Error A")

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertEqual(capture.items.count, 1,
                       "Duplicate messages in quick succession should collapse to 1")
    }

    /// PP-3673 AC 1: Updated status replaces prior — "Loading…" then "10 results" are both announced.
    func testPP3673_updatedStatus_replacesOld() {
        let capture = Capture()
        let announcer = makeAnnouncer(capture: capture, deduplicationInterval: 0)

        announcer.announceMessage("Loading…")
        announcer.announceSearchResults(query: "test", count: 10)

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertEqual(capture.items.count, 2,
                       "Different messages should both be announced")
    }

    /// PP-3673 AC 1: Multiple different status messages in quick succession are all announced.
    func testPP3673_differentMessages_allAnnounced() {
        let capture = Capture()
        let announcer = makeAnnouncer(capture: capture, deduplicationInterval: 0)

        announcer.announceBorrowStarted(title: "Book A")
        announcer.announceBorrowSucceeded(title: "Book A")
        announcer.announceDownloadStarted(title: "Book A")

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertEqual(capture.items.count, 3,
                       "All distinct messages should be announced")
    }

    // MARK: - 5. WCAG Conformance Checks

    /// PP-3673 AC 5: All status announcements are programmatically determinable (use .announcement).
    func testPP3673_allAnnouncementTypes_areProgrammaticallyDeterminable() {
        let capture = Capture()
        let announcer = makeAnnouncer(capture: capture)

        // Exercise all announcement types
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

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertEqual(capture.items.count, 17, "All 17 announcement methods should produce output")

        for (index, notification) in capture.notifications.enumerated() {
            XCTAssertEqual(notification, UIAccessibility.Notification.announcement,
                           "Announcement at index \(index) must use .announcement — WCAG 4.1.2 requires no focus change")
        }
    }

    /// PP-3673 AC 5: VoiceOver disabled means zero announcements for all types.
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

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertTrue(capture.items.isEmpty, "No announcements when VoiceOver is off")
    }

    // MARK: - 6. Localized String Sanity

    /// PP-3673: Search announcement strings are properly localized (not raw keys).
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

    /// PP-3673: Status announcement strings produce understandable output.
    func testPP3673_statusStrings_areUnderstandable() {
        let errorMsg = Strings.StatusAnnouncements.errorOccurred("Server error")
        XCTAssertEqual(errorMsg, "Server error")

        let failedMsg = Strings.StatusAnnouncements.actionFailed(title: "Borrow Failed", message: "Try again later.")
        XCTAssertTrue(failedMsg.contains("Borrow Failed"))
        XCTAssertTrue(failedMsg.contains("Try again later."))
    }
}

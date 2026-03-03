//
//  AccessibilityAnnouncementCenterTests.swift
//  PalaceTests
//
//  Created by The Palace Project on 2/6/26.
//

import XCTest
@testable import Palace

final class AccessibilityAnnouncementCenterTests: XCTestCase {

    // MARK: - Helpers

    /// Creates an announcement center wired to capture announcements synchronously.
    /// The returned `announcements` array collects every message posted.
    private func makeAnnouncer(
        voiceOverRunning: Bool = true,
        deduplicationInterval: TimeInterval = 2.0,
        time: @escaping () -> Date = { Date() }
    ) -> (TPPAccessibilityAnnouncementCenter, Announcements) {
        let store = Announcements()
        let announcer = TPPAccessibilityAnnouncementCenter(
            postHandler: { _, message in store.items.append(message) },
            isVoiceOverRunning: { voiceOverRunning },
            timeProvider: time,
            deduplicationInterval: deduplicationInterval
        )
        return (announcer, store)
    }

    /// Reference-type wrapper so captured closures share the same storage.
    private class Announcements {
        var items: [String] = []
    }

    // MARK: - Download Progress (PP-3594 regression)

    func testPP3594_downloadProgress_throttlesAnnouncements() {
        var announcements: [String] = []
        let expectedCount = 2
        let expectation = expectation(description: "Progress announcements posted")
        expectation.expectedFulfillmentCount = expectedCount

        let announcer = TPPAccessibilityAnnouncementCenter(
            postHandler: { _, message in
                announcements.append(message)
                expectation.fulfill()
            },
            isVoiceOverRunning: { true },
            progressStep: 20
        )

        announcer.announceDownloadProgress(title: "Sample Book", identifier: "book-1", progress: 0.10)
        announcer.announceDownloadProgress(title: "Sample Book", identifier: "book-1", progress: 0.20)
        announcer.announceDownloadProgress(title: "Sample Book", identifier: "book-1", progress: 0.25)
        announcer.announceDownloadProgress(title: "Sample Book", identifier: "book-1", progress: 0.40)
        announcer.announceDownloadProgress(title: "Sample Book", identifier: "book-1", progress: 1.00)

        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(
            announcements,
            [
                "Download 20 percent complete for Sample Book.",
                "Download 40 percent complete for Sample Book."
            ]
        )
    }

    func testPP3594_downloadAnnouncements_respectVoiceOverDisabled() {
        var announcements: [String] = []
        let announcer = TPPAccessibilityAnnouncementCenter(
            postHandler: { _, message in announcements.append(message) },
            isVoiceOverRunning: { false }
        )

        announcer.announceDownloadStarted(title: "Sample Book")
        announcer.announceDownloadCompleted(title: "Sample Book")

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertTrue(announcements.isEmpty)
    }

    func testPP3594_borrowAndReturnAnnouncements_postMessages() {
        var announcements: [String] = []
        let expectedCount = 2
        let expectation = expectation(description: "Borrow and return announcements posted")
        expectation.expectedFulfillmentCount = expectedCount

        let announcer = TPPAccessibilityAnnouncementCenter(
            postHandler: { _, message in
                announcements.append(message)
                expectation.fulfill()
            },
            isVoiceOverRunning: { true }
        )

        announcer.announceBorrowStarted(title: "Sample Book")
        announcer.announceReturnSucceeded(title: "Sample Book")

        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(
            announcements,
            [
                "Borrow started for Sample Book.",
                "Returned Sample Book."
            ]
        )
    }

    // MARK: - Search Announcements (PP-3673)

    /// PP-3673: When search results are found, VoiceOver announces count and query.
    func testPP3673_searchResults_announcesResultCountAndQuery() {
        let expectation = expectation(description: "Search result announcement")
        var announcements: [String] = []

        let announcer = TPPAccessibilityAnnouncementCenter(
            postHandler: { _, message in
                announcements.append(message)
                expectation.fulfill()
            },
            isVoiceOverRunning: { true }
        )

        announcer.announceSearchResults(query: "dragons", count: 12)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(announcements.count, 1)
        XCTAssertTrue(announcements[0].contains("12"))
        XCTAssertTrue(announcements[0].contains("dragons"))
    }

    /// PP-3673: When search returns no results, VoiceOver announces no-results message.
    func testPP3673_searchNoResults_announcesNoResults() {
        let expectation = expectation(description: "No results announcement")
        var announcements: [String] = []

        let announcer = TPPAccessibilityAnnouncementCenter(
            postHandler: { _, message in
                announcements.append(message)
                expectation.fulfill()
            },
            isVoiceOverRunning: { true }
        )

        announcer.announceSearchResults(query: "xyznonexistent", count: 0)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(announcements.count, 1)
        let msg = announcements[0].lowercased()
        XCTAssertTrue(msg.contains("no results"), "Should mention 'no results', got: \(msg)")
        XCTAssertTrue(msg.contains("xyznonexistent"))
    }

    /// PP-3673: When search fails, VoiceOver announces the failure.
    func testPP3673_searchFailed_announcesFailure() {
        let expectation = expectation(description: "Search failed announcement")
        var announcements: [String] = []

        let announcer = TPPAccessibilityAnnouncementCenter(
            postHandler: { _, message in
                announcements.append(message)
                expectation.fulfill()
            },
            isVoiceOverRunning: { true }
        )

        announcer.announceSearchFailed()

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(announcements.count, 1)
        let msg = announcements[0].lowercased()
        XCTAssertTrue(msg.contains("search") && msg.contains("failed"), "Should mention search failure, got: \(msg)")
    }

    /// PP-3673: Updated search (re-run) produces a new announcement with new count.
    func testPP3673_searchRerun_announcesUpdatedResults() {
        var currentTime = Date(timeIntervalSince1970: 1000)
        let expectation = expectation(description: "Two search announcements")
        expectation.expectedFulfillmentCount = 2
        var announcements: [String] = []

        let announcer = TPPAccessibilityAnnouncementCenter(
            postHandler: { _, message in
                announcements.append(message)
                expectation.fulfill()
            },
            isVoiceOverRunning: { true },
            timeProvider: { currentTime },
            deduplicationInterval: 2.0
        )

        announcer.announceSearchResults(query: "robots", count: 5)
        // Advance time past dedup window to ensure second announcement fires
        currentTime = currentTime.addingTimeInterval(3.0)
        announcer.announceSearchResults(query: "robots", count: 10)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(announcements.count, 2)
        XCTAssertTrue(announcements[0].contains("5"))
        XCTAssertTrue(announcements[1].contains("10"))
    }

    /// PP-3673: Additional results loaded during pagination are announced.
    func testPP3673_additionalResultsLoaded_announcesCount() {
        let expectation = expectation(description: "Additional results announcement")
        var announcements: [String] = []

        let announcer = TPPAccessibilityAnnouncementCenter(
            postHandler: { _, message in
                announcements.append(message)
                expectation.fulfill()
            },
            isVoiceOverRunning: { true }
        )

        announcer.announceAdditionalResultsLoaded(count: 20)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(announcements.count, 1)
        XCTAssertTrue(announcements[0].contains("20"))
    }

    /// PP-3673: Zero additional results should not produce an announcement.
    func testPP3673_additionalResultsLoaded_zeroCount_doesNotAnnounce() {
        let (announcer, store) = makeAnnouncer()

        announcer.announceAdditionalResultsLoaded(count: 0)

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertTrue(store.items.isEmpty)
    }

    // MARK: - Error / Status Announcements (PP-3673)

    /// PP-3673: Error messages are announced via VoiceOver.
    func testPP3673_announceError_postsMessage() {
        let expectation = expectation(description: "Error announcement")
        var announcements: [String] = []

        let announcer = TPPAccessibilityAnnouncementCenter(
            postHandler: { _, message in
                announcements.append(message)
                expectation.fulfill()
            },
            isVoiceOverRunning: { true }
        )

        announcer.announceError("Network connection lost.")

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(announcements, ["Network connection lost."])
    }

    /// PP-3673: Status with title+message combines them for a clear announcement.
    func testPP3673_announceStatus_combinesTitleAndMessage() {
        let expectation = expectation(description: "Status announcement")
        var announcements: [String] = []

        let announcer = TPPAccessibilityAnnouncementCenter(
            postHandler: { _, message in
                announcements.append(message)
                expectation.fulfill()
            },
            isVoiceOverRunning: { true }
        )

        announcer.announceStatus(title: "Borrow Failed", message: "Could not complete borrowing.")

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(announcements.count, 1)
        XCTAssertTrue(announcements[0].contains("Borrow Failed"))
        XCTAssertTrue(announcements[0].contains("Could not complete borrowing."))
    }

    /// PP-3673: General-purpose announceMessage works.
    func testPP3673_announceMessage_postsArbitraryMessage() {
        let expectation = expectation(description: "General announcement")
        var announcements: [String] = []

        let announcer = TPPAccessibilityAnnouncementCenter(
            postHandler: { _, message in
                announcements.append(message)
                expectation.fulfill()
            },
            isVoiceOverRunning: { true }
        )

        announcer.announceMessage("Catalog loaded successfully.")

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(announcements, ["Catalog loaded successfully."])
    }

    // MARK: - Deduplication (PP-3673)

    /// PP-3673: Identical messages within the deduplication window are suppressed.
    func testPP3673_deduplication_suppressesDuplicateWithinWindow() {
        var currentTime = Date(timeIntervalSince1970: 1000)
        let (announcer, store) = makeAnnouncer(deduplicationInterval: 2.0) { currentTime }

        announcer.announceError("Something went wrong.")
        // Same message, 0.5s later — should be suppressed
        currentTime = currentTime.addingTimeInterval(0.5)
        announcer.announceError("Something went wrong.")

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertEqual(store.items.count, 1, "Duplicate within window should be suppressed")
    }

    /// PP-3673: Same message after deduplication window passes is allowed.
    func testPP3673_deduplication_allowsRepeatAfterWindowExpires() {
        var currentTime = Date(timeIntervalSince1970: 1000)
        let (announcer, store) = makeAnnouncer(deduplicationInterval: 2.0) { currentTime }

        announcer.announceError("Something went wrong.")
        // Advance past dedup window
        currentTime = currentTime.addingTimeInterval(3.0)
        announcer.announceError("Something went wrong.")

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertEqual(store.items.count, 2, "Should allow repeat after window expires")
    }

    /// PP-3673: Different messages within the window are NOT suppressed.
    func testPP3673_deduplication_allowsDifferentMessages() {
        var currentTime = Date(timeIntervalSince1970: 1000)
        let (announcer, store) = makeAnnouncer(deduplicationInterval: 2.0) { currentTime }

        announcer.announceError("Error A")
        currentTime = currentTime.addingTimeInterval(0.1)
        announcer.announceError("Error B")

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertEqual(store.items, ["Error A", "Error B"])
    }

    /// PP-3673: Rapid-fire identical messages result in only one announcement.
    func testPP3673_deduplication_rapidFireSameMessage_onlyOneAnnouncement() {
        let currentTime = Date(timeIntervalSince1970: 1000)
        let (announcer, store) = makeAnnouncer(deduplicationInterval: 2.0) { currentTime }

        for _ in 0..<10 {
            announcer.announceError("Rapid error")
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertEqual(store.items.count, 1, "10 rapid duplicates should collapse to 1")
    }

    /// PP-3673: Deduplication applies across announcement types using same message text.
    func testPP3673_deduplication_crossMethod_sameText() {
        let currentTime = Date(timeIntervalSince1970: 1000)
        let (announcer, store) = makeAnnouncer(deduplicationInterval: 2.0) { currentTime }

        announcer.announceMessage("Hello")
        announcer.announceError("Hello")

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertEqual(store.items.count, 1, "Same text across methods should deduplicate")
    }

    // MARK: - VoiceOver Guard (PP-3673)

    /// PP-3673: Search announcements are suppressed when VoiceOver is off.
    func testPP3673_searchAnnouncements_respectVoiceOverDisabled() {
        let (announcer, store) = makeAnnouncer(voiceOverRunning: false)

        announcer.announceSearchResults(query: "test", count: 5)
        announcer.announceSearchFailed()
        announcer.announceAdditionalResultsLoaded(count: 10)

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertTrue(store.items.isEmpty, "No announcements when VoiceOver is off")
    }

    /// PP-3673: Error announcements are suppressed when VoiceOver is off.
    func testPP3673_errorAnnouncements_respectVoiceOverDisabled() {
        let (announcer, store) = makeAnnouncer(voiceOverRunning: false)

        announcer.announceError("Big problem")
        announcer.announceStatus(title: "Error", message: "Something broke")
        announcer.announceMessage("Status update")

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertTrue(store.items.isEmpty, "No announcements when VoiceOver is off")
    }

    // MARK: - Empty Message Guard (PP-3673)

    /// PP-3673: Empty messages are never posted.
    func testPP3673_emptyMessage_isNotPosted() {
        let (announcer, store) = makeAnnouncer()

        announcer.announceMessage("")
        announcer.announceError("")

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertTrue(store.items.isEmpty, "Empty messages should not be posted")
    }

    // MARK: - Notification Type

    /// PP-3673: All announcements use .announcement notification type (not .screenChanged or .layoutChanged).
    func testPP3673_allAnnouncements_useAnnouncementNotificationType() {
        var notifications: [UIAccessibility.Notification] = []
        let expectation = expectation(description: "Announcements posted")
        expectation.expectedFulfillmentCount = 3

        let announcer = TPPAccessibilityAnnouncementCenter(
            postHandler: { notification, _ in
                notifications.append(notification)
                expectation.fulfill()
            },
            isVoiceOverRunning: { true }
        )

        announcer.announceSearchResults(query: "test", count: 1)
        announcer.announceError("Error happened")
        announcer.announceMessage("Status update")

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(notifications.count, 3)
        for notification in notifications {
            XCTAssertEqual(notification, UIAccessibility.Notification.announcement,
                           "All status announcements must use .announcement to avoid moving focus")
        }
    }
}

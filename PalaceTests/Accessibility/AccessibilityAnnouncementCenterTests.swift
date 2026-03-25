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

    private func makeAnnouncer(
        voiceOverRunning: Bool = true,
        deduplicationInterval: TimeInterval = 2.0,
        time: @escaping () -> Date = { Date() }
    ) -> (TPPAccessibilityAnnouncementCenter, Announcements) {
        let store = Announcements()
        let announcer = TPPAccessibilityAnnouncementCenter(
            postHandler: { _, message in
                store.items.append(message)
                store.expectation?.fulfill()
            },
            isVoiceOverRunning: { voiceOverRunning },
            timeProvider: time,
            deduplicationInterval: deduplicationInterval
        )
        return (announcer, store)
    }

    private class Announcements {
        var items: [String] = []
        var expectation: XCTestExpectation?
    }

    // MARK: - Download Progress (PP-3594 regression)

    func testPP3594_downloadProgress_throttlesAnnouncements() {
        var announcements: [String] = []
        let expectedCount = 2
        let exp = expectation(description: "Progress announcements posted")
        exp.expectedFulfillmentCount = expectedCount

        let announcer = TPPAccessibilityAnnouncementCenter(
            postHandler: { _, message in
                announcements.append(message)
                exp.fulfill()
            },
            isVoiceOverRunning: { true },
            progressStep: 20
        )

        announcer.announceDownloadProgress(title: "Sample Book", identifier: "book-1", progress: 0.10)
        announcer.announceDownloadProgress(title: "Sample Book", identifier: "book-1", progress: 0.20)
        announcer.announceDownloadProgress(title: "Sample Book", identifier: "book-1", progress: 0.25)
        announcer.announceDownloadProgress(title: "Sample Book", identifier: "book-1", progress: 0.40)
        announcer.announceDownloadProgress(title: "Sample Book", identifier: "book-1", progress: 1.00)

        waitForExpectations(timeout: 5.0)

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

        XCTAssertTrue(announcements.isEmpty)
    }

    func testPP3594_borrowAndReturnAnnouncements_postMessages() {
        var announcements: [String] = []
        let expectedCount = 2
        let exp = expectation(description: "Borrow and return announcements posted")
        exp.expectedFulfillmentCount = expectedCount

        let announcer = TPPAccessibilityAnnouncementCenter(
            postHandler: { _, message in
                announcements.append(message)
                exp.fulfill()
            },
            isVoiceOverRunning: { true }
        )

        announcer.announceBorrowStarted(title: "Sample Book")
        announcer.announceReturnSucceeded(title: "Sample Book")

        waitForExpectations(timeout: 5.0)

        XCTAssertEqual(
            announcements,
            [
                "Borrow started for Sample Book.",
                "Returned Sample Book."
            ]
        )
    }

    // MARK: - Search Announcements (PP-3673)

    func testPP3673_searchResults_announcesResultCountAndQuery() {
        let exp = expectation(description: "Search result announcement")
        var announcements: [String] = []

        let announcer = TPPAccessibilityAnnouncementCenter(
            postHandler: { _, message in
                announcements.append(message)
                exp.fulfill()
            },
            isVoiceOverRunning: { true }
        )

        announcer.announceSearchResults(query: "dragons", count: 12)

        waitForExpectations(timeout: 5.0)
        XCTAssertEqual(announcements.count, 1)
        XCTAssertTrue(announcements[0].contains("12"))
        XCTAssertTrue(announcements[0].contains("dragons"))
    }

    func testPP3673_searchNoResults_announcesNoResults() {
        let exp = expectation(description: "No results announcement")
        var announcements: [String] = []

        let announcer = TPPAccessibilityAnnouncementCenter(
            postHandler: { _, message in
                announcements.append(message)
                exp.fulfill()
            },
            isVoiceOverRunning: { true }
        )

        announcer.announceSearchResults(query: "xyznonexistent", count: 0)

        waitForExpectations(timeout: 5.0)
        XCTAssertEqual(announcements.count, 1)
        let msg = announcements[0].lowercased()
        XCTAssertTrue(msg.contains("no results"), "Should mention 'no results', got: \(msg)")
        XCTAssertTrue(msg.contains("xyznonexistent"))
    }

    func testPP3673_searchFailed_announcesFailure() {
        let exp = expectation(description: "Search failed announcement")
        var announcements: [String] = []

        let announcer = TPPAccessibilityAnnouncementCenter(
            postHandler: { _, message in
                announcements.append(message)
                exp.fulfill()
            },
            isVoiceOverRunning: { true }
        )

        announcer.announceSearchFailed()

        waitForExpectations(timeout: 5.0)
        XCTAssertEqual(announcements.count, 1)
        let msg = announcements[0].lowercased()
        XCTAssertTrue(msg.contains("search") && msg.contains("failed"), "Should mention search failure, got: \(msg)")
    }

    func testPP3673_searchRerun_announcesUpdatedResults() {
        var currentTime = Date(timeIntervalSince1970: 1000)
        let exp = expectation(description: "Two search announcements")
        exp.expectedFulfillmentCount = 2
        var announcements: [String] = []

        let announcer = TPPAccessibilityAnnouncementCenter(
            postHandler: { _, message in
                announcements.append(message)
                exp.fulfill()
            },
            isVoiceOverRunning: { true },
            timeProvider: { currentTime },
            deduplicationInterval: 2.0
        )

        announcer.announceSearchResults(query: "robots", count: 5)
        currentTime = currentTime.addingTimeInterval(3.0)
        announcer.announceSearchResults(query: "robots", count: 10)

        waitForExpectations(timeout: 5.0)
        XCTAssertEqual(announcements.count, 2)
        XCTAssertTrue(announcements[0].contains("5"))
        XCTAssertTrue(announcements[1].contains("10"))
    }

    func testPP3673_additionalResultsLoaded_announcesCount() {
        let exp = expectation(description: "Additional results announcement")
        var announcements: [String] = []

        let announcer = TPPAccessibilityAnnouncementCenter(
            postHandler: { _, message in
                announcements.append(message)
                exp.fulfill()
            },
            isVoiceOverRunning: { true }
        )

        announcer.announceAdditionalResultsLoaded(count: 20)

        waitForExpectations(timeout: 5.0)
        XCTAssertEqual(announcements.count, 1)
        XCTAssertTrue(announcements[0].contains("20"))
    }

    func testPP3673_additionalResultsLoaded_zeroCount_doesNotAnnounce() {
        let (announcer, store) = makeAnnouncer()

        announcer.announceAdditionalResultsLoaded(count: 0)

        XCTAssertTrue(store.items.isEmpty)
    }

    // MARK: - Error / Status Announcements (PP-3673)

    func testPP3673_announceError_postsMessage() {
        let exp = expectation(description: "Error announcement")
        var announcements: [String] = []

        let announcer = TPPAccessibilityAnnouncementCenter(
            postHandler: { _, message in
                announcements.append(message)
                exp.fulfill()
            },
            isVoiceOverRunning: { true }
        )

        announcer.announceError("Network connection lost.")

        waitForExpectations(timeout: 5.0)
        XCTAssertEqual(announcements, ["Network connection lost."])
    }

    func testPP3673_announceStatus_combinesTitleAndMessage() {
        let exp = expectation(description: "Status announcement")
        var announcements: [String] = []

        let announcer = TPPAccessibilityAnnouncementCenter(
            postHandler: { _, message in
                announcements.append(message)
                exp.fulfill()
            },
            isVoiceOverRunning: { true }
        )

        announcer.announceStatus(title: "Borrow Failed", message: "Could not complete borrowing.")

        waitForExpectations(timeout: 5.0)
        XCTAssertEqual(announcements.count, 1)
        XCTAssertTrue(announcements[0].contains("Borrow Failed"))
        XCTAssertTrue(announcements[0].contains("Could not complete borrowing."))
    }

    func testPP3673_announceMessage_postsArbitraryMessage() {
        let exp = expectation(description: "General announcement")
        var announcements: [String] = []

        let announcer = TPPAccessibilityAnnouncementCenter(
            postHandler: { _, message in
                announcements.append(message)
                exp.fulfill()
            },
            isVoiceOverRunning: { true }
        )

        announcer.announceMessage("Catalog loaded successfully.")

        waitForExpectations(timeout: 5.0)
        XCTAssertEqual(announcements, ["Catalog loaded successfully."])
    }

    // MARK: - Deduplication (PP-3673)

    func testPP3673_deduplication_suppressesDuplicateWithinWindow() {
        var currentTime = Date(timeIntervalSince1970: 1000)
        let (announcer, store) = makeAnnouncer(deduplicationInterval: 2.0) { currentTime }
        store.expectation = expectation(description: "one announcement")

        announcer.announceError("Something went wrong.")
        currentTime = currentTime.addingTimeInterval(0.5)
        announcer.announceError("Something went wrong.")

        waitForExpectations(timeout: 5.0)
        XCTAssertEqual(store.items.count, 1, "Duplicate within window should be suppressed")
    }

    func testPP3673_deduplication_allowsRepeatAfterWindowExpires() {
        var currentTime = Date(timeIntervalSince1970: 1000)
        let (announcer, store) = makeAnnouncer(deduplicationInterval: 2.0) { currentTime }
        let exp = expectation(description: "two announcements")
        exp.expectedFulfillmentCount = 2
        store.expectation = exp

        announcer.announceError("Something went wrong.")
        currentTime = currentTime.addingTimeInterval(3.0)
        announcer.announceError("Something went wrong.")

        waitForExpectations(timeout: 5.0)
        XCTAssertEqual(store.items.count, 2, "Should allow repeat after window expires")
    }

    func testPP3673_deduplication_allowsDifferentMessages() {
        var currentTime = Date(timeIntervalSince1970: 1000)
        let (announcer, store) = makeAnnouncer(deduplicationInterval: 2.0) { currentTime }
        let exp = expectation(description: "two announcements")
        exp.expectedFulfillmentCount = 2
        store.expectation = exp

        announcer.announceError("Error A")
        currentTime = currentTime.addingTimeInterval(0.1)
        announcer.announceError("Error B")

        waitForExpectations(timeout: 5.0)
        XCTAssertEqual(store.items, ["Error A", "Error B"])
    }

    func testPP3673_deduplication_rapidFireSameMessage_onlyOneAnnouncement() {
        let currentTime = Date(timeIntervalSince1970: 1000)
        let (announcer, store) = makeAnnouncer(deduplicationInterval: 2.0) { currentTime }
        store.expectation = expectation(description: "one announcement")

        for _ in 0..<10 {
            announcer.announceError("Rapid error")
        }

        waitForExpectations(timeout: 5.0)
        XCTAssertEqual(store.items.count, 1, "10 rapid duplicates should collapse to 1")
    }

    func testPP3673_deduplication_crossMethod_sameText() {
        let currentTime = Date(timeIntervalSince1970: 1000)
        let (announcer, store) = makeAnnouncer(deduplicationInterval: 2.0) { currentTime }
        store.expectation = expectation(description: "one announcement")

        announcer.announceMessage("Hello")
        announcer.announceError("Hello")

        waitForExpectations(timeout: 5.0)
        XCTAssertEqual(store.items.count, 1, "Same text across methods should deduplicate")
    }

    // MARK: - VoiceOver Guard (PP-3673)

    func testPP3673_searchAnnouncements_respectVoiceOverDisabled() {
        let (announcer, store) = makeAnnouncer(voiceOverRunning: false)

        announcer.announceSearchResults(query: "test", count: 5)
        announcer.announceSearchFailed()
        announcer.announceAdditionalResultsLoaded(count: 10)

        XCTAssertTrue(store.items.isEmpty, "No announcements when VoiceOver is off")
    }

    func testPP3673_errorAnnouncements_respectVoiceOverDisabled() {
        let (announcer, store) = makeAnnouncer(voiceOverRunning: false)

        announcer.announceError("Big problem")
        announcer.announceStatus(title: "Error", message: "Something broke")
        announcer.announceMessage("Status update")

        XCTAssertTrue(store.items.isEmpty, "No announcements when VoiceOver is off")
    }

    // MARK: - Empty Message Guard (PP-3673)

    func testPP3673_emptyMessage_isNotPosted() {
        let (announcer, store) = makeAnnouncer()

        announcer.announceMessage("")
        announcer.announceError("")

        XCTAssertTrue(store.items.isEmpty, "Empty messages should not be posted")
    }

    // MARK: - Notification Type

    func testPP3673_allAnnouncements_useAnnouncementNotificationType() {
        var notifications: [UIAccessibility.Notification] = []
        let exp = expectation(description: "Announcements posted")
        exp.expectedFulfillmentCount = 3

        let announcer = TPPAccessibilityAnnouncementCenter(
            postHandler: { notification, _ in
                notifications.append(notification)
                exp.fulfill()
            },
            isVoiceOverRunning: { true }
        )

        announcer.announceSearchResults(query: "test", count: 1)
        announcer.announceError("Error happened")
        announcer.announceMessage("Status update")

        waitForExpectations(timeout: 5.0)
        XCTAssertEqual(notifications.count, 3)
        for notification in notifications {
            XCTAssertEqual(notification, UIAccessibility.Notification.announcement,
                           "All status announcements must use .announcement to avoid moving focus")
        }
    }
}

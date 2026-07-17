//
//  AccessibilityAnnouncementCenterTests.swift
//  PalaceTests
//
//  Created by The Palace Project on 2/6/26.
//

import XCTest
@testable import Palace

@MainActor
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

    /// Creates an announcement center with an expectation-based postHandler.
    /// Use for tests that need to wait for a specific number of announcements.
    private func makeExpectingAnnouncer(
        voiceOverRunning: Bool = true,
        deduplicationInterval: TimeInterval = 2.0,
        time: @escaping () -> Date = { Date() },
        expectedCount: Int,
        description: String
    ) -> (TPPAccessibilityAnnouncementCenter, Announcements, XCTestExpectation) {
        let store = Announcements()
        let exp = expectation(description: description)
        exp.expectedFulfillmentCount = expectedCount
        let announcer = TPPAccessibilityAnnouncementCenter(
            postHandler: { _, message in
                store.items.append(message)
                exp.fulfill()
            },
            isVoiceOverRunning: { voiceOverRunning },
            timeProvider: time,
            deduplicationInterval: deduplicationInterval
        )
        return (announcer, store, exp)
    }

    /// Creates an announcement center with an inverted expectation for negative tests.
    /// The inverted expectation will fail if the postHandler is ever called.
    private func makeNonFiringAnnouncer(
        voiceOverRunning: Bool = true,
        deduplicationInterval: TimeInterval = 2.0,
        time: @escaping () -> Date = { Date() },
        description: String
    ) -> (TPPAccessibilityAnnouncementCenter, Announcements, XCTestExpectation) {
        let store = Announcements()
        let exp = expectation(description: description)
        exp.isInverted = true
        let announcer = TPPAccessibilityAnnouncementCenter(
            postHandler: { _, message in
                store.items.append(message)
                exp.fulfill()
            },
            isVoiceOverRunning: { voiceOverRunning },
            timeProvider: time,
            deduplicationInterval: deduplicationInterval
        )
        return (announcer, store, exp)
    }

    /// Reference-type wrapper so captured closures share the same storage.
    private class Announcements {
        var items: [String] = []
    }

    // MARK: - Download Announcements (PP-3594)

    func testPP3594_downloadAnnouncements_respectVoiceOverDisabled() {
        let (announcer, store, neverFired) = makeNonFiringAnnouncer(
            voiceOverRunning: false,
            description: "postHandler should never be called when VoiceOver is off"
        )

        announcer.announceDownloadStarted(title: "Sample Book")
        announcer.announceDownloadCompleted(title: "Sample Book")

        wait(for: [neverFired], timeout: 0.3)
        XCTAssertTrue(store.items.isEmpty)
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
        let (announcer, store, neverFired) = makeNonFiringAnnouncer(
            description: "Zero additional results should not announce"
        )

        announcer.announceAdditionalResultsLoaded(count: 0)

        wait(for: [neverFired], timeout: 0.3)
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
        let (announcer, store, delivered) = makeExpectingAnnouncer(
            deduplicationInterval: 2.0,
            time: { currentTime },
            expectedCount: 1,
            description: "First announcement delivered"
        )

        announcer.announceError("Something went wrong.")
        // Same message, 0.5s later -- should be suppressed
        currentTime = currentTime.addingTimeInterval(0.5)
        announcer.announceError("Something went wrong.")

        wait(for: [delivered], timeout: 1.0)
        XCTAssertEqual(store.items.count, 1, "Duplicate within window should be suppressed")
    }

    /// PP-3673: Same message after deduplication window passes is allowed.
    func testPP3673_deduplication_allowsRepeatAfterWindowExpires() {
        var currentTime = Date(timeIntervalSince1970: 1000)
        let (announcer, store, delivered) = makeExpectingAnnouncer(
            deduplicationInterval: 2.0,
            time: { currentTime },
            expectedCount: 2,
            description: "Both announcements delivered"
        )

        announcer.announceError("Something went wrong.")
        // Advance past dedup window
        currentTime = currentTime.addingTimeInterval(3.0)
        announcer.announceError("Something went wrong.")

        wait(for: [delivered], timeout: 1.0)
        XCTAssertEqual(store.items.count, 2, "Should allow repeat after window expires")
    }

    /// PP-3673: Different messages within the window are NOT suppressed.
    func testPP3673_deduplication_allowsDifferentMessages() {
        var currentTime = Date(timeIntervalSince1970: 1000)
        let (announcer, store, delivered) = makeExpectingAnnouncer(
            deduplicationInterval: 2.0,
            time: { currentTime },
            expectedCount: 2,
            description: "Both different messages delivered"
        )

        announcer.announceError("Error A")
        currentTime = currentTime.addingTimeInterval(0.1)
        announcer.announceError("Error B")

        wait(for: [delivered], timeout: 1.0)
        XCTAssertEqual(store.items, ["Error A", "Error B"])
    }

    /// PP-3673: Rapid-fire identical messages result in only one announcement.
    func testPP3673_deduplication_rapidFireSameMessage_onlyOneAnnouncement() {
        let currentTime = Date(timeIntervalSince1970: 1000)
        let (announcer, store, delivered) = makeExpectingAnnouncer(
            deduplicationInterval: 2.0,
            time: { currentTime },
            expectedCount: 1,
            description: "Only one announcement from rapid fire"
        )

        for _ in 0..<10 {
            announcer.announceError("Rapid error")
        }

        wait(for: [delivered], timeout: 1.0)
        XCTAssertEqual(store.items.count, 1, "10 rapid duplicates should collapse to 1")
    }

    /// PP-3673: Deduplication applies across announcement types using same message text.
    func testPP3673_deduplication_crossMethod_sameText() {
        let currentTime = Date(timeIntervalSince1970: 1000)
        let (announcer, store, delivered) = makeExpectingAnnouncer(
            deduplicationInterval: 2.0,
            time: { currentTime },
            expectedCount: 1,
            description: "Only one announcement for cross-method same text"
        )

        announcer.announceMessage("Hello")
        announcer.announceError("Hello")

        wait(for: [delivered], timeout: 1.0)
        XCTAssertEqual(store.items.count, 1, "Same text across methods should deduplicate")
    }

    // MARK: - VoiceOver Guard (PP-3673)

    /// PP-3673: Search announcements are suppressed when VoiceOver is off.
    func testPP3673_searchAnnouncements_respectVoiceOverDisabled() {
        let (announcer, store, neverFired) = makeNonFiringAnnouncer(
            voiceOverRunning: false,
            description: "No search announcements when VoiceOver is off"
        )

        announcer.announceSearchResults(query: "test", count: 5)
        announcer.announceSearchFailed()
        announcer.announceAdditionalResultsLoaded(count: 10)

        wait(for: [neverFired], timeout: 0.3)
        XCTAssertTrue(store.items.isEmpty, "No announcements when VoiceOver is off")
    }

    /// PP-3673: Error announcements are suppressed when VoiceOver is off.
    func testPP3673_errorAnnouncements_respectVoiceOverDisabled() {
        let (announcer, store, neverFired) = makeNonFiringAnnouncer(
            voiceOverRunning: false,
            description: "No error announcements when VoiceOver is off"
        )

        announcer.announceError("Big problem")
        announcer.announceStatus(title: "Error", message: "Something broke")
        announcer.announceMessage("Status update")

        wait(for: [neverFired], timeout: 0.3)
        XCTAssertTrue(store.items.isEmpty, "No announcements when VoiceOver is off")
    }

    // MARK: - Empty Message Guard (PP-3673)

    /// PP-3673: Empty messages are never posted.
    func testPP3673_emptyMessage_isNotPosted() {
        let (announcer, store, neverFired) = makeNonFiringAnnouncer(
            description: "Empty messages should not be posted"
        )

        announcer.announceMessage("")
        announcer.announceError("")

        wait(for: [neverFired], timeout: 0.3)
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

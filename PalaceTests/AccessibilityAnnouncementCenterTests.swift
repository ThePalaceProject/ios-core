//
//  AccessibilityAnnouncementCenterTests.swift
//  PalaceTests
//
//  Created by The Palace Project on 2/6/26.
//

import XCTest
@testable import Palace

final class AccessibilityAnnouncementCenterTests: XCTestCase {

    /// Regression test for PP-3594: VoiceOver should announce download progress at throttled intervals.
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

    /// Regression test for PP-3594: VoiceOver announcements should not fire when VoiceOver is off.
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

    /// Regression test for PP-3594: Borrow and return actions should announce state changes.
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
}

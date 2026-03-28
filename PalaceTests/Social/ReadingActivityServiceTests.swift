//
//  ReadingActivityServiceTests.swift
//  PalaceTests
//
//  Tests for ReadingActivityService recording, pruning, and filtering.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import XCTest
@testable import Palace

final class ReadingActivityServiceTests: XCTestCase {

    private var sut: ReadingActivityService!
    private var defaults: UserDefaults!
    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "ReadingActivityServiceTests")!
        defaults.removePersistentDomain(forName: "ReadingActivityServiceTests")
        sut = ReadingActivityService(userDefaults: defaults)
        cancellables = []
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "ReadingActivityServiceTests")
        defaults = nil
        sut = nil
        cancellables = nil
        super.tearDown()
    }

    // MARK: - Recording

    func testRecordActivity_AddsToList() {
        let activity = ReadingActivity(type: .startedReading, bookID: "book-1", bookTitle: "Title")
        sut.recordActivity(activity)
        XCTAssertEqual(sut.activityCount(), 1)
    }

    func testRecordActivity_MultipleEvents() {
        sut.recordActivity(ReadingActivity(type: .startedReading))
        sut.recordActivity(ReadingActivity(type: .finishedBook))
        sut.recordActivity(ReadingActivity(type: .earnedBadge))
        XCTAssertEqual(sut.activityCount(), 3)
    }

    // MARK: - Ordering

    func testAllActivities_ReverseChronological() {
        let old = ReadingActivity(type: .startedReading, timestamp: Date(timeIntervalSince1970: 1000))
        let new = ReadingActivity(type: .finishedBook, timestamp: Date(timeIntervalSince1970: 2000))
        sut.recordActivity(old)
        sut.recordActivity(new)
        let all = sut.allActivities()
        XCTAssertEqual(all.first?.type, .finishedBook)
        XCTAssertEqual(all.last?.type, .startedReading)
    }

    // MARK: - Filtering

    func testFilterByType_ReturnsOnlyMatching() {
        sut.recordActivity(ReadingActivity(type: .startedReading))
        sut.recordActivity(ReadingActivity(type: .finishedBook))
        sut.recordActivity(ReadingActivity(type: .startedReading))
        let started = sut.activities(ofType: .startedReading)
        XCTAssertEqual(started.count, 2)
        XCTAssertTrue(started.allSatisfy { $0.type == .startedReading })
    }

    func testFilterByType_EmptyForNoMatches() {
        sut.recordActivity(ReadingActivity(type: .startedReading))
        let badges = sut.activities(ofType: .earnedBadge)
        XCTAssertTrue(badges.isEmpty)
    }

    // MARK: - Pruning

    func testPruning_LimitsTo500Events() {
        for i in 0..<510 {
            sut.recordActivity(ReadingActivity(
                type: .startedReading,
                timestamp: Date(timeIntervalSince1970: Double(i))
            ))
        }
        XCTAssertLessThanOrEqual(sut.activityCount(), ReadingActivityService.maxEvents)
    }

    func testPruning_KeepsNewest() {
        for i in 0..<510 {
            sut.recordActivity(ReadingActivity(
                type: .startedReading,
                bookTitle: "Book \(i)",
                timestamp: Date(timeIntervalSince1970: Double(i))
            ))
        }
        let all = sut.allActivities()
        // The newest event (timestamp 509) should be present
        XCTAssertTrue(all.contains(where: { $0.bookTitle == "Book 509" }))
    }

    // MARK: - Display Helpers

    func testDisplayText_StartedReading() {
        let activity = ReadingActivity(type: .startedReading, bookTitle: "Dune")
        XCTAssertEqual(activity.displayText, "Started reading Dune")
    }

    func testDisplayText_FinishedBook() {
        let activity = ReadingActivity(type: .finishedBook, bookTitle: "Dune")
        XCTAssertEqual(activity.displayText, "Finished Dune")
    }

    func testDisplayText_EarnedBadge() {
        let activity = ReadingActivity(type: .earnedBadge, metadata: ["badgeName": "Bookworm"])
        XCTAssertEqual(activity.displayText, "Earned Bookworm")
    }

    func testDisplayText_AddedToCollection() {
        let activity = ReadingActivity(type: .addedToCollection, bookTitle: "Dune", metadata: ["collectionName": "Sci-Fi"])
        XCTAssertEqual(activity.displayText, "Added Dune to Sci-Fi")
    }

    func testDisplayText_WroteReview() {
        let activity = ReadingActivity(type: .wroteReview, bookTitle: "Dune")
        XCTAssertEqual(activity.displayText, "Reviewed Dune")
    }

    func testIconName_AllTypesHaveIcons() {
        for type in ReadingActivity.ActivityType.allCases {
            let activity = ReadingActivity(type: type)
            XCTAssertFalse(activity.iconName.isEmpty, "\(type) should have an icon")
        }
    }

    // MARK: - Persistence

    func testPersistence_SurvivesReload() {
        sut.recordActivity(ReadingActivity(type: .startedReading, bookTitle: "Persisted"))
        let reloaded = ReadingActivityService(userDefaults: defaults)
        XCTAssertEqual(reloaded.activityCount(), 1)
        XCTAssertEqual(reloaded.allActivities().first?.bookTitle, "Persisted")
    }

    // MARK: - Publisher

    func testPublisher_EmitsOnRecord() {
        let expectation = expectation(description: "Publisher emits")

        sut.activitiesPublisher
            .dropFirst()
            .sink { activities in
                if !activities.isEmpty {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        sut.recordActivity(ReadingActivity(type: .startedReading))
        wait(for: [expectation], timeout: 1.0)
    }
}

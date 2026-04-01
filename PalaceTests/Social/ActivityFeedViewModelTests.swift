//
//  ActivityFeedViewModelTests.swift
//  PalaceTests
//
//  Tests for ActivityFeedViewModel feed loading and filtering.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import XCTest
@testable import Palace

@MainActor
final class ActivityFeedViewModelTests: XCTestCase {

    private var sut: ActivityFeedViewModel!
    private var mockService: MockReadingActivityService!
    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        mockService = MockReadingActivityService()
        cancellables = []
    }

    override func tearDown() {
        sut = nil
        mockService = nil
        cancellables = nil
        super.tearDown()
    }

    // MARK: - Initial State

    func testInitialState_Empty() {
        sut = ActivityFeedViewModel(activityService: mockService)
        XCTAssertTrue(sut.activities.isEmpty)
        XCTAssertNil(sut.filterType)
    }

    func testInitialState_LoadsExisting() {
        mockService.recordActivity(ReadingActivity(type: .startedReading, bookTitle: "Book"))
        sut = ActivityFeedViewModel(activityService: mockService)
        XCTAssertEqual(sut.activities.count, 1)
    }

    // MARK: - Filtering

    func testSetFilter_FiltersActivities() {
        mockService.recordActivity(ReadingActivity(type: .startedReading))
        mockService.recordActivity(ReadingActivity(type: .finishedBook))
        mockService.recordActivity(ReadingActivity(type: .startedReading))
        sut = ActivityFeedViewModel(activityService: mockService)

        sut.setFilter(.startedReading)
        XCTAssertEqual(sut.filterType, .startedReading)
        XCTAssertEqual(sut.activities.count, 2)
        XCTAssertTrue(sut.activities.allSatisfy { $0.type == .startedReading })
    }

    func testClearFilter_ShowsAll() {
        mockService.recordActivity(ReadingActivity(type: .startedReading))
        mockService.recordActivity(ReadingActivity(type: .finishedBook))
        sut = ActivityFeedViewModel(activityService: mockService)

        sut.setFilter(.startedReading)
        XCTAssertEqual(sut.activities.count, 1)

        sut.clearFilter()
        XCTAssertNil(sut.filterType)
        XCTAssertEqual(sut.activities.count, 2)
    }

    // MARK: - Grouping

    func testGroupedActivities_GroupsByDateBucket() {
        // Add today's activity
        mockService.recordActivity(ReadingActivity(type: .startedReading, timestamp: Date()))

        // Add yesterday's activity
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        mockService.recordActivity(ReadingActivity(type: .finishedBook, timestamp: yesterday))

        // Add old activity
        let oldDate = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        mockService.recordActivity(ReadingActivity(type: .earnedBadge, timestamp: oldDate))

        sut = ActivityFeedViewModel(activityService: mockService)
        let groups = sut.groupedActivities

        XCTAssertGreaterThanOrEqual(groups.count, 2)
        // Should have Today, Yesterday, and Earlier groups
        let groupNames = groups.map(\.0)
        XCTAssertTrue(groupNames.contains("Today"))
        XCTAssertTrue(groupNames.contains("Yesterday"))
    }

    func testGroupedActivities_EmptyWhenNoActivities() {
        sut = ActivityFeedViewModel(activityService: mockService)
        XCTAssertTrue(sut.groupedActivities.isEmpty)
    }

    // MARK: - Publisher Updates

    func testActivities_UpdateWhenServiceChanges() {
        sut = ActivityFeedViewModel(activityService: mockService)
        XCTAssertTrue(sut.activities.isEmpty)

        let expectation = expectation(description: "Activities update")
        sut.$activities
            .dropFirst()
            .prefix(1)
            .sink { activities in
                if !activities.isEmpty {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        mockService.recordActivity(ReadingActivity(type: .startedReading))
        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(sut.activities.count, 1)
    }
}

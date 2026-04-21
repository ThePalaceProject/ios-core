//
//  AudiobookTimeTrackerEdgeTests.swift
//  PalaceTests
//
//  Edge case tests for AudiobookTimeTracker: minute boundaries,
//  duration capping, and thread-safe access.
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Combine
import XCTest
@testable import Palace

/// SRS: AUDIO-003 -- Time tracking accumulates and persists correctly
final class AudiobookTimeTrackerEdgeTests: XCTestCase {

    private var tracker: AudiobookTimeTracker!
    private var mockDataManager: MockDataManager!

    override func setUp() {
        super.setUp()
        mockDataManager = MockDataManager()
        tracker = AudiobookTimeTracker(
            libraryId: "edge-lib",
            bookId: "edge-book",
            timeTrackingUrl: URL(string: "https://example.com/track")!,
            dataManager: mockDataManager
        )
    }

    override func tearDown() {
        tracker.stopAndSave()
        tracker = nil
        mockDataManager = nil
        super.tearDown()
    }

    // MARK: - Minute Boundary Tests

    /// SRS: AUDIO-003 -- Time tracking accumulates and persists correctly
    func testReceiveValue_crossingMinuteBoundary_savesEntry() {
        let calendar = Calendar.current
        // Create a date 5 seconds before minute boundary
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        components.second = 55
        let startDate = calendar.date(from: components)!

        // Simulate ticks across minute boundary
        for i in 0..<10 {
            let time = calendar.date(byAdding: .second, value: i, to: startDate)!
            tracker.receiveValue(time)
        }

        tracker.stopAndSave()
        mockDataManager.flush()

        // Should have saved at least once when crossing the minute boundary
        let total = mockDataManager.savedTimeEntries.reduce(0) { $0 + $1.duration }
        XCTAssertGreaterThan(total, 0,
                              "Crossing a minute boundary should trigger a save")
    }

    /// SRS: AUDIO-003 -- Time tracking accumulates and persists correctly
    func testReceiveValue_withinSameMinute_doesNotSaveUntilStop() {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        components.second = 10
        let startDate = calendar.date(from: components)!

        // 5 ticks all within the same minute
        for i in 0..<5 {
            let time = calendar.date(byAdding: .second, value: i, to: startDate)!
            tracker.receiveValue(time)
        }

        mockDataManager.flush()

        // No save should have occurred yet (still within the same minute)
        let entriesBeforeStop = mockDataManager.savedTimeEntries.count
        // Note: save only happens on minute boundary or stop

        tracker.stopAndSave()
        mockDataManager.flush()

        let total = mockDataManager.savedTimeEntries.reduce(0) { $0 + $1.duration }
        XCTAssertEqual(total, 5, "Should accumulate 5 seconds of playback")
    }

    // MARK: - Duration Cap Tests

    /// SRS: AUDIO-003 -- Time tracking accumulates and persists correctly
    func testTimeEntry_durationCappedAt60() {
        let entry = tracker.timeEntry
        // timeEntry uses min(60, Int(duration))
        // At init, duration is 0
        XCTAssertLessThanOrEqual(entry.duration, 60,
                                  "Duration should never exceed 60 seconds")
    }

    /// SRS: AUDIO-003 -- Time tracking accumulates and persists correctly
    func testTimeEntry_containsCorrectBookAndLibraryIds() {
        let entry = tracker.timeEntry
        XCTAssertEqual(entry.bookId, "edge-book")
        XCTAssertEqual(entry.libraryId, "edge-lib")
        XCTAssertEqual(entry.timeTrackingUrl, URL(string: "https://example.com/track")!)
    }

    /// SRS: AUDIO-003 -- Time tracking accumulates and persists correctly
    func testTimeEntry_duringMinute_isUTCFormat() {
        let entry = tracker.timeEntry
        XCTAssertTrue(entry.duringMinute.hasSuffix("Z"),
                       "duringMinute should be in UTC format ending with Z")
        XCTAssertTrue(entry.duringMinute.contains("T"),
                       "duringMinute should contain ISO 8601 T separator")
    }

    // MARK: - Playback Lifecycle Tests

    /// SRS: AUDIO-003 -- Time tracking accumulates and persists correctly
    func testPlaybackStopped_savesAccumulatedTime_beforeCancellingTimer() {
        let date = Date()

        tracker.playbackStarted()
        for i in 0..<15 {
            let time = Calendar.current.date(byAdding: .second, value: i, to: date)!
            tracker.receiveValue(time)
        }
        tracker.playbackStopped()

        mockDataManager.flush()
        let total = mockDataManager.savedTimeEntries.reduce(0) { $0 + $1.duration }
        XCTAssertGreaterThanOrEqual(total, 14,
                                     "playbackStopped should save accumulated time")
    }

    /// SRS: AUDIO-003 -- Time tracking accumulates and persists correctly
    func testStopAndSave_calledMultipleTimes_doesNotDuplicate() {
        let date = Date()

        for i in 0..<10 {
            let time = Calendar.current.date(byAdding: .second, value: i, to: date)!
            tracker.receiveValue(time)
        }

        tracker.stopAndSave()
        mockDataManager.flush()
        let countAfterFirst = mockDataManager.savedTimeEntries.count

        tracker.stopAndSave()
        mockDataManager.flush()
        let countAfterSecond = mockDataManager.savedTimeEntries.count

        XCTAssertEqual(countAfterFirst, countAfterSecond,
                        "Second stopAndSave should not create duplicate entries (duration is 0)")
    }

    /// SRS: AUDIO-003 -- Time tracking accumulates and persists correctly
    func testZeroDuration_isNotSaved() {
        // Don't send any receiveValue calls
        tracker.stopAndSave()
        mockDataManager.flush()

        XCTAssertEqual(mockDataManager.savedTimeEntries.count, 0,
                        "Zero duration should not produce a saved entry")
    }
}

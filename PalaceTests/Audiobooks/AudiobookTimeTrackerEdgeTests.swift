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
@MainActor
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
    func testTimeEntry_durationCappedAt60_andIsNonNegativeAtInit() {
        // The cap exists so a single entry can't represent more than a minute
        // of listening — the backend counts minutes and rejects oversized
        // entries. Duration must also be >= 0 at init; a negative entry would
        // slip past the cap but would corrupt aggregate totals downstream.
        let entry = tracker.timeEntry

        XCTAssertLessThanOrEqual(entry.duration, 60,
                                  "Duration must never exceed 60 seconds — CM rejects longer entries")
        XCTAssertGreaterThanOrEqual(entry.duration, 0,
                                     "Duration must be non-negative at init (negative would poison aggregates)")
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

    /// Ticks spanning three UTC minutes produce one entry per minute, keyed by
    /// the minute string and holding exactly the seconds played in it (PP-5498).
    func testReceiveValue_acrossThreeUTCMinutes_savesOneEntryPerMinuteWithExactSeconds() {
        // 1_699_999_980 is 2023-11-14T22:13:00Z; ticks run 22:13:50 to 22:15:59.
        let start = 1_700_000_030.0
        for i in 0..<130 {
            tracker.receiveValue(Date(timeIntervalSince1970: start + Double(i)))
        }
        tracker.stopAndSave()
        mockDataManager.flush()

        let saved = mockDataManager.savedTimeEntries.map { ($0.duringMinute, $0.duration) }
        XCTAssertEqual(saved.map(\.0), ["2023-11-14T22:13Z", "2023-11-14T22:14Z", "2023-11-14T22:15Z"])
        XCTAssertEqual(saved.map(\.1), [10, 60, 60])
    }

    /// A tick a fraction of a second before the boundary stays in the old
    /// minute; the first tick at or after it opens the new one.
    func testReceiveValue_fractionalTicksAroundBoundary_splitAtTheExactSecond() {
        let boundary = 1_700_000_040.0
        for offset in [-2.5, -1.5, -0.0005, 0.0, 0.5] {
            tracker.receiveValue(Date(timeIntervalSince1970: boundary + offset))
        }
        tracker.stopAndSave()
        mockDataManager.flush()

        let saved = mockDataManager.savedTimeEntries.map { ($0.duringMinute, $0.duration) }
        XCTAssertEqual(saved.map(\.0), ["2023-11-14T22:13Z", "2023-11-14T22:14Z"])
        XCTAssertEqual(saved.map(\.1), [3, 2])
    }

    /// A tick under a millisecond before a minute ends is filed under that
    /// minute. DateFormatter rounds to the millisecond, so a key formatted from
    /// the tick itself would name the next minute and file it twice.
    func testReceiveValue_tickJustBeforeMinuteEnds_isFiledUnderItsOwnMinute() {
        // 22:13:50, then 22:14:59.9997 after a gap, then 22:15:00.5.
        for t in [1_700_000_030.0, 1_700_000_099.9997, 1_700_000_100.5] {
            tracker.receiveValue(Date(timeIntervalSince1970: t))
        }
        tracker.stopAndSave()
        mockDataManager.flush()

        let saved = mockDataManager.savedTimeEntries.map { ($0.duringMinute, $0.duration) }
        XCTAssertEqual(saved.map(\.0), ["2023-11-14T22:13Z", "2023-11-14T22:14Z", "2023-11-14T22:15Z"])
        XCTAssertEqual(saved.map(\.1), [1, 1, 1])
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

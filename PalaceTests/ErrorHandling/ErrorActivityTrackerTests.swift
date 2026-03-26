//
//  ErrorActivityTrackerTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class ErrorActivityTrackerTests: XCTestCase {

    // Use a fresh tracker for each test to avoid shared state pollution
    private var tracker: ErrorActivityTracker!

    override func setUp() async throws {
        tracker = ErrorActivityTracker()
    }

    override func tearDown() async throws {
        await tracker.clear()
        tracker = nil
        try await super.tearDown()
    }

    // MARK: - Basic Logging

    func testLog_singleEntry_appearsInSnapshot() async {
        await tracker.log("Test message", category: .general)
        let snapshot = await tracker.snapshot()

        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.first?.message, "Test message")
        XCTAssertEqual(snapshot.first?.category, .general)
    }

    func testLog_multipleEntries_preservesOrder() async {
        await tracker.log("First", category: .network)
        await tracker.log("Second", category: .borrow)
        await tracker.log("Third", category: .download)

        let snapshot = await tracker.snapshot()
        XCTAssertEqual(snapshot.count, 3)
        XCTAssertEqual(snapshot[0].message, "First")
        XCTAssertEqual(snapshot[1].message, "Second")
        XCTAssertEqual(snapshot[2].message, "Third")
    }

    func testLog_capturesFileAndLine() async {
        await tracker.log("With source info")
        let snapshot = await tracker.snapshot()

        XCTAssertFalse(snapshot.first!.file.isEmpty)
        XCTAssertGreaterThan(snapshot.first!.line, 0)
    }

    // MARK: - Categories

    func testLog_allCategories_areStoredCorrectly() async {
        let categories: [ErrorActivityTracker.Activity.Category] = [
            .network, .borrow, .download, .auth, .drm, .ui, .general
        ]
        for cat in categories {
            await tracker.log("Cat: \(cat.rawValue)", category: cat)
        }

        let snapshot = await tracker.snapshot()
        XCTAssertEqual(snapshot.count, categories.count)
        for (i, cat) in categories.enumerated() {
            XCTAssertEqual(snapshot[i].category, cat)
        }
    }

    // MARK: - Ring Buffer

    func testLog_exceedingMaxEntries_trimmsOldest() async {
        // MaxEntries is 200 in ErrorActivityTracker
        for i in 0..<250 {
            await tracker.log("Entry \(i)")
        }

        let snapshot = await tracker.snapshot()
        XCTAssertEqual(snapshot.count, 200, "Should cap at maxEntries (200)")
        XCTAssertEqual(snapshot.first?.message, "Entry 50", "Oldest 50 should be trimmed")
        XCTAssertEqual(snapshot.last?.message, "Entry 249")
    }

    // MARK: - Time Filtering

    func testRecentActivities_filtersOldEntries() async {
        await tracker.log("Recent entry")

        // recentActivities with 300 seconds should include the entry we just logged
        let recent = await tracker.recentActivities(seconds: 300)
        XCTAssertEqual(recent.count, 1)

        // With 0 seconds, nothing should be recent
        let none = await tracker.recentActivities(seconds: 0)
        XCTAssertEqual(none.count, 0)
    }

    func testRecentActivities_defaultParameter_returns5Minutes() async {
        await tracker.log("Within 5 minutes")

        let recent = await tracker.recentActivities()
        XCTAssertEqual(recent.count, 1)
    }

    // MARK: - Clear

    func testClear_removesAllEntries() async {
        await tracker.log("Entry 1")
        await tracker.log("Entry 2")
        await tracker.clear()

        let snapshot = await tracker.snapshot()
        XCTAssertTrue(snapshot.isEmpty)
    }

    // MARK: - Activity Formatting

    func testDisplayString_containsTimestampCategoryAndMessage() async {
        await tracker.log("Borrow started", category: .borrow)
        let activity = await tracker.snapshot().first!

        let display = activity.displayString
        XCTAssertTrue(display.contains("[Borrow]"), "Should contain category")
        XCTAssertTrue(display.contains("Borrow started"), "Should contain message")
        // Time format: HH:mm:ss.SSS
        let timePattern = try! NSRegularExpression(pattern: "\\[\\d{2}:\\d{2}:\\d{2}\\.\\d{3}\\]")
        XCTAssertTrue(timePattern.firstMatch(in: display, range: NSRange(display.startIndex..., in: display)) != nil,
                      "Should contain timestamp in HH:mm:ss.SSS format")
    }

    func testShortSource_containsFileAndLine() async {
        await tracker.log("Test")
        let activity = await tracker.snapshot().first!

        let source = activity.shortSource
        XCTAssertTrue(source.contains(":"), "Should have file:line format")
    }

    // MARK: - Category Raw Values

    func testCategoryRawValues() {
        XCTAssertEqual(ErrorActivityTracker.Activity.Category.network.rawValue, "Network")
        XCTAssertEqual(ErrorActivityTracker.Activity.Category.borrow.rawValue, "Borrow")
        XCTAssertEqual(ErrorActivityTracker.Activity.Category.download.rawValue, "Download")
        XCTAssertEqual(ErrorActivityTracker.Activity.Category.auth.rawValue, "Auth")
        XCTAssertEqual(ErrorActivityTracker.Activity.Category.drm.rawValue, "DRM")
        XCTAssertEqual(ErrorActivityTracker.Activity.Category.ui.rawValue, "UI")
        XCTAssertEqual(ErrorActivityTracker.Activity.Category.general.rawValue, "General")
    }

    // MARK: - Timestamp Ordering

    func testLog_timestampsAreMonotonicallyIncreasing() async {
        for i in 0..<10 {
            await tracker.log("Entry \(i)")
        }

        let snapshot = await tracker.snapshot()
        for i in 1..<snapshot.count {
            XCTAssertGreaterThanOrEqual(snapshot[i].timestamp, snapshot[i-1].timestamp)
        }
    }
}

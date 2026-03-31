//
//  AppLaunchTrackerExtendedTests.swift
//  PalaceTests
//
//  Extended tests for AppLaunchTracker: milestone ordering, warm/cold detection,
//  idempotency, and missing milestone handling.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class AppLaunchTrackerExtendedTests: XCTestCase {

    private var tracker: AppLaunchTracker!
    private var monitor: PerformanceMonitor!

    override func setUp() {
        super.setUp()
        monitor = PerformanceMonitor()
        tracker = AppLaunchTracker(performanceMonitor: monitor)
    }

    override func tearDown() {
        tracker = nil
        monitor = nil
        super.tearDown()
    }

    // MARK: - Cold vs Warm Launch Detection

    func testDefaultIsColdLaunch() async {
        let type = await tracker.launchType
        XCTAssertEqual(type, "cold")
    }

    func testMarkWarmLaunch_ChangesType() async {
        await tracker.markWarmLaunch()
        let type = await tracker.launchType
        XCTAssertEqual(type, "warm")
    }

    func testColdLaunch_AfterReset() async {
        await tracker.markWarmLaunch()
        await tracker.reset()
        let type = await tracker.launchType
        XCTAssertEqual(type, "cold")
    }

    // MARK: - Milestones Recorded in Order

    func testAllMilestones_RecordedInChronologicalOrder() async {
        await tracker.recordMilestone(.processStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        await tracker.recordMilestone(.didFinishLaunching)
        try? await Task.sleep(nanoseconds: 5_000_000)
        await tracker.recordMilestone(.firstFrame)
        try? await Task.sleep(nanoseconds: 5_000_000)
        await tracker.recordMilestone(.catalogLoaded)

        let milestones = await tracker.recordedMilestones

        let processStart = milestones[.processStart]!
        let didFinish = milestones[.didFinishLaunching]!
        let firstFrame = milestones[.firstFrame]!
        let catalogLoaded = milestones[.catalogLoaded]!

        XCTAssertLessThan(processStart, didFinish)
        XCTAssertLessThan(didFinish, firstFrame)
        XCTAssertLessThan(firstFrame, catalogLoaded)
    }

    func testMilestoneCount_MatchesRecordedCount() async {
        await tracker.recordMilestone(.processStart)
        await tracker.recordMilestone(.didFinishLaunching)

        let milestones = await tracker.recordedMilestones
        XCTAssertEqual(milestones.count, 2)
    }

    // MARK: - Time-to-Interactive Calculation

    func testTimeToInteractive_RequiresProcessStartAndCatalogLoaded() async {
        await tracker.recordMilestone(.processStart)
        try? await Task.sleep(nanoseconds: 30_000_000) // 30ms
        await tracker.recordMilestone(.catalogLoaded)

        let tti = await tracker.timeToInteractive
        XCTAssertNotNil(tti)
        XCTAssertGreaterThan(tti!, 0.02)
    }

    func testTimeToInteractive_NilWithoutCatalogLoaded() async {
        await tracker.recordMilestone(.processStart)
        await tracker.recordMilestone(.didFinishLaunching)
        await tracker.recordMilestone(.firstFrame)

        let tti = await tracker.timeToInteractive
        XCTAssertNil(tti, "TTI should be nil when catalogLoaded hasn't been recorded")
    }

    func testTimeToInteractive_NilWithoutProcessStart() async {
        await tracker.recordMilestone(.catalogLoaded)

        let tti = await tracker.timeToInteractive
        XCTAssertNil(tti, "TTI should be nil when processStart hasn't been recorded")
    }

    // MARK: - Missing Milestone Handling

    func testTimeBetween_NilWhenStartMissing() async {
        await tracker.recordMilestone(.catalogLoaded)

        let time = await tracker.timeBetween(.processStart, .catalogLoaded)
        XCTAssertNil(time)
    }

    func testTimeBetween_NilWhenEndMissing() async {
        await tracker.recordMilestone(.processStart)

        let time = await tracker.timeBetween(.processStart, .firstFrame)
        XCTAssertNil(time)
    }

    func testTimeBetween_NilWhenBothMissing() async {
        let time = await tracker.timeBetween(.processStart, .catalogLoaded)
        XCTAssertNil(time)
    }

    func testTimeToFirstFrame_NilWithoutFirstFrame() async {
        await tracker.recordMilestone(.processStart)

        let ttf = await tracker.timeToFirstFrame
        XCTAssertNil(ttf)
    }

    // MARK: - Duplicate Milestone Calls are Idempotent (Overwrites)

    func testDuplicateMilestone_OverwritesTimestamp() async {
        await tracker.recordMilestone(.processStart)
        let milestones1 = await tracker.recordedMilestones
        let firstTimestamp = milestones1[.processStart]!

        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

        await tracker.recordMilestone(.processStart)
        let milestones2 = await tracker.recordedMilestones
        let secondTimestamp = milestones2[.processStart]!

        // Second call overwrites - timestamp should be later
        XCTAssertGreaterThan(secondTimestamp, firstTimestamp)
        // Still only one entry for processStart
        XCTAssertEqual(milestones2.count, 1)
    }

    func testDuplicateMilestone_DoesNotCreateExtraEntries() async {
        await tracker.recordMilestone(.firstFrame)
        await tracker.recordMilestone(.firstFrame)
        await tracker.recordMilestone(.firstFrame)

        let milestones = await tracker.recordedMilestones
        XCTAssertEqual(milestones.count, 1)
    }

    // MARK: - Performance Monitor Integration

    func testWarmLaunch_ReportsWithWarmType() async {
        await tracker.markWarmLaunch()
        await tracker.recordMilestone(.processStart)
        try? await Task.sleep(nanoseconds: 20_000_000)
        await tracker.recordMilestone(.firstFrame)
        try? await Task.sleep(nanoseconds: 20_000_000)
        await tracker.recordMilestone(.catalogLoaded)

        // Give time for async metric reporting
        try? await Task.sleep(nanoseconds: 200_000_000)

        let metrics = await monitor.metrics(for: .appLaunch)
        let warmMetrics = metrics.filter { $0.metadata["launch_type"] == "warm" }
        XCTAssertGreaterThan(warmMetrics.count, 0,
                             "Warm launch should report metrics with launch_type=warm")
    }

    // MARK: - LaunchMilestone Enum

    func testLaunchMilestone_AllCases() {
        XCTAssertEqual(LaunchMilestone.allCases.count, 4)
        XCTAssertTrue(LaunchMilestone.allCases.contains(.processStart))
        XCTAssertTrue(LaunchMilestone.allCases.contains(.didFinishLaunching))
        XCTAssertTrue(LaunchMilestone.allCases.contains(.firstFrame))
        XCTAssertTrue(LaunchMilestone.allCases.contains(.catalogLoaded))
    }

    func testLaunchMilestone_RawValues() {
        XCTAssertEqual(LaunchMilestone.processStart.rawValue, "process_start")
        XCTAssertEqual(LaunchMilestone.didFinishLaunching.rawValue, "did_finish_launching")
        XCTAssertEqual(LaunchMilestone.firstFrame.rawValue, "first_frame")
        XCTAssertEqual(LaunchMilestone.catalogLoaded.rawValue, "catalog_loaded")
    }
}

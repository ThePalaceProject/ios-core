//
//  AppLaunchTrackerTests.swift
//  PalaceTests
//
//  Tests for the app launch tracker.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class AppLaunchTrackerTests: XCTestCase {

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

    // MARK: - Milestone Recording

    func testRecordProcessStart() async {
        await tracker.recordMilestone(.processStart)
        let milestones = await tracker.recordedMilestones
        XCTAssertNotNil(milestones[.processStart])
    }

    func testRecordAllMilestones() async {
        await tracker.recordMilestone(.processStart)
        try? await Task.sleep(nanoseconds: 10_000_000)
        await tracker.recordMilestone(.didFinishLaunching)
        try? await Task.sleep(nanoseconds: 10_000_000)
        await tracker.recordMilestone(.firstFrame)
        try? await Task.sleep(nanoseconds: 10_000_000)
        await tracker.recordMilestone(.catalogLoaded)

        let milestones = await tracker.recordedMilestones
        XCTAssertEqual(milestones.count, 4)
    }

    // MARK: - Timing Calculations

    func testTimeBetweenMilestones() async {
        await tracker.recordMilestone(.processStart)
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        await tracker.recordMilestone(.didFinishLaunching)

        let time = await tracker.timeBetween(.processStart, .didFinishLaunching)
        XCTAssertNotNil(time)
        XCTAssertGreaterThan(time ?? 0, 0.04) // At least ~40ms
    }

    func testTimeBetweenUnrecordedMilestones() async {
        await tracker.recordMilestone(.processStart)

        let time = await tracker.timeBetween(.processStart, .catalogLoaded)
        XCTAssertNil(time, "Should return nil when end milestone hasn't been recorded")
    }

    func testTimeToInteractive() async {
        await tracker.recordMilestone(.processStart)
        try? await Task.sleep(nanoseconds: 30_000_000) // 30ms
        await tracker.recordMilestone(.catalogLoaded)

        let tti = await tracker.timeToInteractive
        XCTAssertNotNil(tti)
        XCTAssertGreaterThan(tti ?? 0, 0.02)
    }

    func testTimeToFirstFrame() async {
        await tracker.recordMilestone(.processStart)
        try? await Task.sleep(nanoseconds: 20_000_000)
        await tracker.recordMilestone(.firstFrame)

        let ttf = await tracker.timeToFirstFrame
        XCTAssertNotNil(ttf)
        XCTAssertGreaterThan(ttf ?? 0, 0.01)
    }

    // MARK: - Launch Type

    func testDefaultLaunchTypeIsCold() async {
        let type = await tracker.launchType
        XCTAssertEqual(type, "cold")
    }

    func testWarmLaunchType() async {
        await tracker.markWarmLaunch()
        let type = await tracker.launchType
        XCTAssertEqual(type, "warm")
    }

    // MARK: - Reset

    func testReset() async {
        await tracker.recordMilestone(.processStart)
        await tracker.markWarmLaunch()
        await tracker.reset()

        let milestones = await tracker.recordedMilestones
        let type = await tracker.launchType
        XCTAssertTrue(milestones.isEmpty)
        XCTAssertEqual(type, "cold")
    }

    // MARK: - Performance Monitor Integration

    func testCatalogLoadedReportsToMonitor() async {
        await tracker.recordMilestone(.processStart)
        try? await Task.sleep(nanoseconds: 20_000_000)
        await tracker.recordMilestone(.firstFrame)
        try? await Task.sleep(nanoseconds: 20_000_000)
        await tracker.recordMilestone(.catalogLoaded)

        // Give time for the async metric reporting
        try? await Task.sleep(nanoseconds: 100_000_000)

        let metrics = await monitor.metrics(for: .appLaunch)
        XCTAssertGreaterThan(metrics.count, 0, "Should have reported launch metrics to the performance monitor")
    }
}

//
//  AppLaunchTrackerWiringTests.swift
//  PalaceTests
//
//  Wiring test for the launch instrumentation added in swarm_27c181b5
//  (Startup-AppLifecycle). Proves that recording the launch milestones in the
//  order the production sites fire them (processStart in TPPAppDelegate,
//  didFinishLaunching in TPPAppDelegate, firstFrame in SceneDelegate,
//  catalogLoaded in CatalogViewModel) yields a non-nil, correctly-ordered
//  timeToInteractive / timeToFirstFrame.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

@MainActor
final class AppLaunchTrackerWiringTests: XCTestCase {

    private var tracker: AppLaunchTracker!
    private var monitor: PerformanceMonitor!

    override func setUp() {
        super.setUp()
        // Fresh injected instance — never the `.shared` singleton — so the
        // launch-timing state can't bleed across tests.
        monitor = PerformanceMonitor()
        tracker = AppLaunchTracker(performanceMonitor: monitor)
    }

    override func tearDown() {
        tracker = nil
        monitor = nil
        super.tearDown()
    }

    /// Records the launch milestones in production order and asserts the
    /// derived timings are non-nil and monotonically ordered. This is the
    /// contract the instrumentation exists to satisfy: with `processStart`
    /// recorded (TPPAppDelegate) plus `firstFrame` (SceneDelegate) and
    /// `catalogLoaded` (CatalogViewModel), both `timeToFirstFrame` and
    /// `timeToInteractive` compute non-nil.
    func testLaunchTracker_recordsMilestones_computesTimeToInteractive() async {
        await tracker.recordMilestone(.processStart)
        try? await Task.sleep(nanoseconds: 15_000_000) // 15ms
        await tracker.recordMilestone(.didFinishLaunching)
        try? await Task.sleep(nanoseconds: 15_000_000)
        await tracker.recordMilestone(.firstFrame)
        try? await Task.sleep(nanoseconds: 15_000_000)
        await tracker.recordMilestone(.catalogLoaded)

        // timeToInteractive = processStart -> catalogLoaded must be non-nil and
        // strictly positive (kills the `endTime - startTime` sign-flip mutant).
        let tti = await tracker.timeToInteractive
        XCTAssertNotNil(tti, "timeToInteractive must be non-nil once processStart and catalogLoaded are recorded")
        XCTAssertGreaterThan(tti ?? 0, 0, "timeToInteractive must be strictly positive")

        // timeToFirstFrame = processStart -> firstFrame must also be non-nil.
        let ttf = await tracker.timeToFirstFrame
        XCTAssertNotNil(ttf, "timeToFirstFrame must be non-nil once processStart and firstFrame are recorded")
        XCTAssertGreaterThan(ttf ?? 0, 0, "timeToFirstFrame must be strictly positive")

        // Ordering: firstFrame precedes catalogLoaded, so ttf < tti. This is the
        // wiring invariant — a swapped/duplicated milestone would break it.
        XCTAssertLessThan(ttf ?? .greatestFiniteMagnitude, tti ?? 0,
                          "first frame must be reached before catalog load")

        // Each adjacent segment is individually positive.
        let launchToFrame = await tracker.timeBetween(.didFinishLaunching, .firstFrame)
        XCTAssertNotNil(launchToFrame)
        XCTAssertGreaterThan(launchToFrame ?? 0, 0,
                             "didFinishLaunching must precede firstFrame")
    }

    /// Before `.firstFrame` is recorded, `timeToFirstFrame` must be nil — proves
    /// the tracker doesn't fabricate a timing from a missing milestone (the exact
    /// failure mode that would make a launch metric silently meaningless).
    func testLaunchTracker_firstFrameUnrecorded_timeToFirstFrameIsNil() async {
        await tracker.recordMilestone(.processStart)
        await tracker.recordMilestone(.didFinishLaunching)

        let ttf = await tracker.timeToFirstFrame
        XCTAssertNil(ttf, "timeToFirstFrame must be nil until .firstFrame is recorded")
    }
}

//
//  NowPlayingCoordinatorBackgroundTests.swift
//  PalaceTests
//
//  Regression coverage for HelpSpot 17865 — Audiobook NowPlaying freeze on
//  background → foreground.
//
//  Three behaviors are pinned here:
//
//  1. testApplyUpdate_inBackground_bypassesDebounce — when the app is not
//     active, MPNowPlayingInfoCenter writes must NOT be debounced. The
//     main-queue scheduler stalls during suspend; debounced work items can
//     vanish, leaving the system info stale.
//
//  2. testApplyUpdate_inForeground_debouncesAsBefore — pre-fix behavior must
//     survive: in `.active` state, rapid updates (chapter changes, scrubs)
//     coalesce.
//
//  3. testDryStreamGuard_logsErrorOnForegroundReturn_whenLastUpdateStale —
//     on foreground return, if `isPlaying` is true but the writer was dry
//     for >30s during background, a Crashlytics error is logged. This is
//     the canary for future toolkit-timer regressions of the same shape.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import MediaPlayer
import UIKit
import XCTest
@testable import Palace
@testable import PalaceAudiobookToolkit

@MainActor
final class NowPlayingCoordinatorBackgroundTests: XCTestCase {

    private var coordinator: NowPlayingCoordinator!
    private var fakeAppState: UIApplication.State = .active
    private var fakeNow: Date = Date()
    private var loggedDryStreamErrors: [(summary: String, metadata: [String: Any])] = []

    override func setUp() {
        super.setUp()
        fakeAppState = .active
        fakeNow = Date()
        loggedDryStreamErrors = []

        coordinator = NowPlayingCoordinator(
            applicationStateProvider: { [unowned self] in self.fakeAppState },
            dryStreamLogger: { [unowned self] summary, metadata in
                self.loggedDryStreamErrors.append((summary, metadata ?? [:]))
            },
            now: { [unowned self] in self.fakeNow }
        )
    }

    override func tearDown() {
        coordinator.clearNowPlaying()
        coordinator = nil
        super.tearDown()
    }

    // MARK: - Test 4: Background bypasses debounce

    /// HelpSpot 17865 — When the app is backgrounded the debounced
    /// DispatchWorkItem can be silently dropped (the main queue stalls).
    /// applyUpdate must therefore go direct in any non-`.active` state.
    func testApplyUpdate_inBackground_bypassesDebounce() {
        // Arrange: background state
        fakeAppState = .background

        // Act: two rapid writes within the debounce window (0.3s)
        coordinator.updateNowPlaying(
            title: "Chapter A", artist: nil, album: nil,
            elapsed: 10, duration: 100, isPlaying: true, playbackRate: .normalTime
        )
        coordinator.updateNowPlaying(
            title: "Chapter B", artist: nil, album: nil,
            elapsed: 20, duration: 100, isPlaying: true, playbackRate: .normalTime
        )

        // Assert: second write applied SYNCHRONOUSLY — no waiting for
        // debounce. Pre-fix the second write would be queued via
        // DispatchQueue.main.asyncAfter and never fire under suspend.
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        XCTAssertEqual(
            info?[MPMediaItemPropertyTitle] as? String,
            "Chapter B",
            "Background updates must go direct, not via debounce — debounced work strands during suspend. HelpSpot 17865."
        )
        let elapsed = info?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? -1
        XCTAssertEqual(elapsed, 20.0, accuracy: 0.01, "Second background write should be live, not queued.")
    }

    // MARK: - Test 5: Foreground still debounces

    /// Regression guard: in foreground, rapid updates must still coalesce so
    /// we don't spam MPNowPlayingInfoCenter on every chapter-tick / scrub.
    func testApplyUpdate_inForeground_debouncesAsBefore() {
        // Arrange: active state
        fakeAppState = .active

        // Act: first write goes through immediately (lastUpdateTime is
        // distantPast). Sleep just long enough that the next write IS
        // within the debounce window.
        coordinator.updateNowPlaying(
            title: "Chapter A", artist: nil, album: nil,
            elapsed: 10, duration: 100, isPlaying: true, playbackRate: .normalTime
        )

        // Now schedule two more writes synchronously. They land within the
        // 0.3s debounce window and the second should win, but the result is
        // visible only after the runloop processes the scheduled work.
        coordinator.updateNowPlaying(
            title: "Chapter B", artist: nil, album: nil,
            elapsed: 20, duration: 100, isPlaying: true, playbackRate: .normalTime
        )
        coordinator.updateNowPlaying(
            title: "Chapter C", artist: nil, album: nil,
            elapsed: 30, duration: 100, isPlaying: true, playbackRate: .normalTime
        )

        // Immediately after, info should still show Chapter A — the next
        // two writes are queued via debounce.
        let infoBeforeWait = MPNowPlayingInfoCenter.default().nowPlayingInfo
        XCTAssertEqual(
            infoBeforeWait?[MPMediaItemPropertyTitle] as? String,
            "Chapter A",
            "Foreground debounce must coalesce rapid updates — pre-fix behavior preserved."
        )

        // Production debounce schedules a `Task { try await Task.sleep(...) }`
        // (NowPlayingCoordinator.swift L282-292). Tasks don't hop the main
        // queue, so `drainMainQueue` would miss the resolution — poll the
        // observable system signal instead.
        awaitCondition(timeout: 5) {
            let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
            return (info?[MPMediaItemPropertyTitle] as? String) == "Chapter C"
        }

        // After waiting, Chapter C (the last one) should be live.
        let infoAfter = MPNowPlayingInfoCenter.default().nowPlayingInfo
        XCTAssertEqual(
            infoAfter?[MPMediaItemPropertyTitle] as? String,
            "Chapter C",
            "After debounce flush, the latest title should be set."
        )
    }

    // MARK: - Test 6: Dry-stream guard logs error on stale foreground return

    /// HelpSpot 17865 instrumentation — when the app returns to foreground
    /// from a long suspend and the last MPNowPlayingInfoCenter write was
    /// >30s ago (while `isPlaying=true`), we log to Crashlytics. This is
    /// the canary for any future regression of the same shape (toolkit
    /// timer paused, position publisher dry, lock screen frozen).
    func testDryStreamGuard_logsErrorOnForegroundReturn_whenLastUpdateStale() {
        // Arrange: a baseline write while playing.
        fakeAppState = .background  // background path goes direct, so we
                                    // know lastUpdateTime advances
        let t0 = Date()
        fakeNow = t0
        coordinator.updateNowPlaying(
            title: "Stranded", artist: nil, album: nil,
            elapsed: 10, duration: 600, isPlaying: true, playbackRate: .normalTime
        )

        // Act: simulate the dry stream — back-date lastUpdateTime past the
        // 30s freshness threshold. Use the injected clock so the boundary
        // is exact and reproducible (no wall-time jitter).
        coordinator._test_setLastUpdateTime(t0)
        coordinator._test_setLastIsPlaying(true)
        fakeNow = t0.addingTimeInterval(45)  // 45s elapsed (above threshold)

        // Cross back to foreground; the coordinator checks the guard here.
        fakeAppState = .active
        coordinator.applicationDidBecomeActive()

        // Assert: one Crashlytics error logged with the dry-stream summary.
        XCTAssertEqual(
            loggedDryStreamErrors.count, 1,
            "Foreground return after a >30s dry stream while isPlaying must log to Crashlytics."
        )
        XCTAssertTrue(
            loggedDryStreamErrors.first?.summary.contains("dry") == true,
            "Logged summary should mention the dry-stream condition."
        )
        let seconds = loggedDryStreamErrors.first?.metadata["secondsSinceLastUpdate"] as? Double ?? 0
        XCTAssertEqual(seconds, 45.0, accuracy: 0.001, "Logged metadata should reflect injected clock.")
    }

    /// Guard NEGATIVE case — fresh stream must not log. Without this we
    /// could regress to "always log on foreground return", which would
    /// drown Crashlytics in noise.
    func testDryStreamGuard_doesNotLog_whenStreamIsFresh() {
        // Arrange: fresh write, then immediate foreground transition.
        coordinator.updateNowPlaying(
            title: "Fresh", artist: nil, album: nil,
            elapsed: 10, duration: 600, isPlaying: true, playbackRate: .normalTime
        )

        // Act: foreground return WITHOUT back-dating lastUpdateTime.
        fakeAppState = .active
        coordinator.applicationDidBecomeActive()

        // Assert: no log fired.
        XCTAssertEqual(
            loggedDryStreamErrors.count, 0,
            "Fresh stream on foreground return must not log — would be Crashlytics noise."
        )
    }

    /// Boundary case — at EXACTLY the threshold (30s) the guard must NOT
    /// fire. The condition is `> 30`, not `>= 30`. Without this test the
    /// `>` → `>=` mutant survives. Uses the injected clock so the boundary
    /// is exact and reproducible.
    func testDryStreamGuard_doesNotLog_atExactlyThreshold() {
        let t0 = Date()
        fakeNow = t0

        coordinator.updateNowPlaying(
            title: "Boundary", artist: nil, album: nil,
            elapsed: 10, duration: 600, isPlaying: true, playbackRate: .normalTime
        )

        // Pin the clock at EXACTLY 30s after lastUpdateTime. With `>`
        // (production), 30 > 30 is false → no log. With `>=` (mutant),
        // 30 >= 30 is true → log. So `count == 0` kills the `>=` mutant.
        coordinator._test_setLastUpdateTime(t0)
        coordinator._test_setLastIsPlaying(true)
        fakeNow = t0.addingTimeInterval(30.0)

        fakeAppState = .active
        coordinator.applicationDidBecomeActive()

        XCTAssertEqual(
            loggedDryStreamErrors.count, 0,
            "At EXACTLY the 30s threshold the guard must NOT fire (`>` not `>=`)."
        )
    }

    /// Guard NEGATIVE case — not playing means no expectation of timer
    /// freshness, so no log even if lastUpdateTime is old.
    func testDryStreamGuard_doesNotLog_whenNotPlaying() {
        coordinator.updateNowPlaying(
            title: "Paused", artist: nil, album: nil,
            elapsed: 10, duration: 600, isPlaying: false, playbackRate: .normalTime
        )

        coordinator._test_setLastUpdateTime(Date(timeIntervalSinceNow: -120))
        coordinator._test_setLastIsPlaying(false)

        fakeAppState = .active
        coordinator.applicationDidBecomeActive()

        XCTAssertEqual(
            loggedDryStreamErrors.count, 0,
            "Paused playback has no timer-freshness expectation — must not log."
        )
    }
}

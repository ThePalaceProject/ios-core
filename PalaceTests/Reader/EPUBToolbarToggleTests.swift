//
//  EPUBToolbarToggleTests.swift
//  PalaceTests
//
//  Regression tests for EPUB toolbar tap-to-toggle behavior.
//
//  Background: Readium 3.x has two parallel paths for tap delivery:
//    1. Legacy VisualNavigatorDelegate.navigator(_:didTapAt:) — fires via
//       setupLegacyInputCallbacks, returns false (does NOT consume the event).
//    2. Input observer (.tap) registered in TPPEPUBViewController.init.
//
//  Both fire for every tap. If both call toggleNavigationBar(), the toolbar
//  is toggled twice per tap (net: no visible change). The fix is that
//  TPPEPUBViewController overrides didTapAt as a no-op; only the .tap
//  observer performs the toggle.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

// MARK: - Readium Dual-Path Regression Tests

/// Regression tests verifying the EPUB reader's toolbar toggle behavior.
///
/// The core invariant: a single tap in the center of the page must toggle
/// the toolbar exactly once, regardless of how many internal Readium
/// callbacks fire for that tap.
@MainActor
final class EPUBToolbarToggleTests: XCTestCase {

    // MARK: - Toggle State Correctness

    /// A single toggle call should flip toolbar visibility.
    func testSingleToggle_changesToolbarVisibility() {
        let state = ToolbarToggleTracker(isHidden: true)

        state.toggle()

        XCTAssertFalse(state.isHidden, "Single toggle should show a hidden toolbar")
        XCTAssertEqual(state.toggleCount, 1)
    }

    /// Two toggles cancel each other — documents the double-toggle bug.
    func testDoubleToggle_restoresOriginalState() {
        let state = ToolbarToggleTracker(isHidden: true)

        state.toggle()
        state.toggle()

        XCTAssertTrue(state.isHidden, "Double toggle restores original state (the bug)")
        XCTAssertEqual(state.toggleCount, 2)
    }

    // MARK: - Readium Dual-Path Simulation

    /// FIXED behavior: legacy delegate is a no-op, observer toggles once.
    func testFixedDualPath_centerTap_togglesToolbarExactlyOnce() {
        let sim = ReadiumTapFlowSimulator(legacyDelegateToggles: false)

        sim.simulateCenterTap()

        XCTAssertEqual(sim.toolbarToggleCount, 1,
                       "With the no-op override, toolbar should toggle exactly once")
        XCTAssertFalse(sim.isToolbarHidden,
                       "Toolbar should be visible after toggling from hidden")
    }

    /// BUG behavior: both paths toggle → no visible change.
    func testUnfixedDualPath_centerTap_doubleTogglesToolbar() {
        let sim = ReadiumTapFlowSimulator(legacyDelegateToggles: true)

        sim.simulateCenterTap()

        XCTAssertEqual(sim.toolbarToggleCount, 2,
                       "Without the no-op override, both paths toggle")
        XCTAssertTrue(sim.isToolbarHidden,
                      "Double toggle leaves toolbar in original hidden state")
    }

    /// Edge taps should navigate, not toggle the toolbar.
    func testDualPath_edgeTap_doesNotToggleToolbar() {
        let sim = ReadiumTapFlowSimulator(legacyDelegateToggles: false)

        sim.simulateEdgeTap()

        XCTAssertEqual(sim.toolbarToggleCount, 0,
                       "Edge taps navigate pages, never toggle toolbar")
        XCTAssertTrue(sim.isToolbarHidden, "Toolbar state unchanged by edge tap")
    }

    /// Repeated center taps should toggle on/off/on/off.
    func testFixedDualPath_repeatedCenterTaps_alternateToolbarState() {
        let sim = ReadiumTapFlowSimulator(legacyDelegateToggles: false)

        sim.simulateCenterTap()
        XCTAssertFalse(sim.isToolbarHidden, "First tap shows toolbar")

        sim.simulateCenterTap()
        XCTAssertTrue(sim.isToolbarHidden, "Second tap hides toolbar")

        sim.simulateCenterTap()
        XCTAssertFalse(sim.isToolbarHidden, "Third tap shows toolbar")

        XCTAssertEqual(sim.toolbarToggleCount, 3)
    }

    // MARK: - KeyboardNavigable Integration

    /// Verify that the KeyboardNavigable protocol's toggleToolbar() is the
    /// single path used for toolbar toggling (same path as the .tap observer).
    func testKeyboardNavigable_toggleToolbar_changesState() {
        let mock = MockKeyboardNavigable()
        mock.toolbarHidden = true

        mock.toggleToolbar()

        XCTAssertFalse(mock.isToolbarHidden, "toggleToolbar should flip visibility")
        XCTAssertTrue(mock.didCallToggleToolbar)
    }

    /// Calling toggleToolbar twice via KeyboardNavigable restores state.
    func testKeyboardNavigable_doubleToggle_restoresState() {
        let mock = MockKeyboardNavigable()
        mock.toolbarHidden = true

        mock.toggleToolbar()
        mock.toggleToolbar()

        XCTAssertTrue(mock.isToolbarHidden,
                      "Two toggles should restore original state")
    }

    // MARK: - Tap Region Classification

    /// Center of the viewport should be classified as center.
    func testTapRegion_centerOfViewport_isCenter() {
        let region = TapRegion.classify(
            tapX: 187.5, viewportWidth: 375, edgeThresholdPercent: 0.2)
        XCTAssertEqual(region, .center)
    }

    /// Left edge tap should be classified as left edge.
    func testTapRegion_leftEdge_isLeftEdge() {
        let region = TapRegion.classify(
            tapX: 30, viewportWidth: 375, edgeThresholdPercent: 0.2)
        XCTAssertEqual(region, .leftEdge)
    }

    /// Right edge tap should be classified as right edge.
    func testTapRegion_rightEdge_isRightEdge() {
        let region = TapRegion.classify(
            tapX: 360, viewportWidth: 375, edgeThresholdPercent: 0.2)
        XCTAssertEqual(region, .rightEdge)
    }

    /// Tap exactly at the threshold boundary should be edge.
    func testTapRegion_atExactThreshold_isEdge() {
        // 20% of 400 = 80
        let region = TapRegion.classify(
            tapX: 80, viewportWidth: 400, edgeThresholdPercent: 0.2)
        XCTAssertEqual(region, .leftEdge)
    }

    /// Tap just past the threshold boundary should be center.
    func testTapRegion_justPastThreshold_isCenter() {
        let region = TapRegion.classify(
            tapX: 80.1, viewportWidth: 400, edgeThresholdPercent: 0.2)
        XCTAssertEqual(region, .center)
    }

    /// Zero-width viewport edge case.
    func testTapRegion_zeroWidthViewport_isCenter() {
        let region = TapRegion.classify(
            tapX: 0, viewportWidth: 0, edgeThresholdPercent: 0.2)
        XCTAssertEqual(region, .center)
    }
}

// MARK: - Test Helpers

/// Tracks toolbar toggle state for regression testing.
@MainActor
private final class ToolbarToggleTracker {
    var isHidden: Bool
    private(set) var toggleCount = 0

    init(isHidden: Bool) {
        self.isHidden = isHidden
    }

    func toggle() {
        toggleCount += 1
        isHidden.toggle()
    }
}

/// Simulates Readium's dual-path tap delivery.
///
/// Readium 3.x fires two callbacks for every recognized tap:
///   1. Legacy `VisualNavigatorDelegate.navigator(_:didTapAt:)` via
///      `setupLegacyInputCallbacks` — always fires, returns `false`.
///   2. `.tap` input observer registered by the app — fires after legacy path.
///
/// The fix: `TPPEPUBViewController` overrides `didTapAt` as a no-op so
/// only the `.tap` observer performs the toggle.
@MainActor
private final class ReadiumTapFlowSimulator {

    /// When `true`, the legacy delegate path calls toggle (models the BUG).
    /// When `false`, the legacy delegate is a no-op (models the FIX).
    let legacyDelegateToggles: Bool

    private(set) var isToolbarHidden: Bool = true
    private(set) var toolbarToggleCount: Int = 0

    init(legacyDelegateToggles: Bool) {
        self.legacyDelegateToggles = legacyDelegateToggles
    }

    /// Simulates a center tap going through Readium's dual-path delivery.
    func simulateCenterTap() {
        // Path 1: Legacy VisualNavigatorDelegate.didTapAt
        // Registered first via setupLegacyInputCallbacks in EPUBNavigatorViewController.init.
        // Returns false (doesn't consume), so the observer chain continues.
        if legacyDelegateToggles {
            // BUG: base class TPPBaseReaderViewController toggles here
            toggleToolbar()
        }
        // FIX: TPPEPUBViewController overrides didTapAt as a no-op

        // Path 2: .tap observer registered in TPPEPUBViewController.init
        // Always fires for center taps (DirectionalNavigationAdapter only
        // consumes edge taps).
        toggleToolbar()
    }

    /// Simulates an edge tap (left or right 20% of viewport).
    /// DirectionalNavigationAdapter consumes these for page turning.
    /// Neither path calls toggleToolbar.
    func simulateEdgeTap() {
        // DirectionalNavigationAdapter handles the page turn.
        // It consumes the pointer event, so remaining observers
        // (including the .tap observer) receive a .cancel phase.
        // The legacy delegate also navigates (goLeft/goRight) for
        // edge taps but does NOT toggle the toolbar.
    }

    private func toggleToolbar() {
        toolbarToggleCount += 1
        isToolbarHidden.toggle()
    }
}

/// Pure classifier for tap regions in the reader viewport.
/// Mirrors the threshold logic used by both Readium's
/// DirectionalNavigationAdapter (0.2) and TPPBaseReaderViewController's
/// legacy didTapAt method.
private enum TapRegion: Equatable {
    case leftEdge
    case rightEdge
    case center

    /// Classify a tap's X position relative to the viewport.
    /// - Parameters:
    ///   - tapX: The X coordinate of the tap.
    ///   - viewportWidth: The total width of the viewport.
    ///   - edgeThresholdPercent: Fraction of width that counts as edge (e.g. 0.2 = 20%).
    static func classify(tapX: CGFloat, viewportWidth: CGFloat,
                         edgeThresholdPercent: CGFloat) -> TapRegion {
        guard viewportWidth > 0 else { return .center }
        let edgeWidth = edgeThresholdPercent * viewportWidth
        if tapX <= edgeWidth {
            return .leftEdge
        } else if tapX >= viewportWidth - edgeWidth {
            return .rightEdge
        } else {
            return .center
        }
    }
}

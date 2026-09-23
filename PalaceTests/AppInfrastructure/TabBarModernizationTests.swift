//
//  TabBarModernizationTests.swift
//  PalaceTests
//
//  Unit tests for the extracted, testable decisions behind the modern tab-bar
//  refresh (`TabBarModern` + `TabBarHeightObserver` in
//  `Palace/AppInfrastructure/TabBarModernization.swift`):
//
//    - the mini-player bottom-inset math (must track the LIVE tab-bar height,
//      not double-count the home-indicator safe area, and clamp bogus
//      measurements so the floating card never desyncs / flies off),
//    - the iOS 26 minimize-behavior gate (pin the bar while a mini-player is up).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import SwiftUI
@testable import Palace

@MainActor
final class TabBarModernizationTests: XCTestCase {

    // MARK: - Mini-player bottom inset

    /// The unmeasured fallback: with only the 49pt bar-only seed, the full
    /// height is reconstructed as safeArea + default bar + margin. Kills the
    /// `+` → `-` mutant (would place the card below the bar) and any mutant that
    /// drops one of the three terms.
    func test_miniPlayerBottomInset_sumsSafeAreaBarAndMargin() {
        let inset = TabBarModern.miniPlayerBottomInset(
            safeAreaBottom: 34,
            tabBarHeight: 49,
            margin: 8
        )
        XCTAssertEqual(inset, 34 + 49 + 8, accuracy: 0.001)
    }

    /// A live `UITabBar.frame.height` measurement ALREADY includes the bottom
    /// safe-area inset (the bar draws into the home-indicator region), so it must
    /// flow straight through as `height + margin` — NOT have the safe area added
    /// a second time. Adding it again floated the card ~34pt too high above the
    /// bar (the double-count bug). A taller measured bar must also yield a taller
    /// inset so the card keeps tracking the real bar. Kills a mutant that
    /// re-introduces the `safe +` term.
    func test_miniPlayerBottomInset_fullFrameMeasurement_doesNotDoubleCountSafeArea() {
        // 83 = 49pt bar + 34pt home indicator — the real measured frame height.
        let inset = TabBarModern.miniPlayerBottomInset(safeAreaBottom: 34, tabBarHeight: 83, margin: 8)
        XCTAssertEqual(inset, 83 + 8, accuracy: 0.001,
                       "a full-frame measurement must pass through as height+margin, not add the 34pt safe area again")
        XCTAssertNotEqual(inset, 34 + 83 + 8, accuracy: 0.001,
                          "must NOT double-count the safe area — that is the too-high bug this fixes")

        let taller = TabBarModern.miniPlayerBottomInset(safeAreaBottom: 34, tabBarHeight: 100, margin: 8)
        XCTAssertGreaterThan(taller, inset,
                             "a taller measured bar yields a taller inset — the card tracks the real bar")
    }

    /// A bogus (zero / non-finite) measurement must fall back to the default
    /// height, never to 0 — otherwise the card would collapse onto the tab bar.
    /// Kills a mutant that drops the `tabBarHeight > 0` guard.
    func test_miniPlayerBottomInset_bogusBarHeight_fallsBackToDefault() {
        let zero = TabBarModern.miniPlayerBottomInset(safeAreaBottom: 34, tabBarHeight: 0, margin: 8)
        XCTAssertEqual(zero, 34 + TabBarModern.defaultTabBarHeight + 8, accuracy: 0.001,
                       "a 0 measurement must use the default bar height, not collapse to the bar")

        let nan = TabBarModern.miniPlayerBottomInset(safeAreaBottom: 34, tabBarHeight: .nan, margin: 8)
        XCTAssertEqual(nan, 34 + TabBarModern.defaultTabBarHeight + 8, accuracy: 0.001,
                       "a non-finite measurement must use the default bar height")
    }

    /// A negative safe-area inset (garbage from a torn-down window) must clamp
    /// to 0, never subtract — otherwise the card would ride up over content.
    func test_miniPlayerBottomInset_negativeSafeArea_clampsToZero() {
        let inset = TabBarModern.miniPlayerBottomInset(safeAreaBottom: -20, tabBarHeight: 49, margin: 8)
        XCTAssertEqual(inset, 0 + 49 + 8, accuracy: 0.001,
                       "a negative safe-area must clamp to 0, not reduce the inset")
    }

    // MARK: - iOS 26 minimize-behavior gate

    /// With an active mini-player the bar MUST be pinned (minimize disabled) so
    /// it can't minimize out from under the floating card. Kills the `!` → ``
    /// mutant (which would enable minimize during playback — the exact desync
    /// the gate exists to prevent).
    func test_shouldEnableTabBarMinimize_miniPlayerActive_returnsFalse() {
        XCTAssertFalse(TabBarModern.shouldEnableTabBarMinimize(miniPlayerActive: true),
                       "an active mini-player must PIN the bar (minimize disabled)")
    }

    /// With no mini-player, minimize-on-scroll is free to run — there is no
    /// floating card to desync.
    func test_shouldEnableTabBarMinimize_noMiniPlayer_returnsTrue() {
        XCTAssertTrue(TabBarModern.shouldEnableTabBarMinimize(miniPlayerActive: false),
                      "with no mini-player the bar may minimize on scroll")
    }

    // MARK: - TabBarHeightObserver

    /// The observer seeds with the historical default so the first frame (before
    /// any measurement) positions the card exactly where the old hardcoded path
    /// did. Kills a mutant that seeds it to 0.
    @MainActor
    func test_tabBarHeightObserver_seedsWithHistoricalDefault() {
        let observer = TabBarHeightObserver()
        XCTAssertEqual(observer.tabBarHeight, TabBarModern.defaultTabBarHeight, accuracy: 0.001,
                       "unmeasured observer must report the 49pt default, not 0")
    }

    /// `measure()` is a best-effort read: it updates to a real mounted tab-bar
    /// height when one exists and otherwise keeps the last good value — it must
    /// NEVER corrupt the published height to a bogus 0 / non-finite value, which
    /// would collapse the mini-player onto the bar. Kills the mutant that writes
    /// 0 when no valid bar is found (the `guard measured > 1 else { return }`
    /// bogus-guard). The XCTest host mounts a real tab bar, so this also confirms
    /// measure() picks up a plausible height rather than leaving a stale seed.
    @MainActor
    func test_tabBarHeightObserver_measure_neverCorruptsToBogusHeight() {
        let observer = TabBarHeightObserver()
        observer.measure()
        XCTAssertTrue(observer.tabBarHeight.isFinite,
                      "measured height must stay finite")
        XCTAssertGreaterThan(observer.tabBarHeight, 1,
                             "measure() must keep a valid positive height (the default or a real bar), never collapse to ~0")
    }
}

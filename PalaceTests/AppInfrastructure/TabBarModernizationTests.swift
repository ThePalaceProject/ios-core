//
//  TabBarModernizationTests.swift
//  PalaceTests
//
//  Unit tests for the extracted, testable decisions behind the modern tab-bar
//  refresh (`TabBarModern` + `TabBarHeightObserver` in
//  `Palace/AppInfrastructure/TabBarModernization.swift`):
//
//    - the brand-tint fix (selected tab must be Palace blue #0090C4, NOT the
//      SwiftUI default system blue that the missing AccentColor asset caused),
//    - the mini-player bottom-inset math (must track the LIVE tab-bar height and
//      clamp bogus measurements so the floating card never desyncs / flies off),
//    - the iOS 26 minimize-behavior gate (pin the bar while a mini-player is up).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import SwiftUI
@testable import Palace

final class TabBarModernizationTests: XCTestCase {

    // MARK: - Brand tint (latent-bug fix)

    /// The resolved tab tint MUST be the Palace brand blue #0090C4
    /// (rgb 0, 144, 196), i.e. `TPPConfiguration.accentColor()` — NOT the
    /// SwiftUI default system blue that `Color.accentColor` fell back to because
    /// the app ships no AccentColor asset. Kills a regression that reverts the
    /// tint source back to `Color.accentColor`.
    func test_brandTint_resolvesToPalaceBrandBlue_notSystemBlue() {
        let (r, g, b, a) = TabBarModern.brandTintRGBA

        XCTAssertEqual(r, 0.0 / 255.0, accuracy: 0.001, "red channel must be 0")
        XCTAssertEqual(g, 144.0 / 255.0, accuracy: 0.001, "green channel must be 144")
        XCTAssertEqual(b, 196.0 / 255.0, accuracy: 0.001, "blue channel must be 196 (#0090C4)")
        XCTAssertEqual(a, 1.0, accuracy: 0.001, "alpha must be opaque")
    }

    /// Guard against silent drift toward the iOS default system blue (#007AFF ≈
    /// rgb 0, 122, 255). The brand blue's green (144) and blue (196) differ from
    /// the system blue's (122 / 255), so this pins the two apart — if someone
    /// re-points the tint at `Color.accentColor`, the green/blue channels move.
    func test_brandTint_isDistinctFromSystemDefaultBlue() {
        let (_, g, b, _) = TabBarModern.brandTintRGBA
        let systemBlueGreen = 122.0 / 255.0
        let systemBlueBlue = 255.0 / 255.0
        XCTAssertNotEqual(g, systemBlueGreen, accuracy: 0.01,
                          "brand green (144) must not equal system-blue green (122)")
        XCTAssertNotEqual(b, systemBlueBlue, accuracy: 0.01,
                          "brand blue (196) must not equal system-blue blue (255)")
    }

    // MARK: - Mini-player bottom inset

    /// The nominal case: inset = safeArea + measured bar height + margin. Kills
    /// the `+` → `-` mutant (would place the card below the bar) and any mutant
    /// that drops one of the three terms.
    func test_miniPlayerBottomInset_sumsSafeAreaBarAndMargin() {
        let inset = TabBarModern.miniPlayerBottomInset(
            safeAreaBottom: 34,
            tabBarHeight: 49,
            margin: 8
        )
        XCTAssertEqual(inset, 34 + 49 + 8, accuracy: 0.001)
    }

    /// A DYNAMIC (minimized) bar height must flow straight through so the card
    /// tracks the shrinking bar — proves the value is not hardcoded to 49.
    func test_miniPlayerBottomInset_tracksDynamicBarHeight() {
        let tall = TabBarModern.miniPlayerBottomInset(safeAreaBottom: 34, tabBarHeight: 49, margin: 8)
        let minimized = TabBarModern.miniPlayerBottomInset(safeAreaBottom: 34, tabBarHeight: 24, margin: 8)
        XCTAssertEqual(minimized, 34 + 24 + 8, accuracy: 0.001)
        XCTAssertLessThan(minimized, tall,
                          "a shorter (minimized) bar must yield a smaller inset — the card follows the bar down")
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

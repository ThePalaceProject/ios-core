//
//  TabBarModernization.swift
//  Palace
//
//  Extracted, unit-testable seams for the modern tab-bar refresh (the main app
//  `TabView` in `AppTabHostView`). Keeping the *decisions* here — the resolved
//  brand tint, the mini-player bottom-inset math, and the minimize-behavior
//  gate — means the SwiftUI view stays declarative while the behavior that could
//  regress (wrong tint, mini-player desync under a minimizing bar, minimize
//  enabled while a session floats above the bar) is covered by tests that don't
//  need a SwiftUI host.
//
//  Deployment floor is iOS 17 (see `PalaceMotion` / project settings), so
//  `.tint(_:)` and `.sensoryFeedback`/`palaceHaptic` are available
//  unconditionally. Only the iOS 18 `Tab(value:role:)` builder and the iOS 26
//  Liquid-Glass `.tabBarMinimizeBehavior` are `@available`-gated progressive
//  enhancements in `AppTabHostView`.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import SwiftUI
import UIKit

// MARK: - Pure decisions

/// Namespace for the modern tab-bar's pure decisions. Not a view — a home for
/// the values `AppTabHostView` reads, so each is independently testable.
enum TabBarModern {

    /// The selected-tab tint. Resolves to the Palace brand blue (`#0090C4`) via
    /// `TPPConfiguration.accentColor()` rather than SwiftUI's `Color.accentColor`.
    ///
    /// LATENT BUG this fixes: the app ships **no** `AccentColor` asset-catalog
    /// entry and sets no `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME`, so
    /// `Color.accentColor` fell back to the SwiftUI default system blue
    /// (`#007AFF`) — the selected tab was NOT brand-colored. Sourcing the tint
    /// from `TPPConfiguration.accentColor()` (the single brand-blue source the
    /// rest of the app already uses, e.g. `NormalBookCell`) makes the selected
    /// tab render brand blue in both light and dark appearance.
    static var brandTint: Color { Color(TPPConfiguration.accentColor()) }

    /// The brand tint as sRGB components, exposed for tests to assert the
    /// resolved value is brand blue and not the system default. Reads the same
    /// `UIColor` that `brandTint` wraps.
    static var brandTintRGBA: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        TPPConfiguration.accentColor().getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
    }

    /// Default `UITabBar` height (points) used before a live measurement is
    /// available, and the value the hardcoded constant historically assumed.
    static let defaultTabBarHeight: CGFloat = 49

    /// Breathing room between the minimized mini-player card and the tab bar.
    static let miniMargin: CGFloat = 8

    /// The bottom inset the floating audiobook mini-player must apply to sit
    /// exactly above the tab bar (and clear of the home-indicator safe area).
    ///
    /// Pure function of three measured inputs so the mini-player's vertical
    /// position tracks the ACTUAL tab bar — not a hardcoded 49pt guess. Under
    /// the iOS 26 minimize-on-scroll behavior the bar height is dynamic; feeding
    /// the *measured* `tabBarHeight` here keeps the card glued to the bar in
    /// every state. (We additionally gate minimize OFF while a session is active
    /// — see `shouldEnableTabBarMinimize` — so the height is also stable, giving
    /// belt-and-suspenders correctness.)
    ///
    /// - Parameters:
    ///   - safeAreaBottom: live bottom safe-area inset (home indicator).
    ///   - tabBarHeight: the measured tab bar height, or `defaultTabBarHeight`.
    ///   - margin: gap between the card and the bar.
    static func miniPlayerBottomInset(
        safeAreaBottom: CGFloat,
        tabBarHeight: CGFloat,
        margin: CGFloat = miniMargin
    ) -> CGFloat {
        // Guard against a spurious non-finite / negative measurement (e.g. a
        // window torn down mid-transition reporting garbage) so the card never
        // flies off-screen — fall back to the known-good default height.
        let safe = safeAreaBottom.isFinite && safeAreaBottom >= 0 ? safeAreaBottom : 0
        let bar = tabBarHeight.isFinite && tabBarHeight > 0 ? tabBarHeight : defaultTabBarHeight
        return safe + bar + margin
    }

    /// Whether the iOS 26 `.tabBarMinimizeBehavior(.onScrollDown)` enhancement
    /// should be ACTIVE.
    ///
    /// Minimize-on-scroll continuously changes the tab bar's height as the user
    /// scrolls. The audiobook mini-player floats above the bar and is glued to
    /// it; letting the bar minimize out from under an active mini-player would
    /// leave the card hovering over empty space (or over content) mid-scroll.
    /// So the enhancement is a *conditional* one: enabled only when there is no
    /// active audiobook session. With no session there is no mini-player to
    /// desync, so scroll-to-minimize is free to run.
    ///
    /// - Parameter miniPlayerActive: whether the mini-player overlay is mounted
    ///   (an audiobook session is active — the same predicate `AppTabHostView`
    ///   uses to mount `resizingPlayerOverlay`).
    /// - Returns: `true` to enable minimize-on-scroll, `false` to pin the bar.
    static func shouldEnableTabBarMinimize(miniPlayerActive: Bool) -> Bool {
        return !miniPlayerActive
    }
}

// MARK: - Environment: measured tab-bar inset for the mini-player

/// The measured bottom inset (safe area + live tab-bar height + margin) the
/// floating audiobook mini-player should apply. Injected by `AppTabHostView`
/// from a live measurement so the mini-player tracks the ACTUAL bar position
/// instead of a hardcoded 49pt constant. `nil` means "not measured yet" — the
/// mini-player then falls back to its own window-based default, which is exactly
/// the historical behavior, so there is never a worse position than before.
private struct MiniPlayerTabBarInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    /// See `MiniPlayerTabBarInsetKey`.
    var miniPlayerTabBarInset: CGFloat? {
        get { self[MiniPlayerTabBarInsetKey.self] }
        set { self[MiniPlayerTabBarInsetKey.self] = newValue }
    }
}

// MARK: - Live tab-bar height measurement

/// Publishes the live height of the app's `UITabBar` so the floating mini-player
/// can track the bar's ACTUAL position instead of a hardcoded 49pt constant.
///
/// The main `TabView` is backed by a `UITabBarController`; we read the real
/// `UITabBar.frame.height` from the key window. This is correct across device
/// classes and — critically — under the iOS 26 minimize-on-scroll behavior,
/// where the height is no longer a fixed 49.
///
/// Reading is best-effort: if no tab bar is found (early launch, torn-down
/// window) the published value stays at `TabBarModern.defaultTabBarHeight`,
/// which is exactly the value the old hardcoded path used — so there is never a
/// worse position than before.
@MainActor
final class TabBarHeightObserver: ObservableObject {

    /// Live tab-bar height; seeded with the historical default.
    @Published private(set) var tabBarHeight: CGFloat = TabBarModern.defaultTabBarHeight

    /// Re-measure the tab bar from the key window and publish if it changed.
    /// Cheap enough to call from `onAppear` and on layout/selection changes.
    func measure() {
        guard let measured = Self.currentTabBarHeight() else { return }
        // Ignore obviously-bogus measurements (0 or non-finite): keep the last
        // good value rather than collapsing the mini-player onto the tab bar.
        guard measured.isFinite, measured > 1 else { return }
        if abs(measured - tabBarHeight) > 0.5 {
            tabBarHeight = measured
        }
    }

    /// Finds the frontmost `UITabBar` in the key window's view hierarchy and
    /// returns its height, or `nil` if none is mounted yet.
    static func currentTabBarHeight() -> CGFloat? {
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        guard let root = keyWindow?.rootViewController else { return nil }
        guard let tabBar = firstTabBar(in: root.view) else { return nil }
        return tabBar.frame.height
    }

    /// Depth-first search for the first `UITabBar` in a view subtree.
    private static func firstTabBar(in view: UIView) -> UITabBar? {
        if let tabBar = view as? UITabBar { return tabBar }
        for subview in view.subviews {
            if let found = firstTabBar(in: subview) { return found }
        }
        return nil
    }
}

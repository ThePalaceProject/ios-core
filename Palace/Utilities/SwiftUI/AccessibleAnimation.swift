//
//  AccessibleAnimation.swift
//  Palace
//
//  Accessibility improvements for reduced motion support
//  Provides animations that respect the Reduce Motion accessibility setting.
//
//  The `.accessibleAnimation(_:value:)` view path is a `ViewModifier` that reads
//  `@Environment(\.accessibilityReduceMotion)`, so a mid-session Reduce Motion
//  toggle is picked up reactively (the old implementation snapshotted
//  `UIAccessibility.isReduceMotionEnabled` at body-evaluation time and did not
//  update until the view re-rendered for another reason).
//

import SwiftUI

// MARK: - Reactive Reduce-Motion Animation Modifier

/// Applies `.animation(_:value:)` but drops the animation (passes `nil`) while
/// Reduce Motion is enabled. Reads the accessibility environment so toggles mid
/// session are honored without a manual re-render.
struct ReduceMotionAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation?
    let value: V

    func body(content: Content) -> some View {
        content.animation(PalaceMotion.resolved(animation, reduceMotion: reduceMotion), value: value)
    }
}

// MARK: - Accessible Animation Extension

extension View {
    /// Applies an animation only if Reduce Motion is not enabled.
    /// Use this instead of `.animation(_:value:)` to respect accessibility settings.
    ///
    /// Reactive: reads `@Environment(\.accessibilityReduceMotion)`, so a Reduce
    /// Motion change during the session is honored immediately.
    ///
    /// - Parameters:
    ///   - animation: The animation to apply when Reduce Motion is disabled
    ///   - value: The value to monitor for changes
    /// - Returns: A view with accessible animation applied
    func accessibleAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(ReduceMotionAnimationModifier(animation: animation, value: value))
    }

    /// Wraps a state change in animation only if Reduce Motion is not enabled.
    /// Use this instead of `withAnimation { }` to respect accessibility settings.
    func withAccessibleAnimation<Result>(_ animation: Animation? = .default, _ body: () throws -> Result) rethrows -> Result {
        if UIAccessibility.isReduceMotionEnabled {
            return try body()
        } else {
            return try withAnimation(animation, body)
        }
    }
}

// MARK: - Accessible Transition

extension AnyTransition {
    /// Returns the transition if Reduce Motion is disabled, otherwise returns identity.
    @MainActor
    static func accessible(_ transition: AnyTransition) -> AnyTransition {
        UIAccessibility.isReduceMotionEnabled ? .identity : transition
    }
}

// MARK: - Global Helper

/// Performs an animation block only if Reduce Motion is not enabled.
/// Use this instead of `withAnimation { }` at the call site.
///
/// Example:
/// ```swift
/// accessibleWithAnimation {
///   showContent.toggle()
/// }
/// ```
@MainActor
func accessibleWithAnimation<Result>(_ animation: Animation? = .default, _ body: () throws -> Result) rethrows -> Result {
    if UIAccessibility.isReduceMotionEnabled {
        return try body()
    } else {
        return try withAnimation(animation, body)
    }
}

//
//  AccessibleAnimation.swift
//  Palace
//
//  Accessibility improvements for reduced motion support
//  Provides animations that respect the Reduce Motion accessibility setting.
//

import SwiftUI

// MARK: - Accessible Animation Extension

extension View {
    /// Applies an animation only if Reduce Motion is not enabled.
    /// Use this instead of `.animation(_:value:)` to respect accessibility settings.
    ///
    /// - Parameters:
    ///   - animation: The animation to apply when Reduce Motion is disabled
    ///   - value: The value to monitor for changes
    /// - Returns: A view with accessible animation applied
    @ViewBuilder
    func accessibleAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        if UIAccessibility.isReduceMotionEnabled {
            self
        } else {
            self.animation(animation, value: value)
        }
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
func accessibleWithAnimation<Result>(_ animation: Animation? = .default, _ body: () throws -> Result) rethrows -> Result {
    if UIAccessibility.isReduceMotionEnabled {
        return try body()
    } else {
        return try withAnimation(animation, body)
    }
}

//
//  PalaceHaptic.swift
//  Palace
//
//  A preference-gated SwiftUI haptic modifier. Wraps `.sensoryFeedback` and
//  consults `AccessibilityService`'s `hapticFeedbackEnabled` preference plus the
//  reduce-motion environment, so views can stop reaching for raw
//  `UIImpactFeedbackGenerator`. Broad adoption happens in later PRs.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import SwiftUI

extension View {
    /// Fires preference-gated sensory feedback when `trigger` changes.
    ///
    /// The feedback only plays when the user's `hapticFeedbackEnabled` preference
    /// (from the injected `AccessibilityServiceProtocol`) is on AND Reduce Motion
    /// is off. This mirrors the gating in `AccessibilityService.triggerHaptic` so
    /// SwiftUI views get the same honor-the-preference behavior declaratively.
    ///
    /// - Parameters:
    ///   - feedback: The `SensoryFeedback` to play.
    ///   - trigger: An `Equatable` value; feedback plays when it changes.
    ///   - service: The accessibility service supplying the preference. Defaults
    ///              to the shared service; inject a mock in tests.
    func palaceHaptic<T: Equatable>(
        _ feedback: SensoryFeedback,
        trigger: T,
        service: AccessibilityServiceProtocol = AccessibilityService.shared
    ) -> some View {
        modifier(PalaceHapticModifier(feedback: feedback, trigger: trigger, service: service))
    }
}

/// View modifier backing `palaceHaptic(_:trigger:service:)`. Subscribes to the
/// service's preference publisher and gates `.sensoryFeedback` accordingly.
struct PalaceHapticModifier<T: Equatable>: ViewModifier {
    let feedback: SensoryFeedback
    let trigger: T
    let service: AccessibilityServiceProtocol

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hapticEnabled: Bool = true

    func body(content: Content) -> some View {
        content
            .sensoryFeedback(trigger: trigger) { _, _ in
                PalaceHapticModifier.resolvedFeedback(
                    feedback,
                    hapticEnabled: hapticEnabled,
                    reduceMotion: reduceMotion
                )
            }
            .onReceive(service.preferencesPublisher.receive(on: DispatchQueue.main)) { prefs in
                hapticEnabled = prefs.hapticFeedbackEnabled
            }
    }

    /// Pure gating decision: returns the feedback to play, or `nil` to suppress.
    /// Suppresses when haptics are disabled in preferences OR Reduce Motion is on.
    static func resolvedFeedback(
        _ feedback: SensoryFeedback,
        hapticEnabled: Bool,
        reduceMotion: Bool
    ) -> SensoryFeedback? {
        guard hapticEnabled, !reduceMotion else { return nil }
        return feedback
    }
}

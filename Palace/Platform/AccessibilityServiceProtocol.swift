//
//  AccessibilityServiceProtocol.swift
//  Palace
//
//  Protocol for the app-specific accessibility service.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation
import UIKit

/// Protocol for the app-specific accessibility service.
protocol AccessibilityServiceProtocol: Sendable {
    /// Publisher for preference changes.
    var preferencesPublisher: AnyPublisher<AccessibilityPreferences, Never> { get }

    /// Publisher for Dynamic Type size changes.
    var contentSizeCategoryPublisher: AnyPublisher<UIContentSizeCategory, Never> { get }

    /// Get current preferences.
    func currentPreferences() async -> AccessibilityPreferences

    /// Update preferences.
    func updatePreferences(_ preferences: AccessibilityPreferences) async

    /// Make a VoiceOver announcement respecting verbosity settings.
    func announce(_ message: String, verbosity: AnnouncementVerbosity) async

    /// Trigger haptic feedback (respects reduced motion and haptic preferences).
    func triggerHaptic(_ type: HapticType) async

    /// Whether the effective reduced motion setting is on (system OR app preference).
    func isReducedMotionEffective() async -> Bool

    /// Whether the effective high contrast setting is on (system OR app preference).
    func isHighContrastEffective() async -> Bool
}

/// Types of haptic feedback available.
enum HapticType: Sendable {
    case selection
    case lightImpact
    case mediumImpact
    case heavyImpact
    case success
    case warning
    case error
}

//
//  AccessibilityPreferences.swift
//  Palace
//
//  User's app-specific accessibility preferences.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// Level of VoiceOver announcement verbosity.
enum AnnouncementVerbosity: String, Codable, CaseIterable, Sendable {
    case minimal
    case standard
    case verbose

    var displayName: String {
        switch self {
        case .minimal: return "Minimal"
        case .standard: return "Standard"
        case .verbose: return "Verbose"
        }
    }

    var description: String {
        switch self {
        case .minimal: return "Only essential announcements"
        case .standard: return "Standard level of detail"
        case .verbose: return "Full descriptions and context"
        }
    }
}

/// App-specific accessibility preferences that supplement system settings.
struct AccessibilityPreferences: Codable, Equatable, Sendable {
    /// Preferred announcement verbosity for VoiceOver.
    var verbosity: AnnouncementVerbosity = .standard

    /// Whether custom rotor actions are enabled for book navigation.
    var customRotorActionsEnabled: Bool = true

    /// App-specific reduced motion preference (supplements system setting).
    var reducedMotion: Bool = false

    /// App-specific high contrast boost (supplements system setting).
    var highContrastBoost: Bool = false

    /// Whether button shapes are shown (supplements system setting).
    var buttonShapesEnabled: Bool = false

    /// Whether haptic feedback is enabled.
    var hapticFeedbackEnabled: Bool = true

    // MARK: - Persistence Key

    static let storageKey = "Palace.Platform.accessibilityPreferences"

    // MARK: - Default

    static let `default` = AccessibilityPreferences()
}

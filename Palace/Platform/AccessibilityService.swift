//
//  AccessibilityService.swift
//  Palace
//
//  App-specific accessibility service implementation.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation
import UIKit

/// Actor-based accessibility service managing app-specific accessibility preferences.
actor AccessibilityService: AccessibilityServiceProtocol {

    // MARK: - Singleton

    static let shared = AccessibilityService()

    // MARK: - State

    private var preferences: AccessibilityPreferences
    private let userDefaults: UserDefaults

    // MARK: - Combine

    private nonisolated(unsafe) let preferencesSubject: CurrentValueSubject<AccessibilityPreferences, Never>
    private nonisolated(unsafe) let contentSizeSubject = PassthroughSubject<UIContentSizeCategory, Never>()
    private var cancellables = Set<AnyCancellable>()

    nonisolated var preferencesPublisher: AnyPublisher<AccessibilityPreferences, Never> {
        preferencesSubject.eraseToAnyPublisher()
    }

    nonisolated var contentSizeCategoryPublisher: AnyPublisher<UIContentSizeCategory, Never> {
        contentSizeSubject.eraseToAnyPublisher()
    }

    // MARK: - Haptics (created lazily on MainActor)

    // MARK: - Init

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        // Load saved preferences
        if let data = userDefaults.data(forKey: AccessibilityPreferences.storageKey),
           let saved = try? JSONDecoder().decode(AccessibilityPreferences.self, from: data) {
            self.preferences = saved
        } else {
            self.preferences = .default
        }

        self.preferencesSubject = CurrentValueSubject(preferences)

        // Monitor Dynamic Type changes
        NotificationCenter.default.publisher(for: UIContentSizeCategory.didChangeNotification)
            .compactMap { notification in
                notification.userInfo?[UIContentSizeCategory.newValueUserInfoKey] as? UIContentSizeCategory
            }
            .sink { [contentSizeSubject] category in
                contentSizeSubject.send(category)
            }
            .store(in: &cancellables)
    }

    // MARK: - Preferences

    func currentPreferences() async -> AccessibilityPreferences {
        preferences
    }

    func updatePreferences(_ newPreferences: AccessibilityPreferences) async {
        preferences = newPreferences
        persist()
        preferencesSubject.send(newPreferences)
    }

    // MARK: - Announcements

    func announce(_ message: String, verbosity: AnnouncementVerbosity) async {
        // Only announce if the message meets the verbosity threshold
        guard shouldAnnounce(at: verbosity) else { return }
        // VoiceOver announcements must be on main thread
        await MainActor.run {
            UIAccessibility.post(notification: .announcement, argument: message)
        }
    }

    private func shouldAnnounce(at verbosity: AnnouncementVerbosity) -> Bool {
        switch (preferences.verbosity, verbosity) {
        case (.verbose, _):
            return true
        case (.standard, .standard), (.standard, .minimal):
            return true
        case (.minimal, .minimal):
            return true
        default:
            return false
        }
    }

    // MARK: - Haptics

    func triggerHaptic(_ type: HapticType) async {
        guard preferences.hapticFeedbackEnabled else { return }

        // Respect reduced motion
        if await isReducedMotionEffective() { return }

        await MainActor.run {
            switch type {
            case .selection:
                UISelectionFeedbackGenerator().selectionChanged()
            case .lightImpact:
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            case .mediumImpact:
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            case .heavyImpact:
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            case .success:
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            case .warning:
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            case .error:
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    // MARK: - Effective Settings

    func isReducedMotionEffective() async -> Bool {
        let systemSetting = await MainActor.run { UIAccessibility.isReduceMotionEnabled }
        return systemSetting || preferences.reducedMotion
    }

    func isHighContrastEffective() async -> Bool {
        let systemSetting = await MainActor.run { UIAccessibility.isDarkerSystemColorsEnabled }
        return systemSetting || preferences.highContrastBoost
    }

    // MARK: - Persistence

    private func persist() {
        if let data = try? JSONEncoder().encode(preferences) {
            userDefaults.set(data, forKey: AccessibilityPreferences.storageKey)
        }
    }
}

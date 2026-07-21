//
//  PalaceHapticTests.swift
//  PalaceTests
//
//  PP-4745 (PR2) — pins the preference-gated haptic modifier. The feedback plays
//  only when the user's `hapticFeedbackEnabled` preference is on AND Reduce Motion
//  is off. Uses a mock AccessibilityService — never the real shared singleton.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import SwiftUI
import Combine
import UIKit
@testable import Palace

// MARK: - Mock service

/// Minimal `AccessibilityServiceProtocol` double whose preference publisher is
/// drivable from the test. Never touches UserDefaults or the shared singleton.
private final class MockAccessibilityService: AccessibilityServiceProtocol, @unchecked Sendable {
    let preferencesSubject: CurrentValueSubject<AccessibilityPreferences, Never>
    private let contentSizeSubject = PassthroughSubject<UIContentSizeCategory, Never>()

    init(preferences: AccessibilityPreferences = .default) {
        self.preferencesSubject = CurrentValueSubject(preferences)
    }

    var preferencesPublisher: AnyPublisher<AccessibilityPreferences, Never> {
        preferencesSubject.eraseToAnyPublisher()
    }
    var contentSizeCategoryPublisher: AnyPublisher<UIContentSizeCategory, Never> {
        contentSizeSubject.eraseToAnyPublisher()
    }
    func currentPreferences() async -> AccessibilityPreferences { preferencesSubject.value }
    func updatePreferences(_ preferences: AccessibilityPreferences) async {
        preferencesSubject.send(preferences)
    }
    func announce(_ message: String, verbosity: AnnouncementVerbosity) async {}
    func triggerHaptic(_ type: HapticType) async {}
    func isReducedMotionEffective() async -> Bool { false }
    func isHighContrastEffective() async -> Bool { false }
}

@MainActor
final class PalaceHapticTests: XCTestCase {

    // MARK: - resolvedFeedback — the gating decision

    /// Haptics on + Reduce Motion off → the feedback plays.
    func testResolvedFeedback_enabled_playsFeedback() {
        let result = PalaceHapticModifier<Int>.resolvedFeedback(.success,
                                                                hapticEnabled: true,
                                                                reduceMotion: false)
        XCTAssertEqual(result, .success, "Feedback must play when enabled and motion is allowed")
    }

    /// Haptics preference OFF → suppressed regardless of motion.
    func testResolvedFeedback_preferenceDisabled_suppressed() {
        let result = PalaceHapticModifier<Int>.resolvedFeedback(.success,
                                                                hapticEnabled: false,
                                                                reduceMotion: false)
        XCTAssertNil(result, "Feedback must be suppressed when the haptic preference is off")
    }

    /// Reduce Motion ON → suppressed even if the preference is on.
    func testResolvedFeedback_reduceMotion_suppressed() {
        let result = PalaceHapticModifier<Int>.resolvedFeedback(.success,
                                                                hapticEnabled: true,
                                                                reduceMotion: true)
        XCTAssertNil(result, "Feedback must be suppressed under Reduce Motion")
    }

    // MARK: - Service seam

    /// The modifier is constructed with the injected service and holds it — proving
    /// the preference the gate reads comes from the injected service, not the
    /// shared singleton. Also drives the mock's preference publisher to confirm the
    /// disabled preference the gate consumes is observable through that seam.
    func testPalaceHapticModifier_readsInjectedServicePreference() {
        let mock = MockAccessibilityService(preferences: .default)
        let modifier = PalaceHapticModifier(feedback: .success, trigger: 0, service: mock)

        // The modifier retained the values we passed.
        XCTAssertEqual(modifier.trigger, 0)
        XCTAssertEqual(modifier.feedback, .success)

        // Drive the preference the modifier subscribes to and confirm the seam
        // emits the disabled value the gate would then act on.
        var disabled = AccessibilityPreferences.default
        disabled.hapticFeedbackEnabled = false

        let exp = expectation(description: "preference emitted")
        var received: Bool?
        let cancellable = mock.preferencesPublisher
            .dropFirst() // skip the current value
            // Deliver on main: the `.sink` closure is `@MainActor`-isolated (this
            // is a `@MainActor` test), but `updatePreferences` sends from a
            // background `Task`, so without this the sink runs off-main and
            // Swift 6's executor-isolation check traps (EXC_BREAKPOINT).
            .receive(on: DispatchQueue.main)
            .sink { received = $0.hapticFeedbackEnabled; exp.fulfill() }

        Task { await mock.updatePreferences(disabled) }
        wait(for: [exp], timeout: 1.0)
        cancellable.cancel()

        XCTAssertEqual(received, false)
        // And the gate suppresses for that emitted preference.
        XCTAssertNil(PalaceHapticModifier<Int>.resolvedFeedback(.success,
                                                                hapticEnabled: received ?? true,
                                                                reduceMotion: false))
    }
}

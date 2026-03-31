//
//  AccessibilityServiceTests.swift
//  PalaceTests
//
//  Tests for the accessibility service.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import XCTest
@testable import Palace

final class AccessibilityServiceTests: XCTestCase {

    private var service: AccessibilityService!
    private var userDefaults: UserDefaults!
    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        userDefaults = UserDefaults(suiteName: "AccessibilityServiceTests")!
        userDefaults.removePersistentDomain(forName: "AccessibilityServiceTests")
        service = AccessibilityService(userDefaults: userDefaults)
        cancellables = Set<AnyCancellable>()
    }

    override func tearDown() {
        cancellables = nil
        userDefaults.removePersistentDomain(forName: "AccessibilityServiceTests")
        service = nil
        userDefaults = nil
        super.tearDown()
    }

    // MARK: - Default Preferences

    func testDefaultPreferences() async {
        let prefs = await service.currentPreferences()
        XCTAssertEqual(prefs.verbosity, .standard)
        XCTAssertTrue(prefs.customRotorActionsEnabled)
        XCTAssertFalse(prefs.reducedMotion)
        XCTAssertFalse(prefs.highContrastBoost)
        XCTAssertFalse(prefs.buttonShapesEnabled)
        XCTAssertTrue(prefs.hapticFeedbackEnabled)
    }

    // MARK: - Update Preferences

    func testUpdatePreferences() async {
        var prefs = AccessibilityPreferences.default
        prefs.verbosity = .verbose
        prefs.reducedMotion = true
        prefs.highContrastBoost = true

        await service.updatePreferences(prefs)

        let saved = await service.currentPreferences()
        XCTAssertEqual(saved.verbosity, .verbose)
        XCTAssertTrue(saved.reducedMotion)
        XCTAssertTrue(saved.highContrastBoost)
    }

    // MARK: - Persistence

    func testPreferencesPersistAcrossInstances() async {
        var prefs = AccessibilityPreferences.default
        prefs.verbosity = .minimal
        prefs.hapticFeedbackEnabled = false

        await service.updatePreferences(prefs)

        // Create new instance with same UserDefaults
        let newService = AccessibilityService(userDefaults: userDefaults)
        let loaded = await newService.currentPreferences()

        XCTAssertEqual(loaded.verbosity, .minimal)
        XCTAssertFalse(loaded.hapticFeedbackEnabled)
    }

    // MARK: - Preferences Publisher

    func testPreferencesPublisher() async {
        let expectation = XCTestExpectation(description: "Preferences published")
        var receivedPrefs: AccessibilityPreferences?

        service.preferencesPublisher
            .dropFirst() // Drop the initial value
            .sink { prefs in
                receivedPrefs = prefs
                expectation.fulfill()
            }
            .store(in: &cancellables)

        var prefs = AccessibilityPreferences.default
        prefs.verbosity = .verbose
        await service.updatePreferences(prefs)

        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(receivedPrefs?.verbosity, .verbose)
    }

    // MARK: - Verbosity Levels

    func testVerbosityDisplayNames() {
        XCTAssertEqual(AnnouncementVerbosity.minimal.displayName, "Minimal")
        XCTAssertEqual(AnnouncementVerbosity.standard.displayName, "Standard")
        XCTAssertEqual(AnnouncementVerbosity.verbose.displayName, "Verbose")
    }

    func testVerbosityDescriptions() {
        XCTAssertFalse(AnnouncementVerbosity.minimal.description.isEmpty)
        XCTAssertFalse(AnnouncementVerbosity.standard.description.isEmpty)
        XCTAssertFalse(AnnouncementVerbosity.verbose.description.isEmpty)
    }

    // MARK: - Effective Settings

    func testReducedMotionEffective() async {
        // When app preference is on, should be effective regardless of system
        var prefs = AccessibilityPreferences.default
        prefs.reducedMotion = true
        await service.updatePreferences(prefs)

        let isEffective = await service.isReducedMotionEffective()
        XCTAssertTrue(isEffective)
    }

    func testHighContrastEffective() async {
        var prefs = AccessibilityPreferences.default
        prefs.highContrastBoost = true
        await service.updatePreferences(prefs)

        let isEffective = await service.isHighContrastEffective()
        XCTAssertTrue(isEffective)
    }

    // MARK: - Haptic Gating

    func testHapticDisabledWhenPreferenceOff() async {
        var prefs = AccessibilityPreferences.default
        prefs.hapticFeedbackEnabled = false
        await service.updatePreferences(prefs)

        // This should not crash — haptic is gated
        await service.triggerHaptic(.selection)
    }

    func testHapticDisabledWithReducedMotion() async {
        var prefs = AccessibilityPreferences.default
        prefs.reducedMotion = true
        prefs.hapticFeedbackEnabled = true
        await service.updatePreferences(prefs)

        // This should not crash — haptic is gated by reduced motion
        await service.triggerHaptic(.mediumImpact)
    }

    // MARK: - Codable

    func testAccessibilityPreferencesCodable() throws {
        var prefs = AccessibilityPreferences.default
        prefs.verbosity = .verbose
        prefs.reducedMotion = true
        prefs.highContrastBoost = true
        prefs.buttonShapesEnabled = true
        prefs.hapticFeedbackEnabled = false
        prefs.customRotorActionsEnabled = false

        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(AccessibilityPreferences.self, from: data)

        XCTAssertEqual(decoded, prefs)
    }
}

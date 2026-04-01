//
//  AccessibilityPreferencesTests.swift
//  PalaceTests
//
//  Tests for AccessibilityPreferences defaults, Codable, and persistence.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class AccessibilityPreferencesTests: XCTestCase {

    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: "AccessibilityPreferencesTests")!
        testDefaults.removePersistentDomain(forName: "AccessibilityPreferencesTests")
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: "AccessibilityPreferencesTests")
        testDefaults = nil
        super.tearDown()
    }

    // MARK: - Default Initialization

    func testDefaultPreferences_HasStandardVerbosity() {
        let prefs = AccessibilityPreferences.default
        XCTAssertEqual(prefs.verbosity, .standard)
    }

    func testDefaultPreferences_CustomRotorEnabled() {
        let prefs = AccessibilityPreferences.default
        XCTAssertTrue(prefs.customRotorActionsEnabled)
    }

    func testDefaultPreferences_ReducedMotionOff() {
        let prefs = AccessibilityPreferences.default
        XCTAssertFalse(prefs.reducedMotion)
    }

    func testDefaultPreferences_HighContrastOff() {
        let prefs = AccessibilityPreferences.default
        XCTAssertFalse(prefs.highContrastBoost)
    }

    func testDefaultPreferences_ButtonShapesOff() {
        let prefs = AccessibilityPreferences.default
        XCTAssertFalse(prefs.buttonShapesEnabled)
    }

    func testDefaultPreferences_HapticFeedbackOn() {
        let prefs = AccessibilityPreferences.default
        XCTAssertTrue(prefs.hapticFeedbackEnabled)
    }

    // MARK: - Codable Round-Trip

    func testCodableRoundTrip_DefaultPreferences() throws {
        let original = AccessibilityPreferences.default
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AccessibilityPreferences.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testCodableRoundTrip_CustomPreferences() throws {
        var original = AccessibilityPreferences()
        original.verbosity = .verbose
        original.customRotorActionsEnabled = false
        original.reducedMotion = true
        original.highContrastBoost = true
        original.buttonShapesEnabled = true
        original.hapticFeedbackEnabled = false

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AccessibilityPreferences.self, from: data)

        XCTAssertEqual(decoded.verbosity, .verbose)
        XCTAssertFalse(decoded.customRotorActionsEnabled)
        XCTAssertTrue(decoded.reducedMotion)
        XCTAssertTrue(decoded.highContrastBoost)
        XCTAssertTrue(decoded.buttonShapesEnabled)
        XCTAssertFalse(decoded.hapticFeedbackEnabled)
    }

    // MARK: - All Verbosity Levels

    func testVerbosityMinimal_DisplayName() {
        XCTAssertEqual(AnnouncementVerbosity.minimal.displayName, "Minimal")
    }

    func testVerbosityStandard_DisplayName() {
        XCTAssertEqual(AnnouncementVerbosity.standard.displayName, "Standard")
    }

    func testVerbosityVerbose_DisplayName() {
        XCTAssertEqual(AnnouncementVerbosity.verbose.displayName, "Verbose")
    }

    func testVerbosityMinimal_Description() {
        XCTAssertEqual(AnnouncementVerbosity.minimal.description, "Only essential announcements")
    }

    func testVerbosityStandard_Description() {
        XCTAssertEqual(AnnouncementVerbosity.standard.description, "Standard level of detail")
    }

    func testVerbosityVerbose_Description() {
        XCTAssertEqual(AnnouncementVerbosity.verbose.description, "Full descriptions and context")
    }

    func testVerbosity_AllCases() {
        XCTAssertEqual(AnnouncementVerbosity.allCases.count, 3)
    }

    func testVerbosity_CodableRoundTrip() throws {
        for verbosity in AnnouncementVerbosity.allCases {
            let data = try JSONEncoder().encode(verbosity)
            let decoded = try JSONDecoder().decode(AnnouncementVerbosity.self, from: data)
            XCTAssertEqual(decoded, verbosity)
        }
    }

    // MARK: - Boolean Preference Toggles

    func testReducedMotion_Toggle() {
        var prefs = AccessibilityPreferences()
        XCTAssertFalse(prefs.reducedMotion)
        prefs.reducedMotion = true
        XCTAssertTrue(prefs.reducedMotion)
        prefs.reducedMotion = false
        XCTAssertFalse(prefs.reducedMotion)
    }

    func testHighContrastBoost_Toggle() {
        var prefs = AccessibilityPreferences()
        XCTAssertFalse(prefs.highContrastBoost)
        prefs.highContrastBoost = true
        XCTAssertTrue(prefs.highContrastBoost)
    }

    func testButtonShapesEnabled_Toggle() {
        var prefs = AccessibilityPreferences()
        XCTAssertFalse(prefs.buttonShapesEnabled)
        prefs.buttonShapesEnabled = true
        XCTAssertTrue(prefs.buttonShapesEnabled)
    }

    func testHapticFeedbackEnabled_Toggle() {
        var prefs = AccessibilityPreferences()
        XCTAssertTrue(prefs.hapticFeedbackEnabled)
        prefs.hapticFeedbackEnabled = false
        XCTAssertFalse(prefs.hapticFeedbackEnabled)
    }

    func testCustomRotorActionsEnabled_Toggle() {
        var prefs = AccessibilityPreferences()
        XCTAssertTrue(prefs.customRotorActionsEnabled)
        prefs.customRotorActionsEnabled = false
        XCTAssertFalse(prefs.customRotorActionsEnabled)
    }

    // MARK: - Persistence to UserDefaults

    func testPersistence_SaveAndLoad() throws {
        var prefs = AccessibilityPreferences()
        prefs.verbosity = .verbose
        prefs.reducedMotion = true
        prefs.hapticFeedbackEnabled = false

        let data = try JSONEncoder().encode(prefs)
        testDefaults.set(data, forKey: AccessibilityPreferences.storageKey)

        let loadedData = testDefaults.data(forKey: AccessibilityPreferences.storageKey)
        XCTAssertNotNil(loadedData)

        let loaded = try JSONDecoder().decode(AccessibilityPreferences.self, from: loadedData!)
        XCTAssertEqual(loaded.verbosity, .verbose)
        XCTAssertTrue(loaded.reducedMotion)
        XCTAssertFalse(loaded.hapticFeedbackEnabled)
    }

    func testPersistence_NoSavedData_ReturnsNil() {
        let data = testDefaults.data(forKey: AccessibilityPreferences.storageKey)
        XCTAssertNil(data)
    }

    func testStorageKey_IsCorrect() {
        XCTAssertEqual(AccessibilityPreferences.storageKey, "Palace.Platform.accessibilityPreferences")
    }

    // MARK: - Equatable

    func testEquatable_SameValues() {
        let a = AccessibilityPreferences.default
        let b = AccessibilityPreferences.default
        XCTAssertEqual(a, b)
    }

    func testEquatable_DifferentValues() {
        var a = AccessibilityPreferences()
        var b = AccessibilityPreferences()
        a.verbosity = .minimal
        b.verbosity = .verbose
        XCTAssertNotEqual(a, b)
    }
}

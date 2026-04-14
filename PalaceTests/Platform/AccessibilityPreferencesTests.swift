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

    func testReducedMotion_WhenEnabled_RoundTripsThroughCodable() throws {
        // Arrange: start with default (reducedMotion = false)
        var prefs = AccessibilityPreferences()
        XCTAssertFalse(prefs.reducedMotion, "Precondition: reducedMotion defaults to false")

        // Act: enable reducedMotion and encode/decode
        prefs.reducedMotion = true
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(AccessibilityPreferences.self, from: data)

        // Assert: the mutation survives a codable round-trip
        XCTAssertTrue(decoded.reducedMotion,
                      "reducedMotion=true must survive a JSON encode/decode round-trip")
        XCTAssertNotEqual(decoded, AccessibilityPreferences.default,
                          "Prefs with reducedMotion=true must differ from the default")
    }

    func testHighContrastBoost_WhenEnabled_MakesPrefsUnequalToDefault() throws {
        // Arrange: start with defaults
        var prefs = AccessibilityPreferences()
        XCTAssertFalse(prefs.highContrastBoost, "Precondition: highContrastBoost defaults to false")

        // Act: enable highContrastBoost and encode/decode
        prefs.highContrastBoost = true
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(AccessibilityPreferences.self, from: data)

        // Assert: the flag survived the round-trip and breaks equality with default
        XCTAssertTrue(decoded.highContrastBoost,
                      "highContrastBoost=true must survive JSON encode/decode")
        XCTAssertNotEqual(decoded, AccessibilityPreferences.default,
                          "High-contrast prefs must not be equal to defaults")
    }

    func testButtonShapesEnabled_WhenEnabled_RoundTripsThroughCodable() throws {
        // Arrange: start with defaults
        var prefs = AccessibilityPreferences()
        XCTAssertFalse(prefs.buttonShapesEnabled, "Precondition: buttonShapesEnabled defaults to false")

        // Act: enable button shapes and verify round-trip
        prefs.buttonShapesEnabled = true
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(AccessibilityPreferences.self, from: data)

        // Assert: flag survived and differs from default
        XCTAssertTrue(decoded.buttonShapesEnabled,
                      "buttonShapesEnabled=true must survive JSON encode/decode")
        XCTAssertNotEqual(decoded, AccessibilityPreferences.default,
                          "Prefs with button shapes enabled must not be equal to defaults")
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

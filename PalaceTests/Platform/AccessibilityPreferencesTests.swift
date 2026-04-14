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
        XCTAssertNotEqual(prefs.verbosity, .minimal, "Standard verbosity must not be minimal")
        XCTAssertNotEqual(prefs.verbosity, .verbose, "Standard verbosity must not be verbose")
    }

    func testDefaultPreferences_CustomRotorEnabled() {
        let prefs = AccessibilityPreferences.default
        XCTAssertTrue(prefs.customRotorActionsEnabled)
        // Defaults must equal themselves
        XCTAssertEqual(prefs, AccessibilityPreferences.default,
                       "default must be equal to a freshly constructed default")
    }

    func testDefaultPreferences_ReducedMotionOff() {
        let prefs = AccessibilityPreferences.default
        XCTAssertFalse(prefs.reducedMotion)
        // Changing reducedMotion must produce inequality with default
        var modified = prefs
        modified.reducedMotion = true
        XCTAssertNotEqual(modified, prefs, "Enabling reducedMotion must break equality with the default")
    }

    func testDefaultPreferences_HighContrastOff() {
        let prefs = AccessibilityPreferences.default
        XCTAssertFalse(prefs.highContrastBoost)
        // Toggling must break equality
        var modified = prefs
        modified.highContrastBoost = true
        XCTAssertNotEqual(modified, prefs, "Enabling highContrastBoost must break equality with the default")
    }

    func testDefaultPreferences_ButtonShapesOff() {
        let prefs = AccessibilityPreferences.default
        XCTAssertFalse(prefs.buttonShapesEnabled)
        var modified = prefs
        modified.buttonShapesEnabled = true
        XCTAssertNotEqual(modified, prefs, "Enabling buttonShapes must break equality with the default")
    }

    func testDefaultPreferences_HapticFeedbackOn() {
        let prefs = AccessibilityPreferences.default
        XCTAssertTrue(prefs.hapticFeedbackEnabled)
        // Disabling haptic must break equality with default
        var modified = prefs
        modified.hapticFeedbackEnabled = false
        XCTAssertNotEqual(modified, prefs, "Disabling hapticFeedback must break equality with the default")
    }

    // MARK: - Codable Round-Trip

    func testCodableRoundTrip_DefaultPreferences() throws {
        let original = AccessibilityPreferences.default
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AccessibilityPreferences.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.verbosity, original.verbosity,
                       "Verbosity must survive Codable round-trip for default preferences")
        XCTAssertEqual(decoded.hapticFeedbackEnabled, original.hapticFeedbackEnabled,
                       "hapticFeedbackEnabled must survive Codable round-trip for default preferences")
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
        XCTAssertFalse(AnnouncementVerbosity.minimal.displayName.isEmpty, "Minimal displayName must not be empty")
    }

    func testVerbosityStandard_DisplayName() {
        XCTAssertEqual(AnnouncementVerbosity.standard.displayName, "Standard")
        XCTAssertNotEqual(AnnouncementVerbosity.standard.displayName, AnnouncementVerbosity.minimal.displayName,
                          "Standard and minimal display names must differ")
    }

    func testVerbosityVerbose_DisplayName() {
        XCTAssertEqual(AnnouncementVerbosity.verbose.displayName, "Verbose")
        XCTAssertNotEqual(AnnouncementVerbosity.verbose.displayName, AnnouncementVerbosity.standard.displayName,
                          "Verbose and standard display names must differ")
    }

    func testVerbosityMinimal_Description() {
        XCTAssertEqual(AnnouncementVerbosity.minimal.description, "Only essential announcements")
        XCTAssertNotEqual(AnnouncementVerbosity.minimal.description, AnnouncementVerbosity.standard.description,
                          "Minimal and standard descriptions must differ")
    }

    func testVerbosityStandard_Description() {
        XCTAssertEqual(AnnouncementVerbosity.standard.description, "Standard level of detail")
        XCTAssertNotEqual(AnnouncementVerbosity.standard.description, AnnouncementVerbosity.verbose.description,
                          "Standard and verbose descriptions must differ")
    }

    func testVerbosityVerbose_Description() {
        XCTAssertEqual(AnnouncementVerbosity.verbose.description, "Full descriptions and context")
        XCTAssertNotEqual(AnnouncementVerbosity.verbose.description, AnnouncementVerbosity.minimal.description,
                          "Verbose and minimal descriptions must differ")
    }

    func testVerbosity_AllCases() {
        XCTAssertEqual(AnnouncementVerbosity.allCases.count, 3)
        // All display names must be unique
        let names = AnnouncementVerbosity.allCases.map(\.displayName)
        XCTAssertEqual(Set(names).count, 3, "All verbosity level display names must be unique")
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

    func testHapticFeedbackEnabled_Toggle() throws {
        // Precondition: default is true
        XCTAssertTrue(AccessibilityPreferences.default.hapticFeedbackEnabled,
                      "hapticFeedbackEnabled must default to true")
        // Mutation must survive a Codable round-trip (proves the property is actually persisted)
        var prefs = AccessibilityPreferences()
        prefs.hapticFeedbackEnabled = false
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(AccessibilityPreferences.self, from: data)
        XCTAssertFalse(decoded.hapticFeedbackEnabled,
                       "hapticFeedbackEnabled=false must survive a JSON encode/decode round-trip")
        XCTAssertNotEqual(decoded, AccessibilityPreferences.default,
                          "Prefs with hapticFeedbackEnabled=false must differ from defaults")
    }

    func testCustomRotorActionsEnabled_Toggle() throws {
        // Precondition: default is true
        XCTAssertTrue(AccessibilityPreferences.default.customRotorActionsEnabled,
                      "customRotorActionsEnabled must default to true")
        // Mutation must survive a Codable round-trip (proves the property is actually persisted)
        var prefs = AccessibilityPreferences()
        prefs.customRotorActionsEnabled = false
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(AccessibilityPreferences.self, from: data)
        XCTAssertFalse(decoded.customRotorActionsEnabled,
                       "customRotorActionsEnabled=false must survive a JSON encode/decode round-trip")
        XCTAssertNotEqual(decoded, AccessibilityPreferences.default,
                          "Prefs with customRotorActionsEnabled=false must differ from defaults")
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
        // Writing then removing must also yield nil
        testDefaults.set(Data(), forKey: AccessibilityPreferences.storageKey)
        testDefaults.removeObject(forKey: AccessibilityPreferences.storageKey)
        let afterRemoval = testDefaults.data(forKey: AccessibilityPreferences.storageKey)
        XCTAssertNil(afterRemoval, "Data must be nil after explicit removal from UserDefaults")
    }

    func testStorageKey_IsCorrect() {
        XCTAssertEqual(AccessibilityPreferences.storageKey, "Palace.Platform.accessibilityPreferences")
        XCTAssertTrue(AccessibilityPreferences.storageKey.contains("Palace"),
                      "Storage key must include the app namespace 'Palace'")
        XCTAssertFalse(AccessibilityPreferences.storageKey.isEmpty, "Storage key must not be empty")
    }

    // MARK: - Equatable

    func testEquatable_SameValues() {
        let a = AccessibilityPreferences.default
        let b = AccessibilityPreferences.default
        XCTAssertEqual(a, b)
        // Equality must be reflexive: a == a
        XCTAssertEqual(a, a, "Equatable must be reflexive: a preference object must equal itself")
        // Equality must be symmetric: a == b ↔ b == a
        XCTAssertEqual(b, a, "Equatable must be symmetric: if a==b then b==a must also hold")
    }

    func testEquatable_DifferentValues() {
        var a = AccessibilityPreferences()
        var b = AccessibilityPreferences()
        a.verbosity = .minimal
        b.verbosity = .verbose
        XCTAssertNotEqual(a, b)
    }
}

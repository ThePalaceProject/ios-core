//
//  TPPReaderSettingsTests.swift
//  PalaceTests
//
//  Tests for reader settings functionality
//

import XCTest
import SwiftUI
import ReadiumNavigator
@testable import Palace

@MainActor
final class TPPReaderSettingsTests: XCTestCase {

    // MARK: - Initialization Tests

    func testInit_setsDefaultFontSize() {
        let settings = TPPReaderSettings()
        XCTAssertEqual(settings.fontSize, 1.0)
        XCTAssertTrue(settings.canIncreaseFontSize, "Default font size should allow increasing")
        XCTAssertFalse(settings.canDecreaseFontSize, "Default font size should be at minimum")
    }

    func testInit_setsDefaultFontFamilyIndex() {
        let settings = TPPReaderSettings()
        XCTAssertEqual(settings.fontFamilyIndex, 0)
        XCTAssertEqual(settings.fontFamilyIndex, TPPReaderFont.original.propertyIndex,
                       "Default font family index must match the original font's property index")
    }

    func testInit_setsDefaultAppearanceIndex() {
        let settings = TPPReaderSettings()
        XCTAssertEqual(settings.appearanceIndex, 0)
        XCTAssertEqual(settings.appearanceIndex, TPPReaderAppearance.blackOnWhite.propertyIndex,
                       "Default appearance index must correspond to blackOnWhite appearance")
    }

    func testInit_getsScreenBrightness() {
        let settings = TPPReaderSettings()
        XCTAssertGreaterThanOrEqual(settings.screenBrightness, 0.0)
        XCTAssertLessThanOrEqual(settings.screenBrightness, 1.0)
    }

    // MARK: - Font Size Tests

    func testIncreaseFontSize_increasesByStep() {
        let settings = TPPReaderSettings()
        let initialSize = settings.fontSize

        settings.increaseFontSize()

        XCTAssertGreaterThan(settings.fontSize, initialSize)
        XCTAssertFalse(settings.canDecreaseFontSize == false && settings.fontSize == initialSize,
                       "After increase, font size must differ from initial")
        XCTAssertGreaterThan(settings.fontSize, 1.0, "Font size after increase must exceed the minimum of 1.0")
    }

    func testDecreaseFontSize_decreasesByStep() {
        let settings = TPPReaderSettings()
        settings.fontSize = 2.0
        let initialSize = settings.fontSize

        settings.decreaseFontSize()

        XCTAssertLessThan(settings.fontSize, initialSize)
    }

    func testIncreaseFontSize_respectsMaximum() {
        let settings = TPPReaderSettings()

        // Increase many times to hit max
        for _ in 0..<20 {
            settings.increaseFontSize()
        }

        let maxSize = settings.fontSize
        settings.increaseFontSize()

        XCTAssertEqual(settings.fontSize, maxSize)
    }

    func testDecreaseFontSize_respectsMinimum() {
        let settings = TPPReaderSettings()

        // Decrease many times to hit min
        for _ in 0..<20 {
            settings.decreaseFontSize()
        }

        let minSize = settings.fontSize
        settings.decreaseFontSize()

        XCTAssertEqual(settings.fontSize, minSize)
    }

    func testCanIncreaseFontSize_trueWhenBelowMax() {
        let settings = TPPReaderSettings()
        settings.fontSize = 1.0

        XCTAssertTrue(settings.canIncreaseFontSize)
        settings.increaseFontSize()
        XCTAssertGreaterThan(settings.fontSize, 1.0, "Increasing from minimum must produce a larger value")
    }

    func testCanDecreaseFontSize_falseAtMinimum() {
        let settings = TPPReaderSettings()
        settings.fontSize = 1.0

        XCTAssertFalse(settings.canDecreaseFontSize)
        let sizeBefore = settings.fontSize
        settings.decreaseFontSize()
        XCTAssertEqual(settings.fontSize, sizeBefore, "Decreasing at minimum must leave font size unchanged")
    }

    // MARK: - Appearance Tests

    func testChangeAppearance_updatesIndex() {
        let settings = TPPReaderSettings()

        settings.changeAppearance(appearanceIndex: 1)

        XCTAssertEqual(settings.appearanceIndex, 1)
        XCTAssertNotNil(settings.backgroundColor, "backgroundColor must be set after appearance change")
        XCTAssertNotNil(settings.textColor, "textColor must be set after appearance change")
    }

    func testChangeAppearance_updatesColors() {
        let settings = TPPReaderSettings()
        let initialBackground = settings.backgroundColor

        settings.changeAppearance(appearanceIndex: 1) // Sepia or Dark

        // Colors should change and remain valid
        XCTAssertNotNil(settings.backgroundColor)
        XCTAssertNotEqual(settings.backgroundColor, initialBackground,
                          "Background color should change when appearance index changes")
        XCTAssertNotNil(settings.textColor, "Text color must be set for the new appearance")
    }

    // MARK: - Font Family Tests

    func testChangeFontFamily_updatesIndex() {
        let settings = TPPReaderSettings()

        settings.changeFontFamily(fontFamilyIndex: 1)

        XCTAssertEqual(settings.fontFamilyIndex, 1)
        XCTAssertNotEqual(settings.fontFamilyIndex, 0, "Font family index must change away from default after update")
        settings.changeFontFamily(fontFamilyIndex: 0)
        XCTAssertEqual(settings.fontFamilyIndex, 0, "Resetting to index 0 must restore original font")
    }

    // MARK: - Mapping Helper Tests

    func testMapFontFamilyToIndex_sansSerif() {
        let index = TPPReaderSettings.mapFontFamilyToIndex(.sansSerif)
        XCTAssertEqual(index, TPPReaderFont.sansSerif.propertyIndex)
        // Round-trip: mapping the index back must recover .sansSerif
        XCTAssertEqual(TPPReaderSettings.mapIndexToFontFamily(index), .sansSerif,
                       "mapIndexToFontFamily must be the inverse of mapFontFamilyToIndex for sansSerif")
    }

    func testMapFontFamilyToIndex_serif() {
        let index = TPPReaderSettings.mapFontFamilyToIndex(.serif)
        XCTAssertEqual(index, TPPReaderFont.serif.propertyIndex)
        // Round-trip: mapping the index back must recover .serif
        XCTAssertEqual(TPPReaderSettings.mapIndexToFontFamily(index), .serif,
                       "mapIndexToFontFamily must be the inverse of mapFontFamilyToIndex for serif")
    }

    func testMapFontFamilyToIndex_openDyslexic() {
        let index = TPPReaderSettings.mapFontFamilyToIndex(.openDyslexic)
        XCTAssertEqual(index, TPPReaderFont.dyslexic.propertyIndex)
        // Round-trip: mapping the index back must recover .openDyslexic
        XCTAssertEqual(TPPReaderSettings.mapIndexToFontFamily(index), .openDyslexic,
                       "mapIndexToFontFamily must be the inverse of mapFontFamilyToIndex for openDyslexic")
    }

    func testMapFontFamilyToIndex_nil() {
        let index = TPPReaderSettings.mapFontFamilyToIndex(nil)
        XCTAssertEqual(index, TPPReaderFont.original.propertyIndex)
        // nil input should map to original (0) and the reverse mapping returns nil
        XCTAssertNil(TPPReaderSettings.mapIndexToFontFamily(index),
                     "Mapping the original index back must return nil (no custom font)")
    }

    func testMapAppearanceToIndex_dark() {
        let index = TPPReaderSettings.mapAppearanceToIndex(.dark)
        XCTAssertEqual(index, TPPReaderAppearance.whiteOnBlack.propertyIndex)
        // Round-trip: index must map back to .dark
        XCTAssertEqual(TPPReaderSettings.mapIndexToAppearance(index), .dark,
                       "mapIndexToAppearance must invert mapAppearanceToIndex for dark")
    }

    func testMapAppearanceToIndex_sepia() {
        let index = TPPReaderSettings.mapAppearanceToIndex(.sepia)
        XCTAssertEqual(index, TPPReaderAppearance.blackOnSepia.propertyIndex)
        // Round-trip: index must map back to .sepia
        XCTAssertEqual(TPPReaderSettings.mapIndexToAppearance(index), .sepia,
                       "mapIndexToAppearance must invert mapAppearanceToIndex for sepia")
    }

    func testMapAppearanceToIndex_light() {
        let index = TPPReaderSettings.mapAppearanceToIndex(.light)
        XCTAssertEqual(index, TPPReaderAppearance.blackOnWhite.propertyIndex)
        // Round-trip: index must map back to .light
        XCTAssertEqual(TPPReaderSettings.mapIndexToAppearance(index), .light,
                       "mapIndexToAppearance must invert mapAppearanceToIndex for light")
    }

    func testMapIndexToAppearance_dark() {
        let theme = TPPReaderSettings.mapIndexToAppearance(TPPReaderAppearance.whiteOnBlack.propertyIndex)
        XCTAssertEqual(theme, .dark)
        // The dark index must differ from sepia and light
        XCTAssertNotEqual(TPPReaderAppearance.whiteOnBlack.propertyIndex, TPPReaderAppearance.blackOnSepia.propertyIndex)
        XCTAssertNotEqual(TPPReaderAppearance.whiteOnBlack.propertyIndex, TPPReaderAppearance.blackOnWhite.propertyIndex)
    }

    func testMapIndexToAppearance_sepia() {
        let theme = TPPReaderSettings.mapIndexToAppearance(TPPReaderAppearance.blackOnSepia.propertyIndex)
        XCTAssertEqual(theme, .sepia)
        // sepia index must differ from dark and light
        XCTAssertNotEqual(TPPReaderAppearance.blackOnSepia.propertyIndex, TPPReaderAppearance.whiteOnBlack.propertyIndex)
        XCTAssertNotEqual(TPPReaderAppearance.blackOnSepia.propertyIndex, TPPReaderAppearance.blackOnWhite.propertyIndex)
    }

    func testMapIndexToAppearance_default() {
        let theme = TPPReaderSettings.mapIndexToAppearance(TPPReaderAppearance.blackOnWhite.propertyIndex)
        XCTAssertEqual(theme, .light)
        // Out-of-range indices should also return .light (fallback)
        let fallbackTheme = TPPReaderSettings.mapIndexToAppearance(99)
        XCTAssertEqual(fallbackTheme, .light, "Out-of-range index must fall back to .light")
    }

    func testMapIndexToFontFamily_sansSerif() {
        let family = TPPReaderSettings.mapIndexToFontFamily(TPPReaderFont.sansSerif.propertyIndex)
        XCTAssertEqual(family, .sansSerif)
        // sansSerif index must differ from serif and dyslexic
        XCTAssertNotEqual(TPPReaderFont.sansSerif.propertyIndex, TPPReaderFont.serif.propertyIndex)
    }

    func testMapIndexToFontFamily_serif() {
        let family = TPPReaderSettings.mapIndexToFontFamily(TPPReaderFont.serif.propertyIndex)
        XCTAssertEqual(family, .serif)
        // Verify the round-trip works the other way
        XCTAssertEqual(TPPReaderSettings.mapFontFamilyToIndex(.serif), TPPReaderFont.serif.propertyIndex)
    }

    func testMapIndexToFontFamily_dyslexic() {
        let family = TPPReaderSettings.mapIndexToFontFamily(TPPReaderFont.dyslexic.propertyIndex)
        XCTAssertEqual(family, .openDyslexic)
        // dyslexic index must differ from sansSerif and serif
        XCTAssertNotEqual(TPPReaderFont.dyslexic.propertyIndex, TPPReaderFont.sansSerif.propertyIndex)
        XCTAssertNotEqual(TPPReaderFont.dyslexic.propertyIndex, TPPReaderFont.serif.propertyIndex)
    }

    func testMapIndexToFontFamily_default() {
        let family = TPPReaderSettings.mapIndexToFontFamily(TPPReaderFont.original.propertyIndex)
        XCTAssertNil(family)
        // Verify original index is 0
        XCTAssertEqual(TPPReaderFont.original.propertyIndex, 0, "Original font must map to index 0")
    }

    // MARK: - Preferences Loading Tests

    func testLoadPreferences_returnsPreferences() {
        let preferences = TPPReaderSettings.loadPreferences()
        XCTAssertNotNil(preferences)
        // Calling it twice must return consistent values
        let preferences2 = TPPReaderSettings.loadPreferences()
        XCTAssertNotNil(preferences2)
        XCTAssertEqual(preferences.theme, preferences2.theme,
                       "loadPreferences() must return the same theme on repeated calls")
    }
}

// MARK: - TPPReaderPreferencesLoad Tests

@MainActor
final class TPPReaderPreferencesLoadTests: XCTestCase {

    func testTPPReaderPreferencesLoad_returnsValidPreferences() {
        let preferences = TPPReaderPreferencesLoad()
        // publisherStyles must always be disabled by default for consistency
        XCTAssertEqual(preferences.publisherStyles, false)
        // A theme must always be set
        XCTAssertNotNil(preferences.theme)
        // Two calls must produce consistent publisherStyles
        let preferences2 = TPPReaderPreferencesLoad()
        XCTAssertEqual(preferences2.publisherStyles, preferences.publisherStyles,
                       "publisherStyles must be consistent across calls")
    }

    func testTPPReaderPreferencesLoad_disablesPublisherStyles() {
        let preferences = TPPReaderPreferencesLoad()
        XCTAssertEqual(preferences.publisherStyles, false)
        // Multiple calls must return the same value
        let preferences2 = TPPReaderPreferencesLoad()
        XCTAssertEqual(preferences2.publisherStyles, false,
                       "publisherStyles must consistently be false")
    }

    func testTPPReaderPreferencesLoad_setsDefaultTheme() {
        let preferences = TPPReaderPreferencesLoad()
        // The theme object must have a defined value (not nil)
        XCTAssertNotNil(preferences.theme, "Theme must be set on every TPPReaderPreferencesLoad call")
        // Two consecutive loads must return the same theme (idempotent)
        let preferences2 = TPPReaderPreferencesLoad()
        XCTAssertEqual(preferences2.theme, preferences.theme,
                       "Repeated TPPReaderPreferencesLoad calls must return the same theme")
    }
}

// MARK: - Reader Appearance Tests

@MainActor
final class TPPReaderAppearanceTests: XCTestCase {

    func testBlackOnWhite_hasCorrectPropertyIndex() {
        let appearance = TPPReaderAppearance.blackOnWhite
        XCTAssertEqual(appearance.propertyIndex, 0)
        // Must be distinct from whiteOnBlack
        XCTAssertNotEqual(appearance.propertyIndex, TPPReaderAppearance.whiteOnBlack.propertyIndex)
    }

    func testWhiteOnBlack_hasCorrectPropertyIndex() {
        let appearance = TPPReaderAppearance.whiteOnBlack
        XCTAssertNotNil(appearance.propertyIndex)
        // Must differ from the default (blackOnWhite = 0) and from sepia
        XCTAssertNotEqual(appearance.propertyIndex, TPPReaderAppearance.blackOnWhite.propertyIndex,
                          "whiteOnBlack must have a different index than blackOnWhite")
        XCTAssertNotEqual(appearance.propertyIndex, TPPReaderAppearance.blackOnSepia.propertyIndex,
                          "whiteOnBlack must have a different index than blackOnSepia")
    }

    func testBlackOnSepia_hasCorrectPropertyIndex() {
        let appearance = TPPReaderAppearance.blackOnSepia
        XCTAssertNotNil(appearance.propertyIndex)
        // Must differ from default (blackOnWhite = 0) and from dark
        XCTAssertNotEqual(appearance.propertyIndex, TPPReaderAppearance.blackOnWhite.propertyIndex,
                          "blackOnSepia must have a different index than blackOnWhite")
        XCTAssertNotEqual(appearance.propertyIndex, TPPReaderAppearance.whiteOnBlack.propertyIndex,
                          "blackOnSepia must have a different index than whiteOnBlack")
    }

    func testAssociatedColors_blackOnWhite_hasLightBackground() {
        let appearance = TPPReaderAppearance.blackOnWhite
        let colors = appearance.associatedColors

        // The background is a light color (near white)
        var white: CGFloat = 0
        colors.backgroundColor.getWhite(&white, alpha: nil)
        XCTAssertGreaterThan(white, 0.9, "Background should be a light color (near white)")
        XCTAssertEqual(colors.textColor, .black)
    }
}

// MARK: - Reader Font Tests

@MainActor
final class TPPReaderFontTests: XCTestCase {

    func testOriginal_hasCorrectPropertyIndex() {
        let font = TPPReaderFont.original
        XCTAssertEqual(font.propertyIndex, 0)
        // Original font index must be distinct from sansSerif
        XCTAssertNotEqual(font.propertyIndex, TPPReaderFont.sansSerif.propertyIndex)
    }

    func testSansSerif_hasPropertyIndex() {
        let font = TPPReaderFont.sansSerif
        XCTAssertNotNil(font.propertyIndex)
        // Must differ from the default (original = 0), serif, and dyslexic
        XCTAssertNotEqual(font.propertyIndex, TPPReaderFont.original.propertyIndex,
                          "sansSerif must differ from original")
        XCTAssertNotEqual(font.propertyIndex, TPPReaderFont.serif.propertyIndex,
                          "sansSerif must differ from serif")
    }

    func testSerif_hasPropertyIndex() {
        let font = TPPReaderFont.serif
        XCTAssertNotNil(font.propertyIndex)
        XCTAssertNotEqual(font.propertyIndex, TPPReaderFont.original.propertyIndex,
                          "serif must differ from original")
        XCTAssertNotEqual(font.propertyIndex, TPPReaderFont.sansSerif.propertyIndex,
                          "serif must differ from sansSerif")
    }

    func testDyslexic_hasPropertyIndex() {
        let font = TPPReaderFont.dyslexic
        XCTAssertNotNil(font.propertyIndex)
        XCTAssertNotEqual(font.propertyIndex, TPPReaderFont.original.propertyIndex,
                          "dyslexic must differ from original")
        XCTAssertNotEqual(font.propertyIndex, TPPReaderFont.sansSerif.propertyIndex,
                          "dyslexic must differ from sansSerif")
        XCTAssertNotEqual(font.propertyIndex, TPPReaderFont.serif.propertyIndex,
                          "dyslexic must differ from serif")
    }
}

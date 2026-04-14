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
    }

    func testInit_setsDefaultFontFamilyIndex() {
        let settings = TPPReaderSettings()
        XCTAssertEqual(settings.fontFamilyIndex, 0)
    }

    func testInit_setsDefaultAppearanceIndex() {
        let settings = TPPReaderSettings()
        XCTAssertEqual(settings.appearanceIndex, 0)
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
    }

    func testCanDecreaseFontSize_falseAtMinimum() {
        let settings = TPPReaderSettings()
        settings.fontSize = 1.0

        XCTAssertFalse(settings.canDecreaseFontSize)
    }

    // MARK: - Appearance Tests

    func testChangeAppearance_updatesIndex() {
        let settings = TPPReaderSettings()

        settings.changeAppearance(appearanceIndex: 1)

        XCTAssertEqual(settings.appearanceIndex, 1)
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
    }

    // MARK: - Mapping Helper Tests

    func testMapFontFamilyToIndex_sansSerif() {
        let index = TPPReaderSettings.mapFontFamilyToIndex(.sansSerif)
        XCTAssertEqual(index, TPPReaderFont.sansSerif.propertyIndex)
    }

    func testMapFontFamilyToIndex_serif() {
        let index = TPPReaderSettings.mapFontFamilyToIndex(.serif)
        XCTAssertEqual(index, TPPReaderFont.serif.propertyIndex)
    }

    func testMapFontFamilyToIndex_openDyslexic() {
        let index = TPPReaderSettings.mapFontFamilyToIndex(.openDyslexic)
        XCTAssertEqual(index, TPPReaderFont.dyslexic.propertyIndex)
    }

    func testMapFontFamilyToIndex_nil() {
        let index = TPPReaderSettings.mapFontFamilyToIndex(nil)
        XCTAssertEqual(index, TPPReaderFont.original.propertyIndex)
    }

    func testMapAppearanceToIndex_dark() {
        let index = TPPReaderSettings.mapAppearanceToIndex(.dark)
        XCTAssertEqual(index, TPPReaderAppearance.whiteOnBlack.propertyIndex)
    }

    func testMapAppearanceToIndex_sepia() {
        let index = TPPReaderSettings.mapAppearanceToIndex(.sepia)
        XCTAssertEqual(index, TPPReaderAppearance.blackOnSepia.propertyIndex)
    }

    func testMapAppearanceToIndex_light() {
        let index = TPPReaderSettings.mapAppearanceToIndex(.light)
        XCTAssertEqual(index, TPPReaderAppearance.blackOnWhite.propertyIndex)
    }

    func testMapIndexToAppearance_dark() {
        let theme = TPPReaderSettings.mapIndexToAppearance(TPPReaderAppearance.whiteOnBlack.propertyIndex)
        XCTAssertEqual(theme, .dark)
    }

    func testMapIndexToAppearance_sepia() {
        let theme = TPPReaderSettings.mapIndexToAppearance(TPPReaderAppearance.blackOnSepia.propertyIndex)
        XCTAssertEqual(theme, .sepia)
    }

    func testMapIndexToAppearance_default() {
        let theme = TPPReaderSettings.mapIndexToAppearance(TPPReaderAppearance.blackOnWhite.propertyIndex)
        XCTAssertEqual(theme, .light)
    }

    func testMapIndexToFontFamily_sansSerif() {
        let family = TPPReaderSettings.mapIndexToFontFamily(TPPReaderFont.sansSerif.propertyIndex)
        XCTAssertEqual(family, .sansSerif)
    }

    func testMapIndexToFontFamily_serif() {
        let family = TPPReaderSettings.mapIndexToFontFamily(TPPReaderFont.serif.propertyIndex)
        XCTAssertEqual(family, .serif)
    }

    func testMapIndexToFontFamily_dyslexic() {
        let family = TPPReaderSettings.mapIndexToFontFamily(TPPReaderFont.dyslexic.propertyIndex)
        XCTAssertEqual(family, .openDyslexic)
    }

    func testMapIndexToFontFamily_default() {
        let family = TPPReaderSettings.mapIndexToFontFamily(TPPReaderFont.original.propertyIndex)
        XCTAssertNil(family)
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

final class TPPReaderPreferencesLoadTests: XCTestCase {

    func testTPPReaderPreferencesLoad_returnsValidPreferences() {
        let preferences = TPPReaderPreferencesLoad()
        XCTAssertNotNil(preferences)
        // publisherStyles must always be disabled by default for consistency
        XCTAssertEqual(preferences.publisherStyles, false)
        // A theme must always be set
        XCTAssertNotNil(preferences.theme)
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
        XCTAssertNotNil(preferences.theme)
        // The theme object must have a defined value (not nil)
        let theme = preferences.theme
        XCTAssertNotNil(theme, "Theme must be set on every TPPReaderPreferencesLoad call")
    }
}

// MARK: - Reader Appearance Tests

final class TPPReaderAppearanceTests: XCTestCase {

    func testBlackOnWhite_hasCorrectPropertyIndex() {
        let appearance = TPPReaderAppearance.blackOnWhite
        XCTAssertEqual(appearance.propertyIndex, 0)
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

final class TPPReaderFontTests: XCTestCase {

    func testOriginal_hasCorrectPropertyIndex() {
        let font = TPPReaderFont.original
        XCTAssertEqual(font.propertyIndex, 0)
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

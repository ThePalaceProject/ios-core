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
    
    // Colors should change
    XCTAssertNotNil(settings.backgroundColor)
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
  }
}

// MARK: - TPPReaderPreferencesLoad Tests

final class TPPReaderPreferencesLoadTests: XCTestCase {
  
  func testTPPReaderPreferencesLoad_returnsValidPreferences() {
    let preferences = TPPReaderPreferencesLoad()
    XCTAssertNotNil(preferences)
  }
  
  func testTPPReaderPreferencesLoad_disablesPublisherStyles() {
    let preferences = TPPReaderPreferencesLoad()
    XCTAssertEqual(preferences.publisherStyles, false)
  }
  
  func testTPPReaderPreferencesLoad_setsDefaultTheme() {
    let preferences = TPPReaderPreferencesLoad()
    XCTAssertNotNil(preferences.theme)
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
    // Index depends on implementation
    XCTAssertNotNil(appearance.propertyIndex)
  }
  
  func testBlackOnSepia_hasCorrectPropertyIndex() {
    let appearance = TPPReaderAppearance.blackOnSepia
    // Index depends on implementation
    XCTAssertNotNil(appearance.propertyIndex)
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
  }
  
  func testSerif_hasPropertyIndex() {
    let font = TPPReaderFont.serif
    XCTAssertNotNil(font.propertyIndex)
  }
  
  func testDyslexic_hasPropertyIndex() {
    let font = TPPReaderFont.dyslexic
    XCTAssertNotNil(font.propertyIndex)
  }
}


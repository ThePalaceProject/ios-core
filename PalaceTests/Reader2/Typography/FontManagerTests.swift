//
//  FontManagerTests.swift
//  PalaceTests
//
//  Tests for FontManager: font registration and availability checking.
//

import XCTest
@testable import Palace

final class FontManagerTests: XCTestCase {

    // MARK: - Singleton

    func testSharedInstanceExists() {
        XCTAssertNotNil(FontManager.shared)
    }

    // MARK: - Font Registration

    func testRegisterCustomFontsDoesNotCrash() {
        // Should not throw or crash even if called multiple times
        FontManager.shared.registerCustomFonts()
        FontManager.shared.registerCustomFonts()
    }

    func testRegisterNonexistentFontReturnsFalse() {
        let result = FontManager.shared.registerFont(named: "NonExistentFont12345", extension: "ttf")
        XCTAssertFalse(result, "Registering a nonexistent font should return false")
    }

    // MARK: - Font Availability

    func testSystemFontsAreAvailable() {
        // System fonts should always be available
        XCTAssertTrue(FontManager.shared.isFontAvailable("Georgia"))
        XCTAssertTrue(FontManager.shared.isFontAvailable("Palatino"))
        XCTAssertTrue(FontManager.shared.isFontAvailable("HelveticaNeue"))
        XCTAssertTrue(FontManager.shared.isFontAvailable("TimesNewRomanPSMT"))
    }

    func testNonExistentFontIsNotAvailable() {
        XCTAssertFalse(FontManager.shared.isFontAvailable("TotallyFakeFont12345"))
    }

    func testFamilyAvailabilityForSystemFonts() {
        XCTAssertTrue(FontManager.shared.isFamilyAvailable(.georgia))
        XCTAssertTrue(FontManager.shared.isFamilyAvailable(.sfPro))
        XCTAssertTrue(FontManager.shared.isFamilyAvailable(.helveticaNeue))
        XCTAssertTrue(FontManager.shared.isFamilyAvailable(.palatino))
    }

    func testAvailableFamiliesNotEmpty() {
        let families = FontManager.shared.availableFamilies()
        XCTAssertFalse(families.isEmpty, "At least system fonts should be available")
        XCTAssertTrue(families.contains(.georgia))
        XCTAssertTrue(families.contains(.sfPro))
    }

    // MARK: - TPPFontFamily Properties

    func testAllFontFamiliesHaveCSSValue() {
        for family in TPPFontFamily.allCases {
            XCTAssertFalse(family.cssValue.isEmpty,
                          "Font family \(family.displayName) should have a CSS value")
        }
    }

    func testAllFontFamiliesHaveDisplayName() {
        for family in TPPFontFamily.allCases {
            XCTAssertFalse(family.displayName.isEmpty,
                          "Font family \(family.rawValue) should have a display name")
        }
    }

    func testAllFontFamiliesHavePreviewText() {
        for family in TPPFontFamily.allCases {
            XCTAssertFalse(family.previewText.isEmpty,
                          "Font family \(family.displayName) should have preview text")
        }
    }

    func testAllFontFamiliesHaveCategory() {
        for family in TPPFontFamily.allCases {
            // Just verify the property doesn't crash
            _ = family.category
        }
    }

    func testFontFamilyCategorization() {
        XCTAssertEqual(TPPFontFamily.georgia.category, .serif)
        XCTAssertEqual(TPPFontFamily.palatino.category, .serif)
        XCTAssertEqual(TPPFontFamily.timesNewRoman.category, .serif)
        XCTAssertEqual(TPPFontFamily.newYork.category, .serif)
        XCTAssertEqual(TPPFontFamily.sfPro.category, .sansSerif)
        XCTAssertEqual(TPPFontFamily.helveticaNeue.category, .sansSerif)
        XCTAssertEqual(TPPFontFamily.avenir.category, .sansSerif)
        XCTAssertEqual(TPPFontFamily.openDyslexic.category, .accessibility)
    }

    func testFontsInCategory() {
        let serifFonts = TPPFontFamily.fonts(in: .serif)
        XCTAssertTrue(serifFonts.contains(.georgia))
        XCTAssertTrue(serifFonts.contains(.palatino))
        XCTAssertFalse(serifFonts.contains(.sfPro))

        let sansFonts = TPPFontFamily.fonts(in: .sansSerif)
        XCTAssertTrue(sansFonts.contains(.sfPro))
        XCTAssertFalse(sansFonts.contains(.georgia))

        let accessFonts = TPPFontFamily.fonts(in: .accessibility)
        XCTAssertTrue(accessFonts.contains(.openDyslexic))
        XCTAssertEqual(accessFonts.count, 1)
    }

    func testUIFontCreation() {
        for family in TPPFontFamily.allCases {
            let font = family.uiFont(size: 16)
            XCTAssertNotNil(font, "Should create a UIFont for \(family.displayName)")
            // Even if the exact font isn't available, uiFont falls back to system font
        }
    }

    func testSwiftUIFontCreation() {
        for family in TPPFontFamily.allCases {
            // Just verify this doesn't crash
            _ = family.swiftUIFont(size: 16)
        }
    }

    // MARK: - TPPFontFamily Codable

    func testFontFamilyIsCodable() throws {
        for family in TPPFontFamily.allCases {
            let data = try JSONEncoder().encode(family)
            let decoded = try JSONDecoder().decode(TPPFontFamily.self, from: data)
            XCTAssertEqual(family, decoded, "\(family.displayName) should survive encode/decode")
        }
    }

    // MARK: - OpenDyslexic CSS

    func testOpenDyslexicCSSContainsFontName() {
        let css = TPPFontFamily.openDyslexic.cssValue
        XCTAssertTrue(css.contains("OpenDyslexic"), "OpenDyslexic CSS should reference the font name")
    }
}

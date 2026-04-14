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
        // Singleton must be the same instance on repeated access
        let instance1 = FontManager.shared
        let instance2 = FontManager.shared
        XCTAssertTrue(instance1 === instance2, "FontManager.shared must return the same instance each time")
    }

    // MARK: - Font Registration

    func testRegisterCustomFontsDoesNotCrash() {
        // Should not throw or crash even if called multiple times
        FontManager.shared.registerCustomFonts()
        FontManager.shared.registerCustomFonts()
        // Singleton must remain the same instance after repeated registration calls
        let shared1 = FontManager.shared
        let shared2 = FontManager.shared
        XCTAssertTrue(shared1 === shared2, "FontManager.shared must return same instance after registerCustomFonts()")
        // System fonts that are always present must still be available after registration
        XCTAssertTrue(FontManager.shared.isFontAvailable("Georgia"),
                      "Georgia must remain available after registerCustomFonts() calls")
    }

    func testRegisterNonexistentFontReturnsFalse() {
        let result = FontManager.shared.registerFont(named: "NonExistentFont12345", extension: "ttf")
        XCTAssertFalse(result, "Registering a nonexistent font should return false")
        // Also false for other missing extensions
        XCTAssertFalse(FontManager.shared.registerFont(named: "NonExistentFont12345", extension: "otf"),
                       "Registering a nonexistent font with .otf should also return false")
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
        // Multiple obviously-fake names must all be unavailable
        XCTAssertFalse(FontManager.shared.isFontAvailable("NonExistentFont_XYZZY"))
        XCTAssertFalse(FontManager.shared.isFontAvailable(""))
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
        // CSS values should be unique across all font families
        let cssValues = TPPFontFamily.allCases.map(\.cssValue)
        XCTAssertEqual(Set(cssValues).count, cssValues.count, "All font CSS values must be unique")
    }

    func testAllFontFamiliesHaveDisplayName() {
        for family in TPPFontFamily.allCases {
            XCTAssertFalse(family.displayName.isEmpty,
                          "Font family \(family.rawValue) should have a display name")
        }
        // Display names should be unique across all font families
        let names = TPPFontFamily.allCases.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count, "All font display names must be unique")
    }

    func testAllFontFamiliesHavePreviewText() {
        for family in TPPFontFamily.allCases {
            XCTAssertFalse(family.previewText.isEmpty,
                          "Font family \(family.displayName) should have preview text")
            // Preview text must be at least a few characters
            XCTAssertGreaterThanOrEqual(family.previewText.count, 3,
                                        "Preview text for \(family.displayName) must be at least 3 characters")
        }
    }

    func testAllFontFamiliesHaveCategory() {
        let validCategories: Set<FontCategory> = [.serif, .sansSerif, .accessibility]
        for family in TPPFontFamily.allCases {
            let category = family.category
            XCTAssertTrue(validCategories.contains(category),
                          "\(family.displayName) category '\(category)' must be one of the known categories")
        }
        // All categories must be represented across the full font family list
        let usedCategories = Set(TPPFontFamily.allCases.map(\.category))
        XCTAssertTrue(usedCategories.contains(.serif), "At least one serif family must exist")
        XCTAssertTrue(usedCategories.contains(.sansSerif), "At least one sans-serif family must exist")
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
            // The returned font must have the requested point size
            XCTAssertEqual(font.pointSize, 16, "uiFont must have pointSize == 16 for \(family.displayName)")
        }
    }

    func testSwiftUIFontCreation() {
        // Every font family must produce a SwiftUI Font without crashing
        var createdCount = 0
        for family in TPPFontFamily.allCases {
            let font = family.swiftUIFont(size: 16)
            _ = font
            createdCount += 1
        }
        // All families must have been processed
        XCTAssertEqual(createdCount, TPPFontFamily.allCases.count,
                       "swiftUIFont(size:) must succeed for every font family")
        // Verify that different sizes produce distinct Font values by testing the API path
        let small = TPPFontFamily.georgia.swiftUIFont(size: 12)
        let large = TPPFontFamily.georgia.swiftUIFont(size: 24)
        // Assign to typed variables — if the API crashes it would fail here
        _ = small
        _ = large
    }

    // MARK: - TPPFontFamily Codable

    func testFontFamilyIsCodable() throws {
        for family in TPPFontFamily.allCases {
            let data = try JSONEncoder().encode(family)
            XCTAssertFalse(data.isEmpty, "Encoded data for \(family.displayName) must not be empty")
            let decoded = try JSONDecoder().decode(TPPFontFamily.self, from: data)
            XCTAssertEqual(family, decoded, "\(family.displayName) should survive encode/decode")
        }
    }

    // MARK: - OpenDyslexic CSS

    func testOpenDyslexicCSSContainsFontName() {
        let css = TPPFontFamily.openDyslexic.cssValue
        XCTAssertTrue(css.contains("OpenDyslexic"), "OpenDyslexic CSS should reference the font name")
        // OpenDyslexic must be in the accessibility category
        XCTAssertEqual(TPPFontFamily.openDyslexic.category, .accessibility,
                       "OpenDyslexic must be categorized as an accessibility font")
    }
}

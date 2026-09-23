//
//  ReaderThemeTests.swift
//  PalaceTests
//
//  Tests for ReaderTheme color definitions, CSS generation, and Codable.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

@MainActor
final class ReaderThemeTests: XCTestCase {

    // MARK: - All Cases

    func testAllCases_containsExactly5Themes() {
        XCTAssertEqual(ReaderTheme.allCases.count, 5)
        // All IDs must be unique
        let ids = ReaderTheme.allCases.map(\.id)
        XCTAssertEqual(Set(ids).count, 5, "All theme IDs must be unique")
        // All raw values must be unique
        let rawValues = ReaderTheme.allCases.map(\.rawValue)
        XCTAssertEqual(Set(rawValues).count, 5, "All theme rawValues must be unique")
    }

    func testAllCases_containsExpectedThemes() {
        // Production ReaderTheme.id returns rawValue which is capitalized.
        let ids = Set(ReaderTheme.allCases.map(\.id))
        XCTAssertTrue(ids.contains("Light"))
        XCTAssertTrue(ids.contains("Sepia"))
        XCTAssertTrue(ids.contains("Solarized"))
        XCTAssertTrue(ids.contains("Dark"))
        XCTAssertTrue(ids.contains("Night"))
    }

    // MARK: - Unique IDs

    func testEachThemeID_isUnique() {
        let ids = ReaderTheme.allCases.map(\.id)
        let uniqueIds = Set(ids)
        XCTAssertEqual(ids.count, uniqueIds.count, "Theme IDs must be unique")
        // IDs must be non-empty strings
        for id in ids {
            XCTAssertFalse(id.isEmpty, "Each theme ID must be a non-empty string")
        }
    }

    // MARK: - Valid Background Colors

    func testAllThemes_haveValidBackgroundColors() {
        for theme in ReaderTheme.allCases {
            XCTAssertNotNil(theme.backgroundColor,
                            "Theme '\(theme.rawValue)' should have a valid background color")
            // Background colors must be distinct from each other
        }
        // Verify all background colors are distinct
        let bgHexes = ReaderTheme.allCases.map(\.backgroundCSSHex)
        XCTAssertEqual(Set(bgHexes).count, bgHexes.count, "All themes must have distinct background colors")
    }

    // MARK: - Valid Text Colors

    func testAllThemes_haveValidTextColors() {
        for theme in ReaderTheme.allCases {
            XCTAssertNotNil(theme.textColor,
                            "Theme '\(theme.rawValue)' should have a valid text color")
        }
        // Verify text colors differ between dark and light themes
        XCTAssertNotEqual(ReaderTheme.light.textCSSHex, ReaderTheme.night.textCSSHex,
                          "Light and Night themes must have different text colors")
    }

    // MARK: - CSS Hex Format

    func testAllThemes_haveCSSHexBackgrounds() {
        for theme in ReaderTheme.allCases {
            let hex = theme.backgroundCSSHex
            XCTAssertTrue(hex.hasPrefix("#"),
                          "CSS hex for '\(theme.rawValue)' background should start with #")
            XCTAssertEqual(hex.count, 7,
                           "CSS hex for '\(theme.rawValue)' background should be 7 chars (#RRGGBB)")
        }
    }

    func testAllThemes_haveCSSHexTextColors() {
        for theme in ReaderTheme.allCases {
            let hex = theme.textCSSHex
            XCTAssertTrue(hex.hasPrefix("#"),
                          "CSS hex for '\(theme.rawValue)' text should start with #")
            XCTAssertEqual(hex.count, 7,
                           "CSS hex for '\(theme.rawValue)' text should be 7 chars (#RRGGBB)")
        }
    }

    func testCSSHex_matchesExpectedFormat() {
        let hexPattern = try! NSRegularExpression(pattern: "^#[0-9A-Fa-f]{6}$")

        for theme in ReaderTheme.allCases {
            let bgRange = NSRange(theme.backgroundCSSHex.startIndex..., in: theme.backgroundCSSHex)
            XCTAssertNotNil(
                hexPattern.firstMatch(in: theme.backgroundCSSHex, range: bgRange),
                "Background hex '\(theme.backgroundCSSHex)' for '\(theme.rawValue)' does not match #RRGGBB"
            )

            let txtRange = NSRange(theme.textCSSHex.startIndex..., in: theme.textCSSHex)
            XCTAssertNotNil(
                hexPattern.firstMatch(in: theme.textCSSHex, range: txtRange),
                "Text hex '\(theme.textCSSHex)' for '\(theme.rawValue)' does not match #RRGGBB"
            )
        }
    }

    // MARK: - Dark/Light Classification

    func testDarkTheme_hasDarkBackground() {
        XCTAssertTrue(ReaderTheme.dark.isDark,
                      "Dark theme should have a dark background")
        // Dark themes must have light text (contrast requirement)
        var white: CGFloat = 0
        ReaderTheme.dark.textColor.getWhite(&white, alpha: nil)
        XCTAssertGreaterThan(white, 0.5, "Dark theme must use light text for contrast")
        // CSS hex must not be the same as a light theme
        XCTAssertNotEqual(ReaderTheme.dark.backgroundCSSHex, ReaderTheme.light.backgroundCSSHex,
                          "Dark and light themes must have different background colors")
    }

    func testNightTheme_hasDarkBackground() {
        XCTAssertTrue(ReaderTheme.night.isDark,
                      "Night theme should have a dark background")
        // Night theme must be darker than (or as dark as) the dark theme
        XCTAssertTrue(ReaderTheme.night.backgroundCSSHex <= ReaderTheme.dark.backgroundCSSHex ||
                      ReaderTheme.night.backgroundCSSHex == "#000000",
                      "Night theme background should be black or very dark")
        XCTAssertNotEqual(ReaderTheme.night.backgroundCSSHex, ReaderTheme.light.backgroundCSSHex,
                          "Night and light themes must have different backgrounds")
    }

    func testLightTheme_hasLightBackground() {
        XCTAssertFalse(ReaderTheme.light.isDark,
                       "Light theme should NOT be dark")
        XCTAssertEqual(ReaderTheme.light.backgroundCSSHex, "#FFFFFF",
                       "Light theme background should be pure white")
        // Light themes must have dark text
        var white: CGFloat = 0
        ReaderTheme.light.textColor.getWhite(&white, alpha: nil)
        XCTAssertLessThan(white, 0.5, "Light theme must use dark text for contrast")
    }

    func testSepiaTheme_hasLightBackground() {
        XCTAssertFalse(ReaderTheme.sepia.isDark,
                       "Sepia theme should NOT be dark")
        // Sepia background must differ from both white and black
        XCTAssertNotEqual(ReaderTheme.sepia.backgroundCSSHex, "#FFFFFF",
                          "Sepia should not be pure white")
        XCTAssertNotEqual(ReaderTheme.sepia.backgroundCSSHex, "#000000",
                          "Sepia should not be black")
    }

    func testSolarizedTheme_hasLightBackground() {
        XCTAssertFalse(ReaderTheme.solarized.isDark,
                       "Solarized theme should NOT be dark")
        // Solarized background must be distinct from both light and sepia
        XCTAssertNotEqual(ReaderTheme.solarized.backgroundCSSHex, ReaderTheme.light.backgroundCSSHex,
                          "Solarized must differ from pure white")
        XCTAssertNotEqual(ReaderTheme.solarized.backgroundCSSHex, "#000000",
                          "Solarized should not be black")
    }

    // MARK: - Light Themes Have Dark Text

    func testLightTheme_hasDarkText() {
        var white: CGFloat = 0
        ReaderTheme.light.textColor.getWhite(&white, alpha: nil)
        XCTAssertLessThan(white, 0.3, "Light theme text should be dark")
        // Light theme must NOT classify as dark
        XCTAssertFalse(ReaderTheme.light.isDark, "Light theme must not be classified as dark")
    }

    func testSepiaTheme_hasDarkText() {
        var white: CGFloat = 0
        ReaderTheme.sepia.textColor.getWhite(&white, alpha: nil)
        XCTAssertLessThan(white, 0.5, "Sepia theme text should be dark")
        // Sepia must NOT be classified as dark
        XCTAssertFalse(ReaderTheme.sepia.isDark, "Sepia theme must not be classified as dark")
    }

    // MARK: - Dark Themes Have Light Text

    func testDarkTheme_hasLightText() {
        var white: CGFloat = 0
        ReaderTheme.dark.textColor.getWhite(&white, alpha: nil)
        XCTAssertGreaterThan(white, 0.7, "Dark theme text should be light")
        // Dark theme must be classified as dark
        XCTAssertTrue(ReaderTheme.dark.isDark, "Dark theme must be classified as dark")
    }

    func testNightTheme_hasLightText() {
        var white: CGFloat = 0
        ReaderTheme.night.textColor.getWhite(&white, alpha: nil)
        // Production night text is RGB 0.70/0.70/0.70.
        // Float round-trip yields ~0.6999999, so use a tolerance.
        XCTAssertEqual(white, 0.7, accuracy: 0.001, "Night theme text should be ~0.7 brightness")
        // Night theme must be classified as dark
        XCTAssertTrue(ReaderTheme.night.isDark, "Night theme must be classified as dark")
    }

    // MARK: - Codable Round-Trip

    func testCodable_roundTrip() throws {
        for theme in ReaderTheme.allCases {
            let data = try JSONEncoder().encode(theme)
            XCTAssertFalse(data.isEmpty, "Encoded data for theme '\(theme.rawValue)' must not be empty")
            let decoded = try JSONDecoder().decode(ReaderTheme.self, from: data)
            XCTAssertEqual(decoded, theme,
                           "Codable round-trip failed for theme '\(theme.rawValue)'")
        }
    }

    func testCodable_preservesAllProperties() throws {
        let theme = ReaderTheme.sepia
        let data = try JSONEncoder().encode(theme)
        let decoded = try JSONDecoder().decode(ReaderTheme.self, from: data)

        XCTAssertEqual(decoded.id, theme.id)
        XCTAssertEqual(decoded.rawValue, theme.rawValue)
        XCTAssertEqual(decoded.backgroundCSSHex, theme.backgroundCSSHex)
        XCTAssertEqual(decoded.textCSSHex, theme.textCSSHex)
    }

    // MARK: - Equatable

    func testEquatable_sameThemesAreEqual() {
        XCTAssertEqual(ReaderTheme.light, ReaderTheme.light)
        XCTAssertEqual(ReaderTheme.dark, ReaderTheme.dark)
    }

    func testEquatable_differentThemesAreNotEqual() {
        XCTAssertNotEqual(ReaderTheme.light, ReaderTheme.dark)
        XCTAssertNotEqual(ReaderTheme.sepia, ReaderTheme.night)
    }

    // MARK: - Specific Color Values

    func testLightTheme_whiteBackground() {
        XCTAssertEqual(ReaderTheme.light.backgroundCSSHex, "#FFFFFF")
        // Production light text is RGB 0.13/0.13/0.13 = #212121 (not pure black)
        XCTAssertEqual(ReaderTheme.light.textCSSHex, "#212121")
    }

    func testDarkTheme_darkBackground() {
        // Production dark bg is RGB 0.18/0.18/0.20 = #2D2D33 (warm dark)
        XCTAssertEqual(ReaderTheme.dark.backgroundCSSHex, "#2D2D33")
        // Must not be pure black (that's the night theme) or pure white
        XCTAssertNotEqual(ReaderTheme.dark.backgroundCSSHex, "#000000",
                          "Dark theme must not be pure black (that is the Night theme)")
        XCTAssertNotEqual(ReaderTheme.dark.backgroundCSSHex, "#FFFFFF",
                          "Dark theme must not be white")
    }

    func testNightTheme_nearBlackBackground() {
        // Production night bg is pure black (0.0/0.0/0.0)
        XCTAssertEqual(ReaderTheme.night.backgroundCSSHex, "#000000")
        // Night background must be darker than the dark theme background
        XCTAssertNotEqual(ReaderTheme.night.backgroundCSSHex, ReaderTheme.dark.backgroundCSSHex,
                          "Night theme must have a different background than Dark theme")
    }
}

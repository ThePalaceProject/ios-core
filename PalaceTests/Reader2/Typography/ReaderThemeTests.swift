//
//  ReaderThemeTests.swift
//  PalaceTests
//
//  Tests for ReaderTheme color definitions, CSS generation, and Codable.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class ReaderThemeTests: XCTestCase {

    // MARK: - All Cases

    func testAllCases_containsExactly5Themes() {
        XCTAssertEqual(ReaderTheme.allCases.count, 5)
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
    }

    // MARK: - Valid Background Colors

    func testAllThemes_haveValidBackgroundColors() {
        for theme in ReaderTheme.allCases {
            XCTAssertNotNil(theme.backgroundColor,
                            "Theme '\(theme.rawValue)' should have a valid background color")
        }
    }

    // MARK: - Valid Text Colors

    func testAllThemes_haveValidTextColors() {
        for theme in ReaderTheme.allCases {
            XCTAssertNotNil(theme.textColor,
                            "Theme '\(theme.rawValue)' should have a valid text color")
        }
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
    }

    func testNightTheme_hasDarkBackground() {
        XCTAssertTrue(ReaderTheme.night.isDark,
                      "Night theme should have a dark background")
    }

    func testLightTheme_hasLightBackground() {
        XCTAssertFalse(ReaderTheme.light.isDark,
                       "Light theme should NOT be dark")
    }

    func testSepiaTheme_hasLightBackground() {
        XCTAssertFalse(ReaderTheme.sepia.isDark,
                       "Sepia theme should NOT be dark")
    }

    func testSolarizedTheme_hasLightBackground() {
        XCTAssertFalse(ReaderTheme.solarized.isDark,
                       "Solarized theme should NOT be dark")
    }

    // MARK: - Light Themes Have Dark Text

    func testLightTheme_hasDarkText() {
        var white: CGFloat = 0
        ReaderTheme.light.textColor.getWhite(&white, alpha: nil)
        XCTAssertLessThan(white, 0.3, "Light theme text should be dark")
    }

    func testSepiaTheme_hasDarkText() {
        var white: CGFloat = 0
        ReaderTheme.sepia.textColor.getWhite(&white, alpha: nil)
        XCTAssertLessThan(white, 0.5, "Sepia theme text should be dark")
    }

    // MARK: - Dark Themes Have Light Text

    func testDarkTheme_hasLightText() {
        var white: CGFloat = 0
        ReaderTheme.dark.textColor.getWhite(&white, alpha: nil)
        XCTAssertGreaterThan(white, 0.7, "Dark theme text should be light")
    }

    func testNightTheme_hasLightText() {
        var white: CGFloat = 0
        ReaderTheme.night.textColor.getWhite(&white, alpha: nil)
        // Production night text is RGB 0.70/0.70/0.70.
        // Float round-trip yields ~0.6999999, so use a tolerance.
        XCTAssertEqual(white, 0.7, accuracy: 0.001, "Night theme text should be ~0.7 brightness")
    }

    // MARK: - Codable Round-Trip

    func testCodable_roundTrip() throws {
        for theme in ReaderTheme.allCases {
            let data = try JSONEncoder().encode(theme)
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
    }

    func testNightTheme_nearBlackBackground() {
        // Production night bg is pure black (0.0/0.0/0.0)
        XCTAssertEqual(ReaderTheme.night.backgroundCSSHex, "#000000")
    }
}

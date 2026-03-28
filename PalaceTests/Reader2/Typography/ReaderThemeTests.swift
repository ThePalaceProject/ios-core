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
        let ids = Set(ReaderTheme.allCases.map(\.id))
        XCTAssertTrue(ids.contains("light"))
        XCTAssertTrue(ids.contains("sepia"))
        XCTAssertTrue(ids.contains("cream"))
        XCTAssertTrue(ids.contains("dark"))
        XCTAssertTrue(ids.contains("night"))
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
                            "Theme '\(theme.name)' should have a valid background color")
        }
    }

    // MARK: - Valid Text Colors

    func testAllThemes_haveValidTextColors() {
        for theme in ReaderTheme.allCases {
            XCTAssertNotNil(theme.textColor,
                            "Theme '\(theme.name)' should have a valid text color")
        }
    }

    // MARK: - CSS Hex Format

    func testAllThemes_haveCSSHexBackgrounds() {
        for theme in ReaderTheme.allCases {
            let hex = theme.cssBackgroundHex
            XCTAssertTrue(hex.hasPrefix("#"),
                          "CSS hex for '\(theme.name)' background should start with #")
            XCTAssertEqual(hex.count, 7,
                           "CSS hex for '\(theme.name)' background should be 7 chars (#RRGGBB)")
        }
    }

    func testAllThemes_haveCSSHexTextColors() {
        for theme in ReaderTheme.allCases {
            let hex = theme.cssTextHex
            XCTAssertTrue(hex.hasPrefix("#"),
                          "CSS hex for '\(theme.name)' text should start with #")
            XCTAssertEqual(hex.count, 7,
                           "CSS hex for '\(theme.name)' text should be 7 chars (#RRGGBB)")
        }
    }

    func testCSSHex_matchesExpectedFormat() {
        let hexPattern = try! NSRegularExpression(pattern: "^#[0-9A-Fa-f]{6}$")

        for theme in ReaderTheme.allCases {
            let bgRange = NSRange(theme.cssBackgroundHex.startIndex..., in: theme.cssBackgroundHex)
            XCTAssertNotNil(
                hexPattern.firstMatch(in: theme.cssBackgroundHex, range: bgRange),
                "Background hex '\(theme.cssBackgroundHex)' for '\(theme.name)' does not match #RRGGBB"
            )

            let txtRange = NSRange(theme.cssTextHex.startIndex..., in: theme.cssTextHex)
            XCTAssertNotNil(
                hexPattern.firstMatch(in: theme.cssTextHex, range: txtRange),
                "Text hex '\(theme.cssTextHex)' for '\(theme.name)' does not match #RRGGBB"
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

    func testCreamTheme_hasLightBackground() {
        XCTAssertFalse(ReaderTheme.cream.isDark,
                       "Cream theme should NOT be dark")
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
        XCTAssertGreaterThan(white, 0.7, "Night theme text should be light")
    }

    // MARK: - Codable Round-Trip

    func testCodable_roundTrip() throws {
        for theme in ReaderTheme.allCases {
            let data = try JSONEncoder().encode(theme)
            let decoded = try JSONDecoder().decode(ReaderTheme.self, from: data)
            XCTAssertEqual(decoded, theme,
                           "Codable round-trip failed for theme '\(theme.name)'")
        }
    }

    func testCodable_preservesAllProperties() throws {
        let theme = ReaderTheme.sepia
        let data = try JSONEncoder().encode(theme)
        let decoded = try JSONDecoder().decode(ReaderTheme.self, from: data)

        XCTAssertEqual(decoded.id, theme.id)
        XCTAssertEqual(decoded.name, theme.name)
        XCTAssertEqual(decoded.backgroundColorHex, theme.backgroundColorHex)
        XCTAssertEqual(decoded.textColorHex, theme.textColorHex)
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
        XCTAssertEqual(ReaderTheme.light.backgroundColorHex, "#FFFFFF")
        XCTAssertEqual(ReaderTheme.light.textColorHex, "#000000")
    }

    func testDarkTheme_darkBackground() {
        XCTAssertEqual(ReaderTheme.dark.backgroundColorHex, "#1E1E1E")
    }

    func testNightTheme_nearBlackBackground() {
        XCTAssertEqual(ReaderTheme.night.backgroundColorHex, "#0A0A0A")
    }
}

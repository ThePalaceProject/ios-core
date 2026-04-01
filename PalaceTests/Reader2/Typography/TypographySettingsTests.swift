//
//  TypographySettingsTests.swift
//  PalaceTests
//
//  Tests for TypographySettings initialization, Codable, ranges,
//  enums, and value semantics.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class TypographySettingsTests: XCTestCase {

    // MARK: - Default Initialization

    func testDefault_fontFamily() {
        XCTAssertEqual(TypographySettings.default.fontFamily, "Georgia")
    }

    func testDefault_fontSize() {
        XCTAssertEqual(TypographySettings.default.fontSize, 16.0, accuracy: 0.01)
    }

    func testDefault_lineSpacing() {
        XCTAssertEqual(TypographySettings.default.lineSpacing, 1.5, accuracy: 0.01)
    }

    func testDefault_margins() {
        XCTAssertEqual(TypographySettings.default.margins, .medium)
    }

    func testDefault_textAlignment() {
        XCTAssertEqual(TypographySettings.default.textAlignment, .left)
    }

    func testDefault_letterSpacing() {
        XCTAssertEqual(TypographySettings.default.letterSpacing, 0.0, accuracy: 0.01)
    }

    func testDefault_wordSpacing() {
        XCTAssertEqual(TypographySettings.default.wordSpacing, 0.0, accuracy: 0.01)
    }

    func testDefault_paragraphSpacing() {
        XCTAssertEqual(TypographySettings.default.paragraphSpacing, 0.0, accuracy: 0.01)
    }

    func testDefault_theme() {
        XCTAssertEqual(TypographySettings.default.theme, .light)
    }

    // MARK: - Codable Round-Trip

    func testCodable_roundTrip_defaultSettings() throws {
        let original = TypographySettings.default
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TypographySettings.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testCodable_roundTrip_customSettings() throws {
        let original = TypographySettings(
            fontFamily: "OpenDyslexic",
            fontSize: 24.0,
            lineSpacing: 2.5,
            margins: .extraLarge,
            textAlignment: .justified,
            letterSpacing: 0.2,
            wordSpacing: 0.5,
            paragraphSpacing: 1.0,
            theme: .dark
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TypographySettings.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testCodable_roundTrip_dyslexiaFriendlyPreset() throws {
        let original = TypographySettings.dyslexiaFriendly
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TypographySettings.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Value Ranges (Clamping)

    func testClamped_fontSizeBelowMinimum() {
        var settings = TypographySettings.default
        settings.fontSize = 5.0
        let clamped = settings.clamped()
        XCTAssertEqual(clamped.fontSize, TypographySettings.fontSizeRange.lowerBound)
    }

    func testClamped_fontSizeAboveMaximum() {
        var settings = TypographySettings.default
        settings.fontSize = 100.0
        let clamped = settings.clamped()
        XCTAssertEqual(clamped.fontSize, TypographySettings.fontSizeRange.upperBound)
    }

    func testClamped_lineSpacingBelowMinimum() {
        var settings = TypographySettings.default
        settings.lineSpacing = 0.5
        let clamped = settings.clamped()
        XCTAssertEqual(clamped.lineSpacing, TypographySettings.lineSpacingRange.lowerBound)
    }

    func testClamped_lineSpacingAboveMaximum() {
        var settings = TypographySettings.default
        settings.lineSpacing = 5.0
        let clamped = settings.clamped()
        XCTAssertEqual(clamped.lineSpacing, TypographySettings.lineSpacingRange.upperBound)
    }

    func testClamped_letterSpacingBelowMinimum() {
        var settings = TypographySettings.default
        settings.letterSpacing = -1.0
        let clamped = settings.clamped()
        XCTAssertEqual(clamped.letterSpacing, TypographySettings.letterSpacingRange.lowerBound)
    }

    func testClamped_wordSpacingAboveMaximum() {
        var settings = TypographySettings.default
        settings.wordSpacing = 5.0
        let clamped = settings.clamped()
        XCTAssertEqual(clamped.wordSpacing, TypographySettings.wordSpacingRange.upperBound)
    }

    func testClamped_paragraphSpacingAboveMaximum() {
        var settings = TypographySettings.default
        settings.paragraphSpacing = 10.0
        let clamped = settings.clamped()
        XCTAssertEqual(clamped.paragraphSpacing, TypographySettings.paragraphSpacingRange.upperBound)
    }

    func testClamped_withinRange_unchanged() {
        let settings = TypographySettings.default
        let clamped = settings.clamped()
        XCTAssertEqual(clamped, settings,
                       "Default settings are within range and should not change")
    }

    // MARK: - MarginLevel Enum

    func testMarginLevel_allCases() {
        XCTAssertEqual(MarginLevel.allCases.count, 5)
    }

    func testMarginLevel_rawValues() {
        XCTAssertEqual(MarginLevel.none.rawValue, 0)
        XCTAssertEqual(MarginLevel.small.rawValue, 1)
        XCTAssertEqual(MarginLevel.medium.rawValue, 2)
        XCTAssertEqual(MarginLevel.large.rawValue, 3)
        XCTAssertEqual(MarginLevel.extraLarge.rawValue, 4)
    }

    func testMarginLevel_cssValues() {
        XCTAssertEqual(MarginLevel.none.cssValue, "0em")
        XCTAssertEqual(MarginLevel.small.cssValue, "0.5em")
        XCTAssertEqual(MarginLevel.medium.cssValue, "1em")
        XCTAssertEqual(MarginLevel.large.cssValue, "2em")
        XCTAssertEqual(MarginLevel.extraLarge.cssValue, "3em")
    }

    func testMarginLevel_codableRoundTrip() throws {
        for level in MarginLevel.allCases {
            let data = try JSONEncoder().encode(level)
            let decoded = try JSONDecoder().decode(MarginLevel.self, from: data)
            XCTAssertEqual(decoded, level)
        }
    }

    // MARK: - TextAlignmentOption Enum

    func testTextAlignmentOption_allCases() {
        XCTAssertEqual(TextAlignmentOption.allCases.count, 4)
    }

    func testTextAlignmentOption_cssValues() {
        XCTAssertEqual(TextAlignmentOption.left.cssValue, "left")
        XCTAssertEqual(TextAlignmentOption.right.cssValue, "right")
        XCTAssertEqual(TextAlignmentOption.center.cssValue, "center")
        XCTAssertEqual(TextAlignmentOption.justified.cssValue, "justify")
    }

    func testTextAlignmentOption_codableRoundTrip() throws {
        for alignment in TextAlignmentOption.allCases {
            let data = try JSONEncoder().encode(alignment)
            let decoded = try JSONDecoder().decode(TextAlignmentOption.self, from: data)
            XCTAssertEqual(decoded, alignment)
        }
    }

    // MARK: - Equality

    func testEquality_sameSettingsAreEqual() {
        let a = TypographySettings.default
        let b = TypographySettings.default
        XCTAssertEqual(a, b)
    }

    func testEquality_differentSettingsAreNotEqual() {
        var modified = TypographySettings.default
        modified.fontSize = 24.0
        XCTAssertNotEqual(TypographySettings.default, modified)
    }

    func testEquality_differentThemeMeansNotEqual() {
        var modified = TypographySettings.default
        modified.theme = .dark
        XCTAssertNotEqual(TypographySettings.default, modified)
    }

    // MARK: - Copy-on-Write (Value Semantics)

    func testValueSemantics_modifyingCopyDoesNotAffectOriginal() {
        let original = TypographySettings.default
        var copy = original

        copy.fontFamily = "Helvetica"
        copy.fontSize = 24.0
        copy.lineSpacing = 2.0
        copy.margins = .extraLarge
        copy.textAlignment = .justified
        copy.letterSpacing = 0.3
        copy.wordSpacing = 0.5
        copy.paragraphSpacing = 1.5
        copy.theme = .night

        XCTAssertEqual(original.fontFamily, "Georgia")
        XCTAssertEqual(original.fontSize, 16.0)
        XCTAssertEqual(original.lineSpacing, 1.5)
        XCTAssertEqual(original.margins, .medium)
        XCTAssertEqual(original.textAlignment, .left)
        XCTAssertEqual(original.letterSpacing, 0.0)
        XCTAssertEqual(original.wordSpacing, 0.0)
        XCTAssertEqual(original.paragraphSpacing, 0.0)
        XCTAssertEqual(original.theme, .light)
    }

    // MARK: - Dyslexia-Friendly Preset

    func testDyslexiaFriendly_usesOpenDyslexicFont() {
        XCTAssertEqual(TypographySettings.dyslexiaFriendly.fontFamily, "OpenDyslexic")
    }

    func testDyslexiaFriendly_hasLargerFontSize() {
        XCTAssertGreaterThan(
            TypographySettings.dyslexiaFriendly.fontSize,
            TypographySettings.default.fontSize
        )
    }

    func testDyslexiaFriendly_hasWiderLineSpacing() {
        XCTAssertGreaterThan(
            TypographySettings.dyslexiaFriendly.lineSpacing,
            TypographySettings.default.lineSpacing
        )
    }

    func testDyslexiaFriendly_hasPositiveLetterSpacing() {
        XCTAssertGreaterThan(TypographySettings.dyslexiaFriendly.letterSpacing, 0.0)
    }

    func testDyslexiaFriendly_hasPositiveWordSpacing() {
        XCTAssertGreaterThan(TypographySettings.dyslexiaFriendly.wordSpacing, 0.0)
    }
}

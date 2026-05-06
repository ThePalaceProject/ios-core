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
        let defaults = TypographySettings.default
        XCTAssertEqual(defaults.fontFamily, "Georgia")
        // The default must be within the legal clamped range
        let clamped = defaults.clamped()
        XCTAssertEqual(clamped.fontFamily, defaults.fontFamily,
                       "Default fontFamily must survive clamping unchanged")
    }

    func testDefault_fontSize() {
        let defaults = TypographySettings.default
        XCTAssertEqual(defaults.fontSize, 16.0, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(defaults.fontSize, TypographySettings.fontSizeRange.lowerBound,
                                    "Default fontSize must be >= minimum")
        XCTAssertLessThanOrEqual(defaults.fontSize, TypographySettings.fontSizeRange.upperBound,
                                  "Default fontSize must be <= maximum")
    }

    func testDefault_lineSpacing() {
        let defaults = TypographySettings.default
        XCTAssertEqual(defaults.lineSpacing, 1.5, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(defaults.lineSpacing, TypographySettings.lineSpacingRange.lowerBound)
        XCTAssertLessThanOrEqual(defaults.lineSpacing, TypographySettings.lineSpacingRange.upperBound)
    }

    func testDefault_margins() {
        let defaults = TypographySettings.default
        XCTAssertEqual(defaults.margins, .medium)
        // Medium must not be the extremes
        XCTAssertNotEqual(defaults.margins, .none)
        XCTAssertNotEqual(defaults.margins, .extraLarge)
    }

    func testDefault_textAlignment() {
        let defaults = TypographySettings.default
        XCTAssertEqual(defaults.textAlignment, .left)
        // Verify the default CSS value is what EPUB readers expect
        XCTAssertEqual(defaults.textAlignment.cssValue, "left")
    }

    func testDefault_letterSpacing() {
        let defaults = TypographySettings.default
        XCTAssertEqual(defaults.letterSpacing, 0.0, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(defaults.letterSpacing, TypographySettings.letterSpacingRange.lowerBound)
    }

    func testDefault_wordSpacing() {
        let defaults = TypographySettings.default
        XCTAssertEqual(defaults.wordSpacing, 0.0, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(defaults.wordSpacing, TypographySettings.wordSpacingRange.lowerBound)
    }

    func testDefault_paragraphSpacing() {
        let defaults = TypographySettings.default
        XCTAssertEqual(defaults.paragraphSpacing, 0.0, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(defaults.paragraphSpacing, TypographySettings.paragraphSpacingRange.lowerBound)
    }

    func testDefault_theme() {
        let defaults = TypographySettings.default
        XCTAssertEqual(defaults.theme, .light)
        // Light theme must not be classified as dark
        XCTAssertFalse(defaults.theme.isDark, "Default theme must be a light theme")
    }

    // MARK: - Codable Round-Trip

    func testCodable_roundTrip_defaultSettings() throws {
        let original = TypographySettings.default
        let data = try JSONEncoder().encode(original)
        XCTAssertFalse(data.isEmpty, "Encoded default settings must not produce empty data")
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
        // Spot-check specific fields after round-trip
        XCTAssertEqual(decoded.fontSize, 24.0)
        XCTAssertEqual(decoded.theme, .dark)
    }

    func testCodable_roundTrip_dyslexiaFriendlyPreset() throws {
        let original = TypographySettings.dyslexiaFriendly
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TypographySettings.self, from: data)
        XCTAssertEqual(decoded, original)
        // OpenDyslexic font must survive the round-trip
        XCTAssertEqual(decoded.fontFamily, "OpenDyslexic",
                       "fontFamily must survive encode/decode for dyslexia preset")
    }

    // MARK: - Value Ranges (Clamping)

    func testClamped_fontSizeBelowMinimum() {
        var settings = TypographySettings.default
        settings.fontSize = 5.0
        let clamped = settings.clamped()
        XCTAssertEqual(clamped.fontSize, TypographySettings.fontSizeRange.lowerBound)
        // Other fields must not be affected by font size clamping
        XCTAssertEqual(clamped.theme, settings.theme)
    }

    func testClamped_fontSizeAboveMaximum() {
        var settings = TypographySettings.default
        settings.fontSize = 100.0
        let clamped = settings.clamped()
        XCTAssertEqual(clamped.fontSize, TypographySettings.fontSizeRange.upperBound)
        // Other fields must not be affected by font size clamping
        XCTAssertEqual(clamped.fontFamily, settings.fontFamily)
    }

    func testClamped_lineSpacingBelowMinimum() {
        var settings = TypographySettings.default
        settings.lineSpacing = 0.5
        let clamped = settings.clamped()
        XCTAssertEqual(clamped.lineSpacing, TypographySettings.lineSpacingRange.lowerBound)
        // fontSize must be unchanged by lineSpacing clamping
        XCTAssertEqual(clamped.fontSize, settings.fontSize)
    }

    func testClamped_lineSpacingAboveMaximum() {
        var settings = TypographySettings.default
        settings.lineSpacing = 5.0
        let clamped = settings.clamped()
        XCTAssertEqual(clamped.lineSpacing, TypographySettings.lineSpacingRange.upperBound)
        // Other fields must not be affected
        XCTAssertEqual(clamped.fontSize, settings.fontSize)
    }

    func testClamped_letterSpacingBelowMinimum() {
        var settings = TypographySettings.default
        settings.letterSpacing = -1.0
        let clamped = settings.clamped()
        XCTAssertEqual(clamped.letterSpacing, TypographySettings.letterSpacingRange.lowerBound)
        // Verify that clamping is an idempotent operation
        let doubly = clamped.clamped()
        XCTAssertEqual(doubly.letterSpacing, clamped.letterSpacing,
                       "Clamping an already-clamped value must be idempotent")
    }

    func testClamped_wordSpacingAboveMaximum() {
        var settings = TypographySettings.default
        settings.wordSpacing = 5.0
        let clamped = settings.clamped()
        XCTAssertEqual(clamped.wordSpacing, TypographySettings.wordSpacingRange.upperBound)
        // Verify that letterSpacing is unaffected
        XCTAssertEqual(clamped.letterSpacing, settings.letterSpacing)
    }

    func testClamped_paragraphSpacingAboveMaximum() {
        var settings = TypographySettings.default
        settings.paragraphSpacing = 10.0
        let clamped = settings.clamped()
        XCTAssertEqual(clamped.paragraphSpacing, TypographySettings.paragraphSpacingRange.upperBound)
        // Verify clamping does not affect wordSpacing
        XCTAssertEqual(clamped.wordSpacing, settings.wordSpacing)
    }

    func testClamped_withinRange_unchanged() {
        let settings = TypographySettings.default
        let clamped = settings.clamped()
        XCTAssertEqual(clamped, settings,
                       "Default settings are within range and should not change")
        // Applying clamped() again must be idempotent
        XCTAssertEqual(clamped.clamped(), clamped, "Clamping already-valid settings must be idempotent")
    }

    // MARK: - MarginLevel Enum

    func testMarginLevel_allCases() {
        XCTAssertEqual(MarginLevel.allCases.count, 5)
        // Verify all cases have distinct raw values (no duplicates)
        let rawValues = MarginLevel.allCases.map(\.rawValue)
        XCTAssertEqual(Set(rawValues).count, 5, "All MarginLevel raw values must be unique")
        // Verify all cases have distinct CSS values
        let cssValues = MarginLevel.allCases.map(\.cssValue)
        XCTAssertEqual(Set(cssValues).count, 5, "All MarginLevel CSS values must be unique")
    }

    func testMarginLevel_rawValues() {
        // Raw values must be strictly ordered: each level larger than the previous.
        // This ordering maps to progressively wider margins in the EPUB reader CSS.
        let levels = MarginLevel.allCases
        for i in 1..<levels.count {
            XCTAssertGreaterThan(levels[i].rawValue, levels[i-1].rawValue,
                                 "\(levels[i]) must have a higher rawValue than \(levels[i-1])")
        }
        // Raw values must be unique across all cases (no two levels share an index)
        let rawValues = levels.map(\.rawValue)
        XCTAssertEqual(Set(rawValues).count, levels.count, "All MarginLevel raw values must be unique")
        // none must have the smallest raw value (used as the initial/zero margin state)
        let minRaw = rawValues.min()!
        XCTAssertEqual(MarginLevel(rawValue: minRaw), .none, "The smallest raw value must correspond to .none")
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
            XCTAssertFalse(data.isEmpty, "Encoded data for MarginLevel.\(level) must not be empty")
            let decoded = try JSONDecoder().decode(MarginLevel.self, from: data)
            XCTAssertEqual(decoded, level)
        }
    }

    // MARK: - TextAlignmentOption Enum

    func testTextAlignmentOption_allCases() {
        XCTAssertEqual(TextAlignmentOption.allCases.count, 4)
        // Verify all cases have distinct CSS values so EPUB readers get unambiguous styling
        let cssValues = TextAlignmentOption.allCases.map(\.cssValue)
        XCTAssertEqual(Set(cssValues).count, 4, "All TextAlignmentOption CSS values must be unique")
        // Justified must produce "justify" for CSS standard compatibility
        XCTAssertEqual(TextAlignmentOption.justified.cssValue, "justify")
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
            XCTAssertFalse(data.isEmpty, "Encoded data for TextAlignmentOption.\(alignment) must not be empty")
            let decoded = try JSONDecoder().decode(TextAlignmentOption.self, from: data)
            XCTAssertEqual(decoded, alignment)
        }
    }

    // MARK: - Equality

    func testEquality_sameSettingsAreEqual() {
        let a = TypographySettings.default
        let b = TypographySettings.default
        XCTAssertEqual(a, b)
        // Reflexive: a must equal itself
        XCTAssertEqual(a, a)
        // Symmetric: if a == b then b == a
        XCTAssertEqual(b, a)
    }

    func testEquality_differentSettingsAreNotEqual() {
        var modified = TypographySettings.default
        modified.fontSize = 24.0
        XCTAssertNotEqual(TypographySettings.default, modified)
        // Restoring the original value makes them equal again
        modified.fontSize = TypographySettings.default.fontSize
        XCTAssertEqual(TypographySettings.default, modified,
                       "Restoring fontSize to default should make settings equal again")
    }

    func testEquality_differentThemeMeansNotEqual() {
        var modified = TypographySettings.default
        modified.theme = .dark
        XCTAssertNotEqual(TypographySettings.default, modified)
        // Each available theme produces a distinct settings inequality
        modified.theme = .sepia
        XCTAssertNotEqual(TypographySettings.default, modified,
                          "Sepia theme must also differ from the default light theme")
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
        let preset = TypographySettings.dyslexiaFriendly
        XCTAssertEqual(preset.fontFamily, "OpenDyslexic")
        // The font family must survive clamping
        XCTAssertEqual(preset.clamped().fontFamily, "OpenDyslexic")
    }

    func testDyslexiaFriendly_hasLargerFontSize() {
        let preset = TypographySettings.dyslexiaFriendly
        XCTAssertGreaterThan(preset.fontSize, TypographySettings.default.fontSize)
        // Must still be within the allowed range
        XCTAssertLessThanOrEqual(preset.fontSize, TypographySettings.fontSizeRange.upperBound)
    }

    func testDyslexiaFriendly_hasWiderLineSpacing() {
        let preset = TypographySettings.dyslexiaFriendly
        XCTAssertGreaterThan(preset.lineSpacing, TypographySettings.default.lineSpacing)
        // Must still be within the allowed range
        XCTAssertLessThanOrEqual(preset.lineSpacing, TypographySettings.lineSpacingRange.upperBound)
    }

    func testDyslexiaFriendly_hasPositiveLetterSpacing() {
        let preset = TypographySettings.dyslexiaFriendly
        XCTAssertGreaterThan(preset.letterSpacing, 0.0)
        // Must still be within the allowed range
        XCTAssertLessThanOrEqual(preset.letterSpacing, TypographySettings.letterSpacingRange.upperBound)
    }

    func testDyslexiaFriendly_hasPositiveWordSpacing() {
        let preset = TypographySettings.dyslexiaFriendly
        XCTAssertGreaterThan(preset.wordSpacing, 0.0)
        // Must still be within the allowed range
        XCTAssertLessThanOrEqual(preset.wordSpacing, TypographySettings.wordSpacingRange.upperBound)
    }
}

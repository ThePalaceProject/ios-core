//
//  TypographyPresetTests.swift
//  PalaceTests
//
//  Tests that all built-in presets produce valid CSS.
//

import XCTest
@testable import Palace

@MainActor
final class TypographyPresetTests: XCTestCase {

    private var service: TypographyService!
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: "TypographyPresetTests")!
        testDefaults.removePersistentDomain(forName: "TypographyPresetTests")
        service = TypographyService(userDefaults: testDefaults)
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: "TypographyPresetTests")
        testDefaults = nil
        service = nil
        super.tearDown()
    }

    // MARK: - All Presets Produce Valid CSS

    func testAllPresetsProduceCSS() {
        for preset in TypographyPreset.allPresets {
            let css = service.css(for: preset.typographySettings)
            XCTAssertFalse(css.isEmpty, "Preset \(preset.name) should produce non-empty CSS")
            XCTAssertTrue(css.contains("font-family:"), "Preset \(preset.name) CSS should contain font-family")
            XCTAssertTrue(css.contains("font-size:"), "Preset \(preset.name) CSS should contain font-size")
            XCTAssertTrue(css.contains("line-height:"), "Preset \(preset.name) CSS should contain line-height")
            XCTAssertTrue(css.contains("background-color:"), "Preset \(preset.name) CSS should contain background-color")
            XCTAssertTrue(css.contains("color:"), "Preset \(preset.name) CSS should contain text color")
            XCTAssertTrue(css.contains("text-align:"), "Preset \(preset.name) CSS should contain text-align")
            XCTAssertTrue(css.contains("word-spacing:"), "Preset \(preset.name) CSS should contain word-spacing")
            XCTAssertTrue(css.contains("letter-spacing:"), "Preset \(preset.name) CSS should contain letter-spacing")
            XCTAssertTrue(css.contains("margin-left:"), "Preset \(preset.name) CSS should contain margin-left")
            XCTAssertTrue(css.contains("margin-right:"), "Preset \(preset.name) CSS should contain margin-right")
        }
    }

    // MARK: - Preset Identity

    func testPresetsHaveUniqueIds() {
        let ids = TypographyPreset.allPresets.map { $0.id }
        let uniqueIds = Set(ids)
        XCTAssertEqual(ids.count, uniqueIds.count, "All preset IDs should be unique")
    }

    func testPresetsHaveUniqueNames() {
        let names = TypographyPreset.allPresets.map { $0.name }
        let uniqueNames = Set(names)
        XCTAssertEqual(names.count, uniqueNames.count, "All preset names should be unique")
    }

    func testPresetCount() {
        XCTAssertEqual(TypographyPreset.allPresets.count, 6, "Should have 6 built-in presets")
    }

    func testPresetLookupById() {
        for preset in TypographyPreset.allPresets {
            let found = TypographyPreset.preset(for: preset.id)
            XCTAssertNotNil(found, "Should find preset by ID: \(preset.id)")
            XCTAssertEqual(found?.name, preset.name)
        }
    }

    func testPresetLookupByInvalidId() {
        XCTAssertNil(TypographyPreset.preset(for: "nonexistent"))
    }

    // MARK: - Individual Preset Configurations

    func testClassicPreset() {
        let settings = TypographyPreset.classic.typographySettings
        XCTAssertEqual(settings.fontFamily, .georgia)
        XCTAssertEqual(settings.textAlignment, .justified)
        XCTAssertEqual(settings.theme, .light)
        XCTAssertEqual(settings.presetIdentifier, "classic")
    }

    func testModernPreset() {
        let settings = TypographyPreset.modern.typographySettings
        XCTAssertEqual(settings.fontFamily, .sfPro)
        XCTAssertEqual(settings.textAlignment, .left)
        XCTAssertTrue(settings.lineSpacing < TypographyPreset.classic.settings.lineSpacing,
                       "Modern should have tighter line spacing than Classic")
    }

    func testCozyPreset() {
        let settings = TypographyPreset.cozy.typographySettings
        XCTAssertEqual(settings.fontFamily, .palatino)
        XCTAssertEqual(settings.marginLevel, .wide)
        XCTAssertTrue(settings.fontSize > TypographyPreset.classic.settings.fontSize,
                       "Cozy should have larger font than Classic")
        XCTAssertTrue(settings.lineSpacing > TypographyPreset.classic.settings.lineSpacing,
                       "Cozy should have more line spacing than Classic")
    }

    func testDensePreset() {
        let settings = TypographyPreset.dense.typographySettings
        XCTAssertEqual(settings.fontFamily, .helveticaNeue)
        XCTAssertEqual(settings.marginLevel, .narrow)
        XCTAssertTrue(settings.fontSize < TypographyPreset.classic.settings.fontSize,
                       "Dense should have smaller font than Classic")
        XCTAssertTrue(settings.lineSpacing < TypographyPreset.classic.settings.lineSpacing,
                       "Dense should have tighter line spacing than Classic")
    }

    func testDyslexiaFriendlyPreset() {
        let settings = TypographyPreset.dyslexiaFriendly.typographySettings
        XCTAssertEqual(settings.fontFamily, .openDyslexic)
        XCTAssertEqual(settings.textAlignment, .left, "Dyslexia-friendly should be left-aligned")
        XCTAssertTrue(settings.wordSpacing > 0, "Dyslexia-friendly should have extra word spacing")
        XCTAssertTrue(settings.letterSpacing > 0, "Dyslexia-friendly should have extra letter spacing")
        XCTAssertTrue(settings.lineSpacing >= 1.8, "Dyslexia-friendly should have generous line spacing")
    }

    func testNightReaderPreset() {
        let settings = TypographyPreset.nightReader.typographySettings
        XCTAssertEqual(settings.theme, .night, "Night Reader should use night theme")
        XCTAssertTrue(settings.fontSize >= 18, "Night Reader should have slightly larger text")
    }

    // MARK: - Preset Settings Codability

    func testPresetSettingsAreCodable() throws {
        for preset in TypographyPreset.allPresets {
            let settings = preset.typographySettings
            let data = try JSONEncoder().encode(settings)
            let decoded = try JSONDecoder().decode(TypographySettings.self, from: data)
            XCTAssertEqual(settings, decoded, "Preset \(preset.name) settings should survive encode/decode")
        }
    }

    // MARK: - CSS Content Validation

    func testClassicCSSContainsGeorgia() {
        let css = service.css(for: TypographyPreset.classic.typographySettings)
        XCTAssertTrue(css.contains("Georgia"))
    }

    func testModernCSSContainsSFPro() {
        let css = service.css(for: TypographyPreset.modern.typographySettings)
        XCTAssertTrue(css.contains("-apple-system") || css.contains("SF Pro"))
    }

    func testDyslexiaCSSContainsOpenDyslexic() {
        let css = service.css(for: TypographyPreset.dyslexiaFriendly.typographySettings)
        XCTAssertTrue(css.contains("OpenDyslexic"))
    }

    func testNightReaderCSSHasBlackBackground() {
        let css = service.css(for: TypographyPreset.nightReader.typographySettings)
        XCTAssertTrue(css.contains("#000000"), "Night Reader should have black background")
    }

    // MARK: - Font Size Ranges

    func testAllPresetFontSizesInRange() {
        for preset in TypographyPreset.allPresets {
            let size = preset.settings.fontSize
            XCTAssertGreaterThanOrEqual(size, TypographySettings.minFontSize,
                                        "Preset \(preset.name) font size should be >= min")
            XCTAssertLessThanOrEqual(size, TypographySettings.maxFontSize,
                                     "Preset \(preset.name) font size should be <= max")
        }
    }

    func testAllPresetLineSpacingsInRange() {
        for preset in TypographyPreset.allPresets {
            let spacing = preset.settings.lineSpacing
            XCTAssertGreaterThanOrEqual(spacing, TypographySettings.minLineSpacing,
                                        "Preset \(preset.name) line spacing should be >= min")
            XCTAssertLessThanOrEqual(spacing, TypographySettings.maxLineSpacing,
                                     "Preset \(preset.name) line spacing should be <= max")
        }
    }

    func testAllPresetWordSpacingsInRange() {
        for preset in TypographyPreset.allPresets {
            let spacing = preset.settings.wordSpacing
            XCTAssertGreaterThanOrEqual(spacing, TypographySettings.minWordSpacing)
            XCTAssertLessThanOrEqual(spacing, TypographySettings.maxWordSpacing)
        }
    }

    func testAllPresetLetterSpacingsInRange() {
        for preset in TypographyPreset.allPresets {
            let spacing = preset.settings.letterSpacing
            XCTAssertGreaterThanOrEqual(spacing, TypographySettings.minLetterSpacing)
            XCTAssertLessThanOrEqual(spacing, TypographySettings.maxLetterSpacing)
        }
    }
}

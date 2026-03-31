//
//  TypographyServiceTests.swift
//  PalaceTests
//
//  Tests for TypographyService: CSS generation, persistence, preset loading.
//

import XCTest
import Combine
@testable import Palace

@MainActor
final class TypographyServiceTests: XCTestCase {

    private var service: TypographyService!
    private var testDefaults: UserDefaults!
    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: "TypographyServiceTests")!
        testDefaults.removePersistentDomain(forName: "TypographyServiceTests")
        service = TypographyService(userDefaults: testDefaults)
        cancellables = []
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: "TypographyServiceTests")
        testDefaults = nil
        service = nil
        cancellables = nil
        super.tearDown()
    }

    // MARK: - Initial State

    func testDefaultSettingsLoadClassicPreset() {
        // With no persisted data, service should load classic preset
        let settings = service.currentSettings
        XCTAssertEqual(settings.presetIdentifier, "classic")
        XCTAssertEqual(settings.fontFamily, .georgia)
        XCTAssertEqual(settings.theme, .light)
    }

    // MARK: - CSS Generation

    func testCSSContainsFontFamily() {
        let css = service.cssForCurrentSettings()
        XCTAssertTrue(css.contains("Georgia"), "CSS should contain the font family name")
        XCTAssertTrue(css.contains("font-family:"), "CSS should have font-family property")
    }

    func testCSSContainsBackgroundColor() {
        let css = service.cssForCurrentSettings()
        XCTAssertTrue(css.contains("background-color:"), "CSS should set background color")
    }

    func testCSSContainsFontSize() {
        service.updateFontSize(24)
        let css = service.cssForCurrentSettings()
        XCTAssertTrue(css.contains("24px"), "CSS should contain the font size")
    }

    func testCSSContainsLineSpacing() {
        service.updateLineSpacing(1.8)
        let css = service.cssForCurrentSettings()
        XCTAssertTrue(css.contains("1.80"), "CSS should contain line-height value")
    }

    func testCSSContainsTextAlignment() {
        service.updateTextAlignment(.justified)
        let css = service.cssForCurrentSettings()
        XCTAssertTrue(css.contains("text-align: justify"), "CSS should contain justified alignment")
    }

    func testCSSContainsLetterSpacing() {
        service.updateLetterSpacing(1.5)
        let css = service.cssForCurrentSettings()
        XCTAssertTrue(css.contains("letter-spacing:"), "CSS should contain letter-spacing")
        XCTAssertTrue(css.contains("1.50"), "CSS should contain the letter spacing value")
    }

    func testCSSContainsWordSpacing() {
        service.updateWordSpacing(3.0)
        let css = service.cssForCurrentSettings()
        XCTAssertTrue(css.contains("word-spacing:"), "CSS should contain word-spacing")
        XCTAssertTrue(css.contains("3.0"), "CSS should contain the word spacing value")
    }

    func testCSSContainsMargins() {
        service.updateMarginLevel(.wide)
        let css = service.cssForCurrentSettings()
        XCTAssertTrue(css.contains("margin-left:"), "CSS should set left margin")
        XCTAssertTrue(css.contains("margin-right:"), "CSS should set right margin")
        XCTAssertTrue(css.contains("10.0%"), "CSS should contain wide margin percentage")
    }

    func testCSSContainsParagraphSpacing() {
        service.updateParagraphSpacing(20)
        let css = service.cssForCurrentSettings()
        XCTAssertTrue(css.contains("margin-bottom: 20px"), "CSS should set paragraph spacing")
    }

    func testCSSForDarkTheme() {
        service.updateTheme(.night)
        let css = service.cssForCurrentSettings()
        XCTAssertTrue(css.contains("#000000"), "Night theme should have black background")
    }

    func testCSSForSepiaTheme() {
        service.updateTheme(.sepia)
        let css = service.cssForCurrentSettings()
        // Sepia background should not be pure white or black
        XCTAssertFalse(css.contains("background-color: #FFFFFF"), "Sepia should not be white")
        XCTAssertFalse(css.contains("background-color: #000000"), "Sepia should not be black")
    }

    func testCSSEnablesHyphensForJustifiedText() {
        service.updateTextAlignment(.justified)
        let css = service.cssForCurrentSettings()
        XCTAssertTrue(css.contains("-webkit-hyphens: auto"), "Justified text should enable hyphens")
    }

    func testCSSDisablesHyphensForLeftAligned() {
        service.updateTextAlignment(.left)
        let css = service.cssForCurrentSettings()
        XCTAssertTrue(css.contains("-webkit-hyphens: none"), "Left-aligned text should disable hyphens")
    }

    func testCSSForArbitrarySettings() {
        let settings = TypographySettings(
            fontFamily: .avenir,
            fontSize: 22,
            lineSpacing: 2.0,
            marginLevel: .extraWide,
            paragraphSpacing: 20,
            textAlignment: .justified,
            wordSpacing: 2,
            letterSpacing: 0.5,
            theme: .dark
        )
        let css = service.css(for: settings)
        XCTAssertTrue(css.contains("Avenir"), "CSS should contain Avenir font family")
        XCTAssertTrue(css.contains("22px"), "CSS should contain 22px font size")
        XCTAssertTrue(css.contains("15.0%"), "CSS should contain extra-wide margin")
    }

    // MARK: - Individual Updates

    func testUpdateFontFamily() {
        service.updateFontFamily(.palatino)
        XCTAssertEqual(service.currentSettings.fontFamily, .palatino)
        XCTAssertNil(service.currentSettings.presetIdentifier, "Custom change should clear preset")
    }

    func testUpdateFontSizeClampsToRange() {
        service.updateFontSize(100)
        XCTAssertEqual(service.currentSettings.fontSize, TypographySettings.maxFontSize)

        service.updateFontSize(1)
        XCTAssertEqual(service.currentSettings.fontSize, TypographySettings.minFontSize)
    }

    func testUpdateLineSpacingClampsToRange() {
        service.updateLineSpacing(10)
        XCTAssertEqual(service.currentSettings.lineSpacing, TypographySettings.maxLineSpacing)

        service.updateLineSpacing(0.1)
        XCTAssertEqual(service.currentSettings.lineSpacing, TypographySettings.minLineSpacing)
    }

    func testUpdateMarginLevel() {
        service.updateMarginLevel(.extraWide)
        XCTAssertEqual(service.currentSettings.marginLevel, .extraWide)
    }

    func testUpdateParagraphSpacing() {
        service.updateParagraphSpacing(25)
        XCTAssertEqual(service.currentSettings.paragraphSpacing, 25)
    }

    func testUpdateTextAlignment() {
        service.updateTextAlignment(.justified)
        XCTAssertEqual(service.currentSettings.textAlignment, .justified)
    }

    func testUpdateWordSpacingClampsToRange() {
        service.updateWordSpacing(100)
        XCTAssertEqual(service.currentSettings.wordSpacing, TypographySettings.maxWordSpacing)
    }

    func testUpdateLetterSpacingClampsToRange() {
        service.updateLetterSpacing(-10)
        XCTAssertEqual(service.currentSettings.letterSpacing, TypographySettings.minLetterSpacing)
    }

    func testUpdateTheme() {
        service.updateTheme(.solarized)
        XCTAssertEqual(service.currentSettings.theme, .solarized)
    }

    // MARK: - Preset Application

    func testApplyPreset() {
        service.applyPreset(.nightReader)
        XCTAssertEqual(service.currentSettings.presetIdentifier, "night-reader")
        XCTAssertEqual(service.currentSettings.fontFamily, .newYork)
        XCTAssertEqual(service.currentSettings.theme, .night)
    }

    func testApplyPresetClearsPreviousCustomization() {
        service.updateFontSize(30) // Custom change
        XCTAssertNil(service.currentSettings.presetIdentifier)

        service.applyPreset(.modern)
        XCTAssertEqual(service.currentSettings.presetIdentifier, "modern")
        XCTAssertEqual(service.currentSettings.fontSize, 17)
    }

    func testResetToPresetRestoresOriginal() {
        service.applyPreset(.cozy)
        let originalSize = service.currentSettings.fontSize
        service.updateFontSize(30)
        XCTAssertNotEqual(service.currentSettings.fontSize, originalSize)

        // Reset still works because presetIdentifier was cleared
        service.resetToPreset()
        // With no preset identifier, resets to classic
        XCTAssertEqual(service.currentSettings.presetIdentifier, "classic")
    }

    func testResetToPresetWithNoPresetResetsToClassic() {
        service.updateFontFamily(.avenir)
        service.resetToPreset()
        XCTAssertEqual(service.currentSettings.presetIdentifier, "classic")
        XCTAssertEqual(service.currentSettings.fontFamily, .georgia)
    }

    // MARK: - Persistence

    func testSettingsPersistedAfterDebounce() {
        let expectation = expectation(description: "Settings persisted")

        service.updateFontSize(28)

        // Wait for debounce (500ms + buffer)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            let reloaded = TypographyService(userDefaults: self.testDefaults)
            XCTAssertEqual(reloaded.currentSettings.fontSize, 28, "Font size should be persisted")
            expectation.fulfill()
        }

        waitForExpectations(timeout: 2)
    }

    func testSettingsPublisherEmitsOnChange() {
        var receivedSettings: [TypographySettings] = []
        let expectation = expectation(description: "Received settings update")

        service.settingsPublisher
            .dropFirst() // Skip initial value
            .prefix(1)
            .sink { settings in
                receivedSettings.append(settings)
                expectation.fulfill()
            }
            .store(in: &cancellables)

        service.updateFontSize(24)

        waitForExpectations(timeout: 1)
        XCTAssertEqual(receivedSettings.count, 1)
        XCTAssertEqual(receivedSettings.first?.fontSize, 24)
    }

    // MARK: - Full Settings Update

    func testUpdateSettingsReplacesAll() {
        let custom = TypographySettings(
            fontFamily: .timesNewRoman,
            fontSize: 30,
            lineSpacing: 2.5,
            marginLevel: .extraWide,
            paragraphSpacing: 25,
            textAlignment: .justified,
            wordSpacing: 4,
            letterSpacing: 1.5,
            theme: .solarized,
            presetIdentifier: nil
        )
        service.updateSettings(custom)
        XCTAssertEqual(service.currentSettings, custom)
    }
}

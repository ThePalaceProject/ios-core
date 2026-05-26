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
        // For the default light theme the background should be white (#FFFFFF)
        XCTAssertTrue(css.contains("#FFFFFF") || css.contains("rgb(255"),
                      "Default light theme CSS should specify a white background")
    }

    func testCSSContainsFontSize() {
        service.updateFontSize(24)
        let css = service.cssForCurrentSettings()
        XCTAssertTrue(css.contains("24px"), "CSS should contain the font size")
        // Changing font size again must update the CSS
        service.updateFontSize(18)
        let updatedCSS = service.cssForCurrentSettings()
        XCTAssertTrue(updatedCSS.contains("18px"), "CSS should reflect the new font size")
        XCTAssertFalse(updatedCSS.contains("24px"), "Old font size should not appear in updated CSS")
    }

    func testCSSContainsLineSpacing() {
        service.updateLineSpacing(1.8)
        let css = service.cssForCurrentSettings()
        XCTAssertTrue(css.contains("1.80"), "CSS should contain line-height value")
        // Line-height property name must also be present
        XCTAssertTrue(css.contains("line-height:"), "CSS must include line-height property")
    }

    func testCSSContainsTextAlignment() {
        service.updateTextAlignment(.justified)
        let css = service.cssForCurrentSettings()
        XCTAssertTrue(css.contains("text-align: justify"), "CSS should contain justified alignment")
        // Justified alignment must also enable hyphens
        XCTAssertTrue(css.contains("hyphens"), "Justified text CSS should enable hyphens")
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
        // Resetting to 0 still emits the paragraph rule (the CSS template always includes it)
        service.updateParagraphSpacing(0)
        let zeroCSS = service.cssForCurrentSettings()
        XCTAssertTrue(zeroCSS.contains("margin-bottom: 0px"), "Zero spacing should emit margin-bottom: 0px")
    }

    func testCSSForDarkTheme() {
        service.updateTheme(.night)
        let css = service.cssForCurrentSettings()
        XCTAssertTrue(css.contains("#000000"), "Night theme should have black background")
        // Text color in night theme should be white or near-white
        XCTAssertTrue(css.contains("color:"), "Night theme CSS must specify a text color")
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
        XCTAssertTrue(css.contains("hyphens: auto"), "Justified text should also set the non-webkit hyphens property")
    }

    func testCSSDisablesHyphensForLeftAligned() {
        service.updateTextAlignment(.left)
        let css = service.cssForCurrentSettings()
        XCTAssertTrue(css.contains("-webkit-hyphens: none"), "Left-aligned text should disable hyphens")
        // Non-webkit hyphens property should also be disabled
        XCTAssertTrue(css.contains("hyphens: none"), "Non-webkit hyphens must also be disabled for left alignment")
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
        // Preset identifier should be cleared on custom change
        XCTAssertNil(service.currentSettings.presetIdentifier, "Custom margin change should clear preset")
        // CSS should reflect the new margin
        let css = service.cssForCurrentSettings()
        XCTAssertTrue(css.contains("margin"), "CSS must contain margin after level change")
    }

    func testUpdateParagraphSpacing() {
        service.updateParagraphSpacing(25)
        XCTAssertEqual(service.currentSettings.paragraphSpacing, 25)
        // CSS must include the new paragraph spacing
        let css = service.cssForCurrentSettings()
        XCTAssertTrue(css.contains("25px") || css.contains("25.0"),
                      "CSS should contain the updated paragraph spacing value")
    }

    func testUpdateTextAlignment() {
        service.updateTextAlignment(.justified)
        XCTAssertEqual(service.currentSettings.textAlignment, .justified)
        // Justified text must enable hyphenation in CSS
        let css = service.cssForCurrentSettings()
        XCTAssertTrue(css.contains("justify"), "CSS must contain 'justify' for justified alignment")
    }

    func testUpdateWordSpacingClampsToRange() {
        service.updateWordSpacing(100)
        XCTAssertEqual(service.currentSettings.wordSpacing, TypographySettings.maxWordSpacing)
        // Verify below-min is also clamped
        service.updateWordSpacing(-100)
        XCTAssertEqual(service.currentSettings.wordSpacing, TypographySettings.minWordSpacing)
    }

    func testUpdateLetterSpacingClampsToRange() {
        service.updateLetterSpacing(-10)
        XCTAssertEqual(service.currentSettings.letterSpacing, TypographySettings.minLetterSpacing)
        // Verify above-max is also clamped
        service.updateLetterSpacing(1000)
        XCTAssertEqual(service.currentSettings.letterSpacing, TypographySettings.maxLetterSpacing)
    }

    func testUpdateTheme() {
        service.updateTheme(.solarized)
        XCTAssertEqual(service.currentSettings.theme, .solarized)
        // Preset identifier should be cleared on custom change
        XCTAssertNil(service.currentSettings.presetIdentifier, "Custom theme change should clear preset")
        // CSS must change to reflect the solarized theme
        let css = service.cssForCurrentSettings()
        XCTAssertTrue(css.contains("background-color:"), "CSS must set background-color for theme")
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
        // Capture into a local so the predicate block doesn't reach back through
        // self.testDefaults — under CI load the predicate can fire after tearDown
        // has already nulled the implicitly-unwrapped optional, crashing the
        // next test that's running. The captured local keeps UserDefaults alive
        // for the predicate's lifetime.
        let capturedDefaults = testDefaults!
        service.updateFontSize(28)

        // Poll the persisted value rather than guess at debounce + scheduling
        // drift. The previous fixed-700ms wait raced the 500ms debounce on
        // RunLoop.main and intermittently read the default 18pt back on loaded
        // CI runners (the main run loop can be starved past the debounce
        // deadline). Polling lets the test pass as soon as the value lands.
        let predicate = NSPredicate { _, _ in
            let reloaded = TypographyService(userDefaults: capturedDefaults)
            return reloaded.currentSettings.fontSize == 28
        }
        wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 5.0)

        let reloaded = TypographyService(userDefaults: capturedDefaults)
        XCTAssertEqual(reloaded.currentSettings.fontSize, 28, "Font size should be persisted")
        XCTAssertEqual(reloaded.currentSettings.fontFamily, .georgia,
                       "Default fontFamily should be preserved alongside the changed fontSize")
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
        // Verify each field individually so that a regression is clearly identified
        XCTAssertEqual(service.currentSettings.fontFamily, .timesNewRoman)
        XCTAssertEqual(service.currentSettings.fontSize, 30)
        XCTAssertEqual(service.currentSettings.theme, .solarized)
    }
}

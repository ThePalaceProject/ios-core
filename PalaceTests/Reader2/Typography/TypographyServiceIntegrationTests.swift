//
//  TypographyServiceIntegrationTests.swift
//  PalaceTests
//
//  Tests for TypographyService CSS generation, setting updates,
//  publisher emissions, and debounced persistence.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import XCTest
@testable import Palace

// MARK: - Mock Persistence

private final class MockTypographyPersistence: TypographyPersistence {
    private(set) var savedSettings: TypographySettings?
    private(set) var saveCallCount = 0
    var storedSettings: TypographySettings?

    func save(_ settings: TypographySettings) {
        savedSettings = settings
        saveCallCount += 1
    }

    func load() -> TypographySettings? {
        return storedSettings
    }
}

// MARK: - Tests

@MainActor
final class TypographyServiceIntegrationTests: XCTestCase {

    private var persistence: MockTypographyPersistence!
    private var service: TypographyService!
    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        persistence = MockTypographyPersistence()
        cancellables = []
    }

    override func tearDown() {
        cancellables = nil
        service = nil
        persistence = nil
        super.tearDown()
    }

    // MARK: - CSS for Default Settings

    func testCSSForCurrentSettings_defaultSettings_producesValidCSS() {
        service = makeService()
        let css = service.cssForCurrentSettings()

        XCTAssertFalse(css.isEmpty, "CSS should not be empty")
        XCTAssertTrue(css.contains("body {"), "CSS should contain body selector")
        XCTAssertTrue(css.contains("font-family"), "CSS should contain font-family")
        XCTAssertTrue(css.contains("font-size"), "CSS should contain font-size")
        XCTAssertTrue(css.contains("line-height"), "CSS should contain line-height")
        XCTAssertTrue(css.contains("margin"), "CSS should contain margin")
        XCTAssertTrue(css.contains("text-align"), "CSS should contain text-align")
        XCTAssertTrue(css.contains("letter-spacing"), "CSS should contain letter-spacing")
        XCTAssertTrue(css.contains("word-spacing"), "CSS should contain word-spacing")
    }

    func testCSSForCurrentSettings_includesAllProperties() {
        service = makeService()
        let css = service.cssForCurrentSettings()

        XCTAssertTrue(css.contains("font-family:"), "Missing font-family")
        XCTAssertTrue(css.contains("font-size:"), "Missing font-size")
        XCTAssertTrue(css.contains("line-height:"), "Missing line-height")
        XCTAssertTrue(css.contains("margin:"), "Missing margin")
        XCTAssertTrue(css.contains("text-align:"), "Missing text-align")
        XCTAssertTrue(css.contains("letter-spacing:"), "Missing letter-spacing")
        XCTAssertTrue(css.contains("word-spacing:"), "Missing word-spacing")
        XCTAssertTrue(css.contains("color:"), "Missing text color")
        XCTAssertTrue(css.contains("background-color:"), "Missing background-color")
    }

    // MARK: - CSS Changes with Font Family

    func testCSS_changesWhenFontFamilyChanges() {
        service = makeService()
        let cssBefore = service.cssForCurrentSettings()

        service.updateFontFamily("Helvetica")
        let cssAfter = service.cssForCurrentSettings()

        XCTAssertNotEqual(cssBefore, cssAfter,
                          "CSS should change when font family changes")
        XCTAssertTrue(cssAfter.contains("Helvetica"),
                      "CSS should contain new font family")
    }

    // MARK: - CSS Changes with Theme

    func testCSS_changesWhenThemeChanges() {
        service = makeService()
        let cssBefore = service.cssForCurrentSettings()

        service.updateTheme(.dark)
        let cssAfter = service.cssForCurrentSettings()

        XCTAssertNotEqual(cssBefore, cssAfter,
                          "CSS should change when theme changes")
        XCTAssertTrue(cssAfter.contains(ReaderTheme.dark.cssBackgroundHex),
                      "CSS should contain dark theme background hex")
    }

    // MARK: - CSS Changes with Multiple Settings

    func testCSS_changesWhenMultipleSettingsChange() {
        service = makeService()
        let cssBefore = service.cssForCurrentSettings()

        service.updateFontFamily("Courier")
        service.updateFontSize(24.0)
        service.updateLineSpacing(2.0)
        let cssAfter = service.cssForCurrentSettings()

        XCTAssertNotEqual(cssBefore, cssAfter)
        XCTAssertTrue(cssAfter.contains("Courier"))
        XCTAssertTrue(cssAfter.contains("24.0"))
        XCTAssertTrue(cssAfter.contains("2.0"))
    }

    // MARK: - Dyslexia-Friendly CSS

    func testCSS_dyslexiaFriendlyPreset_includesOpenDyslexic() {
        service = makeService()
        service.applySettings(.dyslexiaFriendly)

        let css = service.cssForCurrentSettings()

        XCTAssertTrue(css.contains("OpenDyslexic"),
                      "Dyslexia-friendly CSS should include OpenDyslexic font")
    }

    // MARK: - Justified Alignment Includes Hyphens

    func testCSS_justifiedAlignment_includesHyphenSettings() {
        service = makeService()
        service.updateTextAlignment(.justified)

        let css = service.cssForCurrentSettings()

        XCTAssertTrue(css.contains("hyphens: auto"),
                      "Justified text should include hyphen settings")
        XCTAssertTrue(css.contains("-webkit-hyphens: auto"),
                      "Justified text should include webkit hyphen settings")
    }

    func testCSS_nonJustifiedAlignment_doesNotIncludeHyphens() {
        service = makeService()
        service.updateTextAlignment(.left)

        let css = service.cssForCurrentSettings()

        XCTAssertFalse(css.contains("hyphens"),
                       "Non-justified text should not include hyphen settings")
    }

    // MARK: - Paragraph Spacing in CSS

    func testCSS_withParagraphSpacing_includesParagraphRule() {
        service = makeService()
        service.updateParagraphSpacing(1.5)

        let css = service.cssForCurrentSettings()

        XCTAssertTrue(css.contains("p {"), "Should include paragraph CSS rule")
        XCTAssertTrue(css.contains("margin-bottom: 1.5em"),
                      "Should include paragraph spacing value")
    }

    func testCSS_withZeroParagraphSpacing_omitsParagraphRule() {
        service = makeService()
        service.updateParagraphSpacing(0.0)

        let css = service.cssForCurrentSettings()

        XCTAssertFalse(css.contains("p {"),
                       "Should not include paragraph rule when spacing is 0")
    }

    // MARK: - Settings Publisher

    func testSettingsPublisher_emitsOnFontFamilyChange() {
        service = makeService()
        var emittedSettings: [TypographySettings] = []

        service.settingsPublisher
            .sink { emittedSettings.append($0) }
            .store(in: &cancellables)

        service.updateFontFamily("Courier")

        XCTAssertEqual(emittedSettings.count, 1)
        XCTAssertEqual(emittedSettings.first?.fontFamily, "Courier")
    }

    func testSettingsPublisher_emitsOnThemeChange() {
        service = makeService()
        var emittedSettings: [TypographySettings] = []

        service.settingsPublisher
            .sink { emittedSettings.append($0) }
            .store(in: &cancellables)

        service.updateTheme(.night)

        XCTAssertEqual(emittedSettings.count, 1)
        XCTAssertEqual(emittedSettings.first?.theme, .night)
    }

    func testSettingsPublisher_emitsOnEachChange() {
        service = makeService()
        var emitCount = 0

        service.settingsPublisher
            .sink { _ in emitCount += 1 }
            .store(in: &cancellables)

        service.updateFontFamily("Courier")
        service.updateFontSize(20)
        service.updateLineSpacing(2.0)
        service.updateMargins(.large)
        service.updateTextAlignment(.center)

        XCTAssertEqual(emitCount, 5, "Should emit once per setting change")
    }

    // MARK: - Debounced Persistence

    func testDebouncedPersistence_multipleRapidChanges_eventuallyPersists() async throws {
        service = makeService(debounceInterval: 0.1)

        service.updateFontFamily("Courier")
        service.updateFontSize(20)
        service.updateLineSpacing(2.0)

        // Wait for debounce to fire
        try await Task.sleep(nanoseconds: 300_000_000) // 0.3s
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        // Should have persisted (possibly multiple times due to debounce reset,
        // but at least once)
        XCTAssertGreaterThanOrEqual(persistence.saveCallCount, 1,
                                    "Should persist after debounce interval")
    }

    func testDebouncedPersistence_savesLatestSettings() async throws {
        service = makeService(debounceInterval: 0.1)

        service.updateFontFamily("Helvetica")
        service.updateFontFamily("Courier")
        service.updateFontFamily("Georgia")

        try await Task.sleep(nanoseconds: 300_000_000)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(persistence.savedSettings?.fontFamily, "Georgia",
                       "Should persist the latest font family")
    }

    // MARK: - Loads Persisted Settings

    func testInit_loadsPersistedSettings() {
        var custom = TypographySettings.default
        custom.fontFamily = "Courier"
        custom.fontSize = 20.0
        persistence.storedSettings = custom

        service = makeService()

        XCTAssertEqual(service.settings.fontFamily, "Courier")
        XCTAssertEqual(service.settings.fontSize, 20.0)
    }

    func testInit_usesDefaultWhenNoPersisted() {
        persistence.storedSettings = nil

        service = makeService()

        XCTAssertEqual(service.settings, .default)
    }

    // MARK: - Value Clamping on Apply

    func testApplySettings_clampsValues() {
        service = makeService()

        var extreme = TypographySettings.default
        extreme.fontSize = 1000.0
        extreme.lineSpacing = 100.0

        service.applySettings(extreme)

        XCTAssertEqual(service.settings.fontSize, TypographySettings.fontSizeRange.upperBound)
        XCTAssertEqual(service.settings.lineSpacing, TypographySettings.lineSpacingRange.upperBound)
    }

    // MARK: - Individual Update Methods Clamp

    func testUpdateFontSize_clampsToRange() {
        service = makeService()

        service.updateFontSize(1.0) // below min of 10
        XCTAssertEqual(service.settings.fontSize, 10.0)

        service.updateFontSize(1000.0) // above max of 40
        XCTAssertEqual(service.settings.fontSize, 40.0)
    }

    func testUpdateLineSpacing_clampsToRange() {
        service = makeService()

        service.updateLineSpacing(0.1) // below min of 1.0
        XCTAssertEqual(service.settings.lineSpacing, 1.0)
    }

    func testUpdateLetterSpacing_clampsToRange() {
        service = makeService()

        service.updateLetterSpacing(-5.0)
        XCTAssertEqual(service.settings.letterSpacing, TypographySettings.letterSpacingRange.lowerBound)
    }

    func testUpdateWordSpacing_clampsToRange() {
        service = makeService()

        service.updateWordSpacing(10.0)
        XCTAssertEqual(service.settings.wordSpacing, TypographySettings.wordSpacingRange.upperBound)
    }

    func testUpdateParagraphSpacing_clampsToRange() {
        service = makeService()

        service.updateParagraphSpacing(100.0)
        XCTAssertEqual(service.settings.paragraphSpacing, TypographySettings.paragraphSpacingRange.upperBound)
    }

    // MARK: - Helpers

    private func makeService(debounceInterval: TimeInterval = 0.5) -> TypographyService {
        TypographyService(persistence: persistence, debounceInterval: debounceInterval)
    }
}

//
//  TypographySettingsViewModelTests.swift
//  PalaceTests
//
//  Tests for TypographySettingsViewModel: slider changes, preset selection, reset.
//

import XCTest
import Combine
@testable import Palace

@MainActor
final class TypographySettingsViewModelTests: XCTestCase {

    private var service: TypographyService!
    private var viewModel: TypographySettingsViewModel!
    private var testDefaults: UserDefaults!
    private var cancellables: Set<AnyCancellable>!

    // async setUp adopts the class's @MainActor isolation so testDefaults can be
    // passed to the @MainActor TypographyService init without a sending violation.
    override func setUp() async throws {
        try await super.setUp()
        testDefaults = UserDefaults(suiteName: "TypographySettingsViewModelTests")!
        testDefaults.removePersistentDomain(forName: "TypographySettingsViewModelTests")
        service = TypographyService(userDefaults: testDefaults)
        viewModel = TypographySettingsViewModel(typographyService: service)
        cancellables = []
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: "TypographySettingsViewModelTests")
        testDefaults = nil
        service = nil
        viewModel = nil
        cancellables = nil
        super.tearDown()
    }

    // MARK: - Initial State

    func testInitialStateMatchesService() {
        XCTAssertEqual(viewModel.currentSettings, service.currentSettings)
        // The initial font size and line spacing must also match
        XCTAssertEqual(viewModel.currentSettings.fontSize, service.currentSettings.fontSize,
                       "Initial fontSize must match the service")
        XCTAssertEqual(viewModel.currentSettings.lineSpacing, service.currentSettings.lineSpacing,
                       "Initial lineSpacing must match the service")
    }

    func testInitialPresetIsClassic() {
        XCTAssertNotNil(viewModel.selectedPreset)
        XCTAssertEqual(viewModel.selectedPreset?.id, "classic")
        // The selected preset must also be in the list of all available presets
        let allPresetIds = TypographyPreset.allPresets.map(\.id)
        XCTAssertTrue(allPresetIds.contains("classic"), "classic must be a valid preset id")
    }

    func testAvailableFontsNotEmpty() {
        XCTAssertFalse(viewModel.availableFonts.isEmpty)
        // Every font in the list must have a non-empty display name
        for font in viewModel.availableFonts {
            XCTAssertFalse(font.displayName.isEmpty,
                           "Every available font must have a non-empty display name")
        }
    }

    func testPreviewTextNotEmpty() {
        XCTAssertFalse(viewModel.previewText.isEmpty)
        // Preview text must be at least a few characters to be meaningful
        XCTAssertGreaterThanOrEqual(viewModel.previewText.count, 5,
                                    "Preview text must have at least 5 characters to be readable")
    }

    // MARK: - Preset Selection

    func testSelectPresetUpdatesSettings() {
        viewModel.selectPreset(.modern)
        flushRunLoop()
        XCTAssertEqual(viewModel.selectedPreset?.id, "modern")
        XCTAssertEqual(viewModel.currentSettings.fontFamily, .sfPro)
        XCTAssertEqual(viewModel.currentSettings.presetIdentifier, "modern")
    }

    func testSelectPresetUpdatesService() {
        viewModel.selectPreset(.cozy)
        flushRunLoop()
        XCTAssertEqual(service.currentSettings.presetIdentifier, "cozy")
        XCTAssertEqual(service.currentSettings.fontFamily, .palatino)
    }

    func testSelectAllPresetsInSequence() {
        for preset in TypographyPreset.allPresets {
            viewModel.selectPreset(preset)
            flushRunLoop()
            XCTAssertEqual(viewModel.selectedPreset?.id, preset.id)
            XCTAssertEqual(viewModel.currentSettings.fontFamily, preset.settings.fontFamily)
        }
    }

    // MARK: - Helpers

    /// Flush the RunLoop so that Combine's `receive(on: RunLoop.main)` delivers values.
    private func flushRunLoop() {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    // MARK: - Font Size

    func testUpdateFontSize() {
        viewModel.fontSize = 24
        flushRunLoop()
        XCTAssertEqual(viewModel.currentSettings.fontSize, 24)
        XCTAssertNil(viewModel.selectedPreset, "Custom change should clear preset")
    }

    func testFontSizeGetterMatchesSettings() {
        viewModel.selectPreset(.dense)
        flushRunLoop()
        XCTAssertEqual(viewModel.fontSize, TypographyPreset.dense.settings.fontSize)
        // Dense preset should have a smaller font than classic
        XCTAssertLessThan(viewModel.fontSize, TypographyPreset.classic.settings.fontSize,
                          "Dense preset should have smaller font size than Classic")
    }

    // MARK: - Line Spacing

    func testUpdateLineSpacing() {
        viewModel.lineSpacing = 2.0
        flushRunLoop()
        XCTAssertEqual(viewModel.currentSettings.lineSpacing, 2.0)
        XCTAssertNil(viewModel.selectedPreset)
    }

    // MARK: - Margin Level

    func testUpdateMarginLevel() {
        viewModel.marginLevel = .extraWide
        flushRunLoop()
        XCTAssertEqual(viewModel.currentSettings.marginLevel, .extraWide)
        // Custom change must clear any active preset
        XCTAssertNil(viewModel.selectedPreset, "Custom margin change must clear the active preset")
        // Service must reflect the same change
        XCTAssertEqual(service.currentSettings.marginLevel, .extraWide)
    }

    // MARK: - Paragraph Spacing

    func testUpdateParagraphSpacing() {
        viewModel.paragraphSpacing = 20
        flushRunLoop()
        XCTAssertEqual(viewModel.currentSettings.paragraphSpacing, 20)
        // Service must also reflect the change
        XCTAssertEqual(service.currentSettings.paragraphSpacing, 20)
        // Preset must be cleared since it's a custom override
        XCTAssertNil(viewModel.selectedPreset)
    }

    // MARK: - Text Alignment

    func testUpdateTextAlignment() {
        viewModel.updateTextAlignment(.justified)
        flushRunLoop()
        XCTAssertEqual(viewModel.textAlignment, .justified)
        // Service must match the ViewModel
        XCTAssertEqual(service.currentSettings.textAlignment, .justified)
        // Preset must be cleared since it's a custom override
        XCTAssertNil(viewModel.selectedPreset)
    }

    func testAlignmentGetterMatchesSettings() {
        viewModel.selectPreset(.classic) // justified
        flushRunLoop()
        XCTAssertEqual(viewModel.textAlignment, .justified)
        // Getter must always be consistent with the underlying settings
        XCTAssertEqual(viewModel.textAlignment, viewModel.currentSettings.textAlignment)
    }

    // MARK: - Word Spacing

    func testUpdateWordSpacing() {
        viewModel.wordSpacing = 3.0
        flushRunLoop()
        XCTAssertEqual(viewModel.currentSettings.wordSpacing, 3.0)
        XCTAssertEqual(service.currentSettings.wordSpacing, 3.0)
        XCTAssertNil(viewModel.selectedPreset)
    }

    // MARK: - Letter Spacing

    func testUpdateLetterSpacing() {
        viewModel.letterSpacing = 1.0
        flushRunLoop()
        XCTAssertEqual(viewModel.currentSettings.letterSpacing, 1.0)
        XCTAssertEqual(service.currentSettings.letterSpacing, 1.0)
        XCTAssertNil(viewModel.selectedPreset)
    }

    // MARK: - Font Family

    func testUpdateFontFamily() {
        viewModel.fontFamily = .avenir
        flushRunLoop()
        XCTAssertEqual(viewModel.currentSettings.fontFamily, .avenir)
        XCTAssertNil(viewModel.selectedPreset)
    }

    // MARK: - Theme

    func testUpdateTheme() {
        viewModel.theme = .dark
        flushRunLoop()
        XCTAssertEqual(viewModel.currentSettings.theme, .dark)
        XCTAssertEqual(service.currentSettings.theme, .dark)
        // Dark theme should be classified as dark by isDark
        XCTAssertTrue(viewModel.currentSettings.theme.isDark)
    }

    // MARK: - Reset

    func testResetToPresetAfterCustomization() {
        viewModel.selectPreset(.modern)
        flushRunLoop()
        viewModel.fontSize = 30 // Customize
        flushRunLoop()
        XCTAssertNil(viewModel.selectedPreset)

        viewModel.resetToPreset()
        flushRunLoop()
        // No preset identifier after customization, so resets to classic
        XCTAssertEqual(viewModel.selectedPreset?.id, "classic")
    }

    func testResetWithNoPresetResetsToClassic() {
        viewModel.fontFamily = .avenir // No preset
        flushRunLoop()
        viewModel.resetToPreset()
        flushRunLoop()
        XCTAssertEqual(viewModel.selectedPreset?.id, "classic")
        XCTAssertEqual(viewModel.fontFamily, .georgia)
    }

    // MARK: - Custom Overrides Detection

    func testHasCustomOverridesIsFalseForPreset() {
        viewModel.selectPreset(.classic)
        flushRunLoop()
        XCTAssertFalse(viewModel.hasCustomOverrides)
        // Applying any other preset also has no overrides immediately after
        viewModel.selectPreset(.modern)
        flushRunLoop()
        XCTAssertFalse(viewModel.hasCustomOverrides, "A freshly-applied preset should have no overrides")
    }

    func testHasCustomOverridesIsTrueAfterChange() {
        viewModel.selectPreset(.classic)
        flushRunLoop()
        viewModel.fontSize = 30
        flushRunLoop()
        XCTAssertTrue(viewModel.hasCustomOverrides)
        // The preset must be nil since a custom override cleared it
        XCTAssertNil(viewModel.selectedPreset, "A custom override must clear the selected preset")
    }

    func testHasCustomOverridesIsTrueWithNoPreset() {
        viewModel.fontFamily = .avenir
        flushRunLoop()
        XCTAssertTrue(viewModel.hasCustomOverrides)
        // No preset should be selected when a custom font family is applied
        XCTAssertNil(viewModel.selectedPreset, "Custom font change must not keep a preset selected")
    }

    // MARK: - Preview CSS

    func testPreviewCSSNotEmpty() {
        XCTAssertFalse(viewModel.previewCSS.isEmpty)
        // CSS must contain at minimum a body selector, font-family, and font-size
        XCTAssertTrue(viewModel.previewCSS.contains("body {"), "Preview CSS must contain body selector")
        XCTAssertTrue(viewModel.previewCSS.contains("font-family"), "Preview CSS must include font-family")
    }

    func testPreviewCSSChangesWithSettings() {
        let cssBefore = viewModel.previewCSS
        viewModel.theme = .night
        flushRunLoop()
        let cssAfter = viewModel.previewCSS
        XCTAssertNotEqual(cssBefore, cssAfter, "CSS should change when theme changes")
        // Night theme must include a dark background color
        XCTAssertTrue(cssAfter.contains("#000000"), "Night theme CSS must have black background")
    }

    // MARK: - Service Synchronization

    func testServiceChangesReflectedInViewModel() {
        let expectation = expectation(description: "ViewModel updated from service")

        viewModel.$currentSettings
            .dropFirst()
            .prefix(1)
            .sink { settings in
                XCTAssertEqual(settings.fontFamily, .timesNewRoman)
                // The font size must remain unchanged — only fontFamily changed
                XCTAssertEqual(settings.fontSize, TypographyPreset.classic.settings.fontSize,
                               "Only fontFamily should change; fontSize must remain at classic value")
                expectation.fulfill()
            }
            .store(in: &cancellables)

        service.updateFontFamily(.timesNewRoman)

        waitForExpectations(timeout: 1)
    }

    // MARK: - Multiple Rapid Changes

    func testRapidChangesSettleCorrectly() {
        for size in stride(from: CGFloat(12), through: 36, by: 1) {
            viewModel.fontSize = size
        }
        flushRunLoop()
        XCTAssertEqual(viewModel.fontSize, 36)
        XCTAssertEqual(service.currentSettings.fontSize, 36)
    }
}

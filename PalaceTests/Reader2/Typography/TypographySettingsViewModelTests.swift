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

    override func setUp() {
        super.setUp()
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
    }

    func testInitialPresetIsClassic() {
        XCTAssertNotNil(viewModel.selectedPreset)
        XCTAssertEqual(viewModel.selectedPreset?.id, "classic")
    }

    func testAvailableFontsNotEmpty() {
        XCTAssertFalse(viewModel.availableFonts.isEmpty)
    }

    func testPreviewTextNotEmpty() {
        XCTAssertFalse(viewModel.previewText.isEmpty)
    }

    // MARK: - Preset Selection

    func testSelectPresetUpdatesSettings() {
        viewModel.selectPreset(.modern)
        XCTAssertEqual(viewModel.selectedPreset?.id, "modern")
        XCTAssertEqual(viewModel.currentSettings.fontFamily, .sfPro)
        XCTAssertEqual(viewModel.currentSettings.presetIdentifier, "modern")
    }

    func testSelectPresetUpdatesService() {
        viewModel.selectPreset(.cozy)
        XCTAssertEqual(service.currentSettings.presetIdentifier, "cozy")
        XCTAssertEqual(service.currentSettings.fontFamily, .palatino)
    }

    func testSelectAllPresetsInSequence() {
        for preset in TypographyPreset.allPresets {
            viewModel.selectPreset(preset)
            XCTAssertEqual(viewModel.selectedPreset?.id, preset.id)
            XCTAssertEqual(viewModel.currentSettings.fontFamily, preset.settings.fontFamily)
        }
    }

    // MARK: - Font Size

    func testUpdateFontSize() {
        viewModel.fontSize = 24
        XCTAssertEqual(viewModel.currentSettings.fontSize, 24)
        XCTAssertNil(viewModel.selectedPreset, "Custom change should clear preset")
    }

    func testFontSizeGetterMatchesSettings() {
        viewModel.selectPreset(.dense)
        XCTAssertEqual(viewModel.fontSize, TypographyPreset.dense.settings.fontSize)
    }

    // MARK: - Line Spacing

    func testUpdateLineSpacing() {
        viewModel.lineSpacing = 2.0
        XCTAssertEqual(viewModel.currentSettings.lineSpacing, 2.0)
        XCTAssertNil(viewModel.selectedPreset)
    }

    // MARK: - Margin Level

    func testUpdateMarginLevel() {
        viewModel.marginLevel = .extraWide
        XCTAssertEqual(viewModel.currentSettings.marginLevel, .extraWide)
    }

    // MARK: - Paragraph Spacing

    func testUpdateParagraphSpacing() {
        viewModel.paragraphSpacing = 20
        XCTAssertEqual(viewModel.currentSettings.paragraphSpacing, 20)
    }

    // MARK: - Text Alignment

    func testUpdateTextAlignment() {
        viewModel.updateTextAlignment(.justified)
        XCTAssertEqual(viewModel.textAlignment, .justified)
    }

    func testAlignmentGetterMatchesSettings() {
        viewModel.selectPreset(.classic) // justified
        XCTAssertEqual(viewModel.textAlignment, .justified)
    }

    // MARK: - Word Spacing

    func testUpdateWordSpacing() {
        viewModel.wordSpacing = 3.0
        XCTAssertEqual(viewModel.currentSettings.wordSpacing, 3.0)
    }

    // MARK: - Letter Spacing

    func testUpdateLetterSpacing() {
        viewModel.letterSpacing = 1.0
        XCTAssertEqual(viewModel.currentSettings.letterSpacing, 1.0)
    }

    // MARK: - Font Family

    func testUpdateFontFamily() {
        viewModel.fontFamily = .avenir
        XCTAssertEqual(viewModel.currentSettings.fontFamily, .avenir)
        XCTAssertNil(viewModel.selectedPreset)
    }

    // MARK: - Theme

    func testUpdateTheme() {
        viewModel.theme = .dark
        XCTAssertEqual(viewModel.currentSettings.theme, .dark)
    }

    // MARK: - Reset

    func testResetToPresetAfterCustomization() {
        viewModel.selectPreset(.modern)
        viewModel.fontSize = 30 // Customize
        XCTAssertNil(viewModel.selectedPreset)

        viewModel.resetToPreset()
        // No preset identifier after customization, so resets to classic
        XCTAssertEqual(viewModel.selectedPreset?.id, "classic")
    }

    func testResetWithNoPresetResetsToClassic() {
        viewModel.fontFamily = .avenir // No preset
        viewModel.resetToPreset()
        XCTAssertEqual(viewModel.selectedPreset?.id, "classic")
        XCTAssertEqual(viewModel.fontFamily, .georgia)
    }

    // MARK: - Custom Overrides Detection

    func testHasCustomOverridesIsFalseForPreset() {
        viewModel.selectPreset(.classic)
        XCTAssertFalse(viewModel.hasCustomOverrides)
    }

    func testHasCustomOverridesIsTrueAfterChange() {
        viewModel.selectPreset(.classic)
        viewModel.fontSize = 30
        XCTAssertTrue(viewModel.hasCustomOverrides)
    }

    func testHasCustomOverridesIsTrueWithNoPreset() {
        viewModel.fontFamily = .avenir
        XCTAssertTrue(viewModel.hasCustomOverrides)
    }

    // MARK: - Preview CSS

    func testPreviewCSSNotEmpty() {
        XCTAssertFalse(viewModel.previewCSS.isEmpty)
    }

    func testPreviewCSSChangesWithSettings() {
        let cssBefore = viewModel.previewCSS
        viewModel.theme = .night
        let cssAfter = viewModel.previewCSS
        XCTAssertNotEqual(cssBefore, cssAfter, "CSS should change when theme changes")
    }

    // MARK: - Service Synchronization

    func testServiceChangesReflectedInViewModel() {
        let expectation = expectation(description: "ViewModel updated from service")

        viewModel.$currentSettings
            .dropFirst()
            .prefix(1)
            .sink { settings in
                XCTAssertEqual(settings.fontFamily, .timesNewRoman)
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
        XCTAssertEqual(viewModel.fontSize, 36)
        XCTAssertEqual(service.currentSettings.fontSize, 36)
    }
}

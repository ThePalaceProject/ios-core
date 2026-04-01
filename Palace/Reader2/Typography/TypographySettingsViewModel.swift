//
//  TypographySettingsViewModel.swift
//  Palace
//
//  Typography system — ViewModel driving the typography settings UI.
//

import Combine
import SwiftUI
import UIKit

/// ViewModel for the typography settings panel.
/// Publishes all editable properties and debounces persistence.
@MainActor
final class TypographySettingsViewModel: ObservableObject {

    // MARK: - Published Properties

    @Published var currentSettings: TypographySettings
    @Published var selectedPreset: TypographyPreset?
    @Published var availableFonts: [TPPFontFamily]
    @Published var previewText: String

    // MARK: - Dependencies

    private let typographyService: TypographyServiceProtocol
    private let fontManager: FontManager
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(typographyService: TypographyServiceProtocol? = nil,
         fontManager: FontManager = .shared,
         previewText: String = "In a hole in the ground there lived a hobbit. Not a nasty, dirty, wet hole, filled with the ends of worms and an oozy smell, nor yet a dry, bare, sandy hole with nothing in it to sit down on or to eat: it was a hobbit-hole, and that means comfort.") {

        let service = typographyService ?? TypographyService.shared
        self.typographyService = service
        self.fontManager = fontManager
        self.currentSettings = service.currentSettings
        self.previewText = previewText
        self.availableFonts = fontManager.availableFamilies()

        // Resolve preset from current settings
        if let presetId = service.currentSettings.presetIdentifier {
            self.selectedPreset = TypographyPreset.preset(for: presetId)
        } else {
            self.selectedPreset = nil
        }

        // Subscribe to service changes (e.g. from other screens)
        service.settingsPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] settings in
                guard let self else { return }
                if settings != self.currentSettings {
                    self.currentSettings = settings
                    if let presetId = settings.presetIdentifier {
                        self.selectedPreset = TypographyPreset.preset(for: presetId)
                    } else {
                        self.selectedPreset = nil
                    }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Preset Selection

    func selectPreset(_ preset: TypographyPreset) {
        selectedPreset = preset
        typographyService.applyPreset(preset)
        generateHaptic()
    }

    // MARK: - Individual Property Updates

    func updateFontFamily(_ family: TPPFontFamily) {
        typographyService.updateFontFamily(family)
        selectedPreset = nil
        generateHaptic()
    }

    func updateFontSize(_ size: CGFloat) {
        typographyService.updateFontSize(size)
        selectedPreset = nil
    }

    func updateLineSpacing(_ spacing: CGFloat) {
        typographyService.updateLineSpacing(spacing)
        selectedPreset = nil
    }

    func updateMarginLevel(_ level: MarginLevel) {
        typographyService.updateMarginLevel(level)
        selectedPreset = nil
        generateHaptic()
    }

    func updateParagraphSpacing(_ spacing: CGFloat) {
        typographyService.updateParagraphSpacing(spacing)
        selectedPreset = nil
    }

    func updateTextAlignment(_ alignment: TextAlignmentOption) {
        typographyService.updateTextAlignment(alignment)
        selectedPreset = nil
        generateHaptic()
    }

    func updateWordSpacing(_ spacing: CGFloat) {
        typographyService.updateWordSpacing(spacing)
        selectedPreset = nil
    }

    func updateLetterSpacing(_ spacing: CGFloat) {
        typographyService.updateLetterSpacing(spacing)
        selectedPreset = nil
    }

    func updateTheme(_ theme: ReaderTheme) {
        typographyService.updateTheme(theme)
        selectedPreset = nil
        generateHaptic()
    }

    // MARK: - Reset

    func resetToPreset() {
        typographyService.resetToPreset()
        if let presetId = typographyService.currentSettings.presetIdentifier {
            selectedPreset = TypographyPreset.preset(for: presetId)
        }
        generateHaptic()
    }

    // MARK: - Computed Convenience

    var fontSize: CGFloat {
        get { currentSettings.fontSize }
        set { updateFontSize(newValue) }
    }

    var lineSpacing: CGFloat {
        get { currentSettings.lineSpacing }
        set { updateLineSpacing(newValue) }
    }

    var paragraphSpacing: CGFloat {
        get { currentSettings.paragraphSpacing }
        set { updateParagraphSpacing(newValue) }
    }

    var wordSpacing: CGFloat {
        get { currentSettings.wordSpacing }
        set { updateWordSpacing(newValue) }
    }

    var letterSpacing: CGFloat {
        get { currentSettings.letterSpacing }
        set { updateLetterSpacing(newValue) }
    }

    var fontFamily: TPPFontFamily {
        get { currentSettings.fontFamily }
        set { updateFontFamily(newValue) }
    }

    var theme: ReaderTheme {
        get { currentSettings.theme }
        set { updateTheme(newValue) }
    }

    var textAlignment: TextAlignmentOption {
        get { currentSettings.textAlignment }
        set { updateTextAlignment(newValue) }
    }

    var marginLevel: MarginLevel {
        get { currentSettings.marginLevel }
        set { updateMarginLevel(newValue) }
    }

    /// Whether the current settings differ from the selected preset.
    var hasCustomOverrides: Bool {
        guard let preset = selectedPreset else { return true }
        var presetSettings = preset.settings
        presetSettings.presetIdentifier = currentSettings.presetIdentifier
        return currentSettings != presetSettings
    }

    /// CSS for the current settings (used by the live preview).
    var previewCSS: String {
        typographyService.css(for: currentSettings)
    }

    // MARK: - Haptics

    private func generateHaptic() {
        let generator = UISelectionFeedbackGenerator()
        generator.selectionChanged()
    }
}

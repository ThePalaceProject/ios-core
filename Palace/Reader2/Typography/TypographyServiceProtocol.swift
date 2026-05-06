//
//  TypographyServiceProtocol.swift
//  Palace
//
//  Typography system — protocol for the typography management service.
//

import Combine
import Foundation

/// Protocol defining the typography service interface.
/// Manages current settings, persistence, CSS generation, and change notification.
@MainActor
protocol TypographyServiceProtocol: AnyObject {

    /// Publisher that emits the current settings whenever they change.
    var settingsPublisher: AnyPublisher<TypographySettings, Never> { get }

    /// The current typography settings.
    var currentSettings: TypographySettings { get }

    /// Updates the full typography settings.
    func updateSettings(_ settings: TypographySettings)

    /// Applies a preset, replacing all current settings.
    func applyPreset(_ preset: TypographyPreset)

    /// Updates individual typography properties.
    func updateFontFamily(_ family: TPPFontFamily)
    func updateFontSize(_ size: CGFloat)
    func updateLineSpacing(_ spacing: CGFloat)
    func updateMarginLevel(_ level: MarginLevel)
    func updateParagraphSpacing(_ spacing: CGFloat)
    func updateTextAlignment(_ alignment: TextAlignmentOption)
    func updateWordSpacing(_ spacing: CGFloat)
    func updateLetterSpacing(_ spacing: CGFloat)
    func updateTheme(_ theme: ReaderTheme)

    /// Resets settings to the currently selected preset, or to defaults if no preset.
    func resetToPreset()

    /// Generates CSS for the current settings, suitable for Readium injection.
    func cssForCurrentSettings() -> String

    /// Generates CSS for arbitrary settings.
    func css(for settings: TypographySettings) -> String

    /// Applies the current typography settings to an active Readium navigator.
    /// The navigator parameter is typed as `Any` to avoid coupling this protocol
    /// to Readium types. Implementations should cast to `EPUBNavigatorViewController`.
    func applyToReader(_ navigator: Any)
}

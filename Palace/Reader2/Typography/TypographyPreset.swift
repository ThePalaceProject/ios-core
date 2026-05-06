//
//  TypographyPreset.swift
//  Palace
//
//  Typography system — named typography configurations (presets).
//

import Foundation

/// A named, pre-configured typography setup users can select for quick customization.
/// Each preset defines a complete set of typography parameters optimized for
/// a particular reading style.
struct TypographyPreset: Identifiable, Equatable {

    let id: String
    let name: String
    let description: String
    let settings: TypographySettings

    /// Convenience to create a TypographySettings from this preset,
    /// stamped with the preset identifier.
    var typographySettings: TypographySettings {
        var s = settings
        s.presetIdentifier = id
        return s
    }

    // MARK: - Built-in Presets

    /// Classic — Serif (Georgia), comfortable margins, generous line spacing.
    static let classic = TypographyPreset(
        id: "classic",
        name: "Classic",
        description: "Traditional serif reading experience",
        settings: TypographySettings(
            fontFamily: .georgia,
            fontSize: 18,
            lineSpacing: 1.6,
            marginLevel: .medium,
            paragraphSpacing: 12,
            textAlignment: .justified,
            wordSpacing: 0,
            letterSpacing: 0,
            theme: .light
        )
    )

    /// Modern — Sans-serif (SF Pro), tighter spacing, clean look.
    static let modern = TypographyPreset(
        id: "modern",
        name: "Modern",
        description: "Clean sans-serif with tight spacing",
        settings: TypographySettings(
            fontFamily: .sfPro,
            fontSize: 17,
            lineSpacing: 1.4,
            marginLevel: .medium,
            paragraphSpacing: 8,
            textAlignment: .left,
            wordSpacing: 0,
            letterSpacing: 0,
            theme: .light
        )
    )

    /// Cozy — Large text, wide margins, extra line spacing for relaxed reading.
    static let cozy = TypographyPreset(
        id: "cozy",
        name: "Cozy",
        description: "Large text with generous spacing",
        settings: TypographySettings(
            fontFamily: .palatino,
            fontSize: 22,
            lineSpacing: 2.0,
            marginLevel: .wide,
            paragraphSpacing: 16,
            textAlignment: .left,
            wordSpacing: 1,
            letterSpacing: 0.3,
            theme: .sepia
        )
    )

    /// Dense — Smaller text, narrow margins, tight spacing for maximum content.
    static let dense = TypographyPreset(
        id: "dense",
        name: "Dense",
        description: "Maximum content with compact spacing",
        settings: TypographySettings(
            fontFamily: .helveticaNeue,
            fontSize: 14,
            lineSpacing: 1.2,
            marginLevel: .narrow,
            paragraphSpacing: 4,
            textAlignment: .justified,
            wordSpacing: 0,
            letterSpacing: -0.2,
            theme: .light
        )
    )

    /// Dyslexia-Friendly — OpenDyslexic font, extra letter/word spacing, left-aligned.
    static let dyslexiaFriendly = TypographyPreset(
        id: "dyslexia-friendly",
        name: "Dyslexia-Friendly",
        description: "Optimized for readability with OpenDyslexic",
        settings: TypographySettings(
            fontFamily: .openDyslexic,
            fontSize: 20,
            lineSpacing: 1.8,
            marginLevel: .wide,
            paragraphSpacing: 14,
            textAlignment: .left,
            wordSpacing: 3,
            letterSpacing: 1.0,
            theme: .light
        )
    )

    /// Night Reader — Optimized for dark mode, slightly larger, warmer tones.
    static let nightReader = TypographyPreset(
        id: "night-reader",
        name: "Night Reader",
        description: "Easy on the eyes in low light",
        settings: TypographySettings(
            fontFamily: .newYork,
            fontSize: 19,
            lineSpacing: 1.6,
            marginLevel: .medium,
            paragraphSpacing: 12,
            textAlignment: .left,
            wordSpacing: 0.5,
            letterSpacing: 0.1,
            theme: .night
        )
    )

    /// All built-in presets in display order.
    static let allPresets: [TypographyPreset] = [
        .classic, .modern, .cozy, .dense, .dyslexiaFriendly, .nightReader
    ]

    /// Finds a preset by its identifier, or nil if not found.
    static func preset(for id: String) -> TypographyPreset? {
        allPresets.first { $0.id == id }
    }
}

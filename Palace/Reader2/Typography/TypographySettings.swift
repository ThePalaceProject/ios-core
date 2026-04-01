//
//  TypographySettings.swift
//  Palace
//
//  Typography system — persisted user configuration for reader typography.
//

import Foundation

/// The user's current typography configuration.
/// Codable for persistence to UserDefaults. Stores the selected preset
/// plus any custom overrides the user has made.
struct TypographySettings: Codable, Equatable {

    /// The font family for body text.
    var fontFamily: TPPFontFamily

    /// Font size in points (range: 12-36).
    var fontSize: CGFloat

    /// Line height multiplier (range: 1.0-2.5).
    var lineSpacing: CGFloat

    /// Horizontal margin level (maps to CSS margin values).
    var marginLevel: MarginLevel

    /// Paragraph spacing in points (range: 0-30).
    var paragraphSpacing: CGFloat

    /// Text alignment for body text.
    var textAlignment: TextAlignmentOption

    /// Word spacing in points (range: 0-5).
    var wordSpacing: CGFloat

    /// Letter spacing in points (range: -0.5 to 2.0).
    var letterSpacing: CGFloat

    /// The visual theme (colors).
    var theme: ReaderTheme

    /// If non-nil, this is the preset the settings were last loaded from.
    /// Set to nil when the user customizes beyond the preset.
    var presetIdentifier: String?

    // MARK: - Defaults

    static let defaultFontSize: CGFloat = 18
    static let minFontSize: CGFloat = 12
    static let maxFontSize: CGFloat = 36
    static let fontSizeStep: CGFloat = 1

    static let defaultLineSpacing: CGFloat = 1.5
    static let minLineSpacing: CGFloat = 1.0
    static let maxLineSpacing: CGFloat = 2.5
    static let lineSpacingStep: CGFloat = 0.1

    static let defaultParagraphSpacing: CGFloat = 10
    static let minParagraphSpacing: CGFloat = 0
    static let maxParagraphSpacing: CGFloat = 30

    static let defaultWordSpacing: CGFloat = 0
    static let minWordSpacing: CGFloat = 0
    static let maxWordSpacing: CGFloat = 5

    static let defaultLetterSpacing: CGFloat = 0
    static let minLetterSpacing: CGFloat = -0.5
    static let maxLetterSpacing: CGFloat = 2.0

    /// Creates default typography settings.
    init(
        fontFamily: TPPFontFamily = .georgia,
        fontSize: CGFloat = defaultFontSize,
        lineSpacing: CGFloat = defaultLineSpacing,
        marginLevel: MarginLevel = .medium,
        paragraphSpacing: CGFloat = defaultParagraphSpacing,
        textAlignment: TextAlignmentOption = .left,
        wordSpacing: CGFloat = defaultWordSpacing,
        letterSpacing: CGFloat = defaultLetterSpacing,
        theme: ReaderTheme = .light,
        presetIdentifier: String? = nil
    ) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.marginLevel = marginLevel
        self.paragraphSpacing = paragraphSpacing
        self.textAlignment = textAlignment
        self.wordSpacing = wordSpacing
        self.letterSpacing = letterSpacing
        self.theme = theme
        self.presetIdentifier = presetIdentifier
    }
}

// MARK: - MarginLevel

/// Horizontal margin presets that map to CSS percentage values.
enum MarginLevel: Int, Codable, CaseIterable, Identifiable {
    case narrow = 0
    case medium = 1
    case wide = 2
    case extraWide = 3

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .narrow: return "Narrow"
        case .medium: return "Medium"
        case .wide: return "Wide"
        case .extraWide: return "Extra Wide"
        }
    }

    /// CSS margin value as a percentage of the viewport width.
    var cssPercentage: CGFloat {
        switch self {
        case .narrow: return 2
        case .medium: return 5
        case .wide: return 10
        case .extraWide: return 15
        }
    }
}

// MARK: - TextAlignmentOption

/// Text alignment options for reader body text.
enum TextAlignmentOption: String, Codable, CaseIterable, Identifiable {
    case left = "left"
    case justified = "justify"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .left: return "Left"
        case .justified: return "Justified"
        }
    }

    var systemImage: String {
        switch self {
        case .left: return "text.alignleft"
        case .justified: return "text.justify"
        }
    }
}

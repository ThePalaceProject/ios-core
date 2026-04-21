//
//  FontFamily.swift
//  Palace
//
//  Typography system — available font families for EPUB reader.
//

import SwiftUI
import UIKit

/// Categories for grouping fonts in the picker UI.
enum FontCategory: String, Codable, CaseIterable {
    case serif = "Serif"
    case sansSerif = "Sans-Serif"
    case accessibility = "Accessibility"
}

/// Represents a font family available for use in the EPUB reader.
/// Each font provides its CSS value for injection into Readium's rendering pipeline.
enum TPPFontFamily: String, Codable, CaseIterable, Identifiable {
    case sfPro = "SF Pro"
    case newYork = "New York"
    case georgia = "Georgia"
    case palatino = "Palatino"
    case timesNewRoman = "Times New Roman"
    case helveticaNeue = "Helvetica Neue"
    case avenir = "Avenir"
    case openDyslexic = "OpenDyslexic"

    var id: String { rawValue }

    /// Human-readable display name shown in the font picker.
    var displayName: String { rawValue }

    /// The CSS font-family value injected into EPUB content via Readium.
    var cssValue: String {
        switch self {
        case .sfPro:
            return "-apple-system, 'SF Pro Text', 'SF Pro Display', system-ui, sans-serif"
        case .newYork:
            return "'New York', 'SFUI-NYSerif', ui-serif, Georgia, serif"
        case .georgia:
            return "Georgia, 'Times New Roman', serif"
        case .palatino:
            return "'Palatino Linotype', Palatino, 'Book Antiqua', serif"
        case .timesNewRoman:
            return "'Times New Roman', Times, serif"
        case .helveticaNeue:
            return "'Helvetica Neue', Helvetica, Arial, sans-serif"
        case .avenir:
            return "'Avenir Next', Avenir, 'Helvetica Neue', sans-serif"
        case .openDyslexic:
            return "'OpenDyslexic3', 'OpenDyslexic', sans-serif"
        }
    }

    /// The category this font belongs to, used for grouping in the picker.
    var category: FontCategory {
        switch self {
        case .georgia, .palatino, .timesNewRoman, .newYork:
            return .serif
        case .sfPro, .helveticaNeue, .avenir:
            return .sansSerif
        case .openDyslexic:
            return .accessibility
        }
    }

    /// Sample preview text shown in the font picker row.
    var previewText: String {
        "The quick brown fox jumps over the lazy dog"
    }

    /// Returns a UIFont for this family at the given size, falling back to system font.
    func uiFont(size: CGFloat) -> UIFont {
        switch self {
        case .sfPro:
            return .systemFont(ofSize: size)
        case .newYork:
            if let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body)
                .withDesign(.serif) {
                return UIFont(descriptor: descriptor, size: size)
            }
            return UIFont(name: "Georgia", size: size) ?? .systemFont(ofSize: size)
        case .georgia:
            return UIFont(name: "Georgia", size: size) ?? .systemFont(ofSize: size)
        case .palatino:
            return UIFont(name: "Palatino", size: size) ?? .systemFont(ofSize: size)
        case .timesNewRoman:
            return UIFont(name: "TimesNewRomanPSMT", size: size) ?? .systemFont(ofSize: size)
        case .helveticaNeue:
            return UIFont(name: "HelveticaNeue", size: size) ?? .systemFont(ofSize: size)
        case .avenir:
            return UIFont(name: "AvenirNext-Regular", size: size) ?? .systemFont(ofSize: size)
        case .openDyslexic:
            return UIFont(name: "OpenDyslexic3", size: size) ?? .systemFont(ofSize: size)
        }
    }

    /// SwiftUI Font for use in previews and settings UI.
    func swiftUIFont(size: CGFloat) -> Font {
        Font(uiFont(size: size))
    }

    /// Whether this font is available on the current device.
    var isAvailable: Bool {
        switch self {
        case .sfPro:
            return true // System font always available
        case .newYork:
            return UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body)
                .withDesign(.serif) != nil
        case .openDyslexic:
            return UIFont(name: "OpenDyslexic3", size: 12) != nil
        default:
            return uiFont(size: 12).familyName != UIFont.systemFont(ofSize: 12).familyName
                || uiFont(size: 12).fontName != UIFont.systemFont(ofSize: 12).fontName
        }
    }

    /// All fonts in a given category.
    static func fonts(in category: FontCategory) -> [TPPFontFamily] {
        allCases.filter { $0.category == category }
    }
}

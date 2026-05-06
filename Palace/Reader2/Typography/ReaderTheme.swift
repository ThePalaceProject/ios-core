//
//  ReaderTheme.swift
//  Palace
//
//  Typography system — visual themes for the EPUB reader.
//

import SwiftUI
import UIKit

/// A visual theme controlling the reader's color scheme.
/// Each theme defines background, text, link, and selection colors.
enum ReaderTheme: String, Codable, CaseIterable, Identifiable {
    case light = "Light"
    case dark = "Dark"
    case sepia = "Sepia"
    case solarized = "Solarized"
    case night = "Night"

    var id: String { rawValue }

    var displayName: String { rawValue }

    /// Background color for the reading area.
    var backgroundColor: UIColor {
        switch self {
        case .light:
            return UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        case .dark:
            return UIColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1.0)
        case .sepia:
            return UIColor(red: 0.98, green: 0.95, blue: 0.90, alpha: 1.0)
        case .solarized:
            return UIColor(red: 0.99, green: 0.96, blue: 0.89, alpha: 1.0)
        case .night:
            return UIColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
        }
    }

    /// Primary text color.
    var textColor: UIColor {
        switch self {
        case .light:
            return UIColor(red: 0.13, green: 0.13, blue: 0.13, alpha: 1.0)
        case .dark:
            return UIColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1.0)
        case .sepia:
            return UIColor(red: 0.27, green: 0.22, blue: 0.17, alpha: 1.0)
        case .solarized:
            return UIColor(red: 0.40, green: 0.48, blue: 0.51, alpha: 1.0)
        case .night:
            return UIColor(red: 0.70, green: 0.70, blue: 0.70, alpha: 1.0)
        }
    }

    /// Hyperlink color.
    var linkColor: UIColor {
        switch self {
        case .light:
            return UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1.0)
        case .dark:
            return UIColor(red: 0.39, green: 0.68, blue: 1.0, alpha: 1.0)
        case .sepia:
            return UIColor(red: 0.55, green: 0.35, blue: 0.17, alpha: 1.0)
        case .solarized:
            return UIColor(red: 0.15, green: 0.55, blue: 0.82, alpha: 1.0)
        case .night:
            return UIColor(red: 0.35, green: 0.60, blue: 0.90, alpha: 1.0)
        }
    }

    /// Text selection highlight color.
    var selectionColor: UIColor {
        switch self {
        case .light:
            return UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 0.3)
        case .dark:
            return UIColor(red: 0.39, green: 0.68, blue: 1.0, alpha: 0.3)
        case .sepia:
            return UIColor(red: 0.55, green: 0.35, blue: 0.17, alpha: 0.3)
        case .solarized:
            return UIColor(red: 0.15, green: 0.55, blue: 0.82, alpha: 0.3)
        case .night:
            return UIColor(red: 0.35, green: 0.60, blue: 0.90, alpha: 0.3)
        }
    }

    /// CSS hex string for the background color.
    var backgroundCSSHex: String {
        backgroundColor.cssHexString
    }

    /// CSS hex string for the text color.
    var textCSSHex: String {
        textColor.cssHexString
    }

    /// CSS hex string for the link color.
    var linkCSSHex: String {
        linkColor.cssHexString
    }

    /// CSS hex string for the selection color.
    var selectionCSSHex: String {
        selectionColor.cssHexString
    }

    /// SwiftUI Color for background (used in previews/cards).
    var backgroundSwiftUI: Color {
        Color(backgroundColor)
    }

    /// SwiftUI Color for text.
    var textSwiftUI: Color {
        Color(textColor)
    }

    /// Swatch color for the theme picker circles.
    var swatchColor: Color {
        backgroundSwiftUI
    }

    /// Whether the theme is considered "dark" for UI adaptation.
    var isDark: Bool {
        switch self {
        case .dark, .night:
            return true
        case .light, .sepia, .solarized:
            return false
        }
    }
}

// MARK: - UIColor CSS Helper

extension UIColor {
    /// Converts the color to a CSS hex string (#RRGGBB).
    var cssHexString: String {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X",
                      Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

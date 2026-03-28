//
//  FontManager.swift
//  Palace
//
//  Typography system — custom font registration and availability.
//

import UIKit
import CoreText

/// Manages registration of custom fonts (e.g. OpenDyslexic) and checks font availability.
/// Call `registerCustomFonts()` at app launch to ensure bundled fonts are available.
final class FontManager {

    static let shared = FontManager()

    /// Tracks whether fonts have already been registered this session.
    private var hasRegistered = false

    private init() {}

    // MARK: - Font Registration

    /// Registers all custom bundled fonts with the system.
    /// Safe to call multiple times; only performs registration once per app session.
    func registerCustomFonts() {
        guard !hasRegistered else { return }
        hasRegistered = true

        registerOpenDyslexicFonts()
    }

    /// Registers OpenDyslexic font files from the app bundle.
    ///
    /// OpenDyslexic files are expected at:
    ///   - Palace/Resources/OpenDyslexicFont/OpenDyslexic3-Regular.ttf
    ///   - Palace/Resources/OpenDyslexicFont/OpenDyslexic3-Bold.ttf
    ///
    /// If you want to add the .otf variant, place it at:
    ///   Palace/Resources/Fonts/OpenDyslexic-Regular.otf
    private func registerOpenDyslexicFonts() {
        let fontFiles = [
            ("OpenDyslexic3-Regular", "ttf"),
            ("OpenDyslexic3-Bold", "ttf")
        ]

        for (name, ext) in fontFiles {
            registerFont(named: name, extension: ext)
        }
    }

    /// Registers a single font file with CoreText.
    /// - Parameters:
    ///   - name: The font file name (without extension).
    ///   - extension: The file extension (e.g. "ttf", "otf").
    /// - Returns: `true` if registration succeeded or the font was already registered.
    @discardableResult
    func registerFont(named name: String, extension ext: String) -> Bool {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
            logFontWarning("Font file not found: \(name).\(ext)")
            return false
        }
        return registerFont(at: url)
    }

    /// Registers a font file at the given URL with CoreText.
    /// - Parameter url: File URL to the font resource.
    /// - Returns: `true` if registration succeeded or the font was already registered.
    @discardableResult
    func registerFont(at url: URL) -> Bool {
        var error: Unmanaged<CFError>?
        let success = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)

        if !success {
            if let cfError = error?.takeRetainedValue() {
                let nsError = cfError as Error as NSError
                // Error code 105 = font already registered, which is fine
                if nsError.code == 105 {
                    return true
                }
                logFontWarning("Failed to register font at \(url.lastPathComponent): \(nsError.localizedDescription)")
            }
            return false
        }
        return true
    }

    // MARK: - Availability

    /// Checks whether a specific font name is available on the system.
    /// - Parameter fontName: The PostScript name of the font (e.g. "OpenDyslexic3").
    /// - Returns: `true` if the font can be instantiated.
    func isFontAvailable(_ fontName: String) -> Bool {
        UIFont(name: fontName, size: 12) != nil
    }

    /// Checks whether all fonts in a given `TPPFontFamily` are available.
    /// - Parameter family: The font family to check.
    /// - Returns: `true` if the font family's primary font is available.
    func isFamilyAvailable(_ family: TPPFontFamily) -> Bool {
        family.isAvailable
    }

    /// Returns all `TPPFontFamily` cases that are currently available on the device.
    func availableFamilies() -> [TPPFontFamily] {
        TPPFontFamily.allCases.filter { $0.isAvailable }
    }

    // MARK: - Logging

    private func logFontWarning(_ message: String) {
        #if DEBUG
        print("[FontManager] \(message)")
        #endif
    }
}

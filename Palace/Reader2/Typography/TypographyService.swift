//
//  TypographyService.swift
//  Palace
//
//  Typography system — manages typography settings, persistence, and CSS generation.
//

import Combine
import Foundation
import UIKit

/// Concrete implementation of `TypographyServiceProtocol`.
/// Persists settings to UserDefaults, publishes changes via Combine,
/// and generates CSS for injection into Readium's EPUB renderer.
@MainActor
final class TypographyService: TypographyServiceProtocol {

    // MARK: - Singleton

    static let shared = TypographyService()

    // MARK: - Constants

    private static let userDefaultsKey = "TypographyService.settings"

    // MARK: - Published State

    private let settingsSubject: CurrentValueSubject<TypographySettings, Never>
    private var persistCancellable: AnyCancellable?

    var settingsPublisher: AnyPublisher<TypographySettings, Never> {
        settingsSubject.eraseToAnyPublisher()
    }

    var currentSettings: TypographySettings {
        settingsSubject.value
    }

    // MARK: - Init

    init(userDefaults: UserDefaults = .standard) {
        let loaded = TypographyService.loadSettings(from: userDefaults)
        self.settingsSubject = CurrentValueSubject(loaded)

        // Debounced persistence: save 500ms after the last change
        self.persistCancellable = settingsSubject
            .dropFirst() // Don't re-save the initial load
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] settings in
                self?.persist(settings, to: userDefaults)
            }
    }

    // MARK: - Full Update

    func updateSettings(_ settings: TypographySettings) {
        settingsSubject.send(settings)
    }

    func applyPreset(_ preset: TypographyPreset) {
        updateSettings(preset.typographySettings)
    }

    // MARK: - Individual Updates

    func updateFontFamily(_ family: TPPFontFamily) {
        var s = currentSettings
        s.fontFamily = family
        s.presetIdentifier = nil
        settingsSubject.send(s)
    }

    func updateFontSize(_ size: CGFloat) {
        var s = currentSettings
        s.fontSize = clamp(size, min: TypographySettings.minFontSize, max: TypographySettings.maxFontSize)
        s.presetIdentifier = nil
        settingsSubject.send(s)
    }

    func updateLineSpacing(_ spacing: CGFloat) {
        var s = currentSettings
        s.lineSpacing = clamp(spacing, min: TypographySettings.minLineSpacing, max: TypographySettings.maxLineSpacing)
        s.presetIdentifier = nil
        settingsSubject.send(s)
    }

    func updateMarginLevel(_ level: MarginLevel) {
        var s = currentSettings
        s.marginLevel = level
        s.presetIdentifier = nil
        settingsSubject.send(s)
    }

    func updateParagraphSpacing(_ spacing: CGFloat) {
        var s = currentSettings
        s.paragraphSpacing = clamp(spacing, min: TypographySettings.minParagraphSpacing, max: TypographySettings.maxParagraphSpacing)
        s.presetIdentifier = nil
        settingsSubject.send(s)
    }

    func updateTextAlignment(_ alignment: TextAlignmentOption) {
        var s = currentSettings
        s.textAlignment = alignment
        s.presetIdentifier = nil
        settingsSubject.send(s)
    }

    func updateWordSpacing(_ spacing: CGFloat) {
        var s = currentSettings
        s.wordSpacing = clamp(spacing, min: TypographySettings.minWordSpacing, max: TypographySettings.maxWordSpacing)
        s.presetIdentifier = nil
        settingsSubject.send(s)
    }

    func updateLetterSpacing(_ spacing: CGFloat) {
        var s = currentSettings
        s.letterSpacing = clamp(spacing, min: TypographySettings.minLetterSpacing, max: TypographySettings.maxLetterSpacing)
        s.presetIdentifier = nil
        settingsSubject.send(s)
    }

    func updateTheme(_ theme: ReaderTheme) {
        var s = currentSettings
        s.theme = theme
        s.presetIdentifier = nil
        settingsSubject.send(s)
    }

    func resetToPreset() {
        if let presetId = currentSettings.presetIdentifier,
           let preset = TypographyPreset.preset(for: presetId) {
            updateSettings(preset.typographySettings)
        } else {
            updateSettings(TypographyPreset.classic.typographySettings)
        }
    }

    // MARK: - CSS Generation

    func cssForCurrentSettings() -> String {
        css(for: currentSettings)
    }

    func css(for settings: TypographySettings) -> String {
        let theme = settings.theme

        var css = """
        /* Palace Typography — generated CSS */
        :root {
            --palace-bg: \(theme.backgroundCSSHex);
            --palace-text: \(theme.textCSSHex);
            --palace-link: \(theme.linkCSSHex);
            --palace-selection: \(theme.selectionCSSHex);
        }

        html {
            background-color: \(theme.backgroundCSSHex) !important;
        }

        body {
            font-family: \(settings.fontFamily.cssValue) !important;
            font-size: \(Int(settings.fontSize))px !important;
            line-height: \(String(format: "%.2f", settings.lineSpacing)) !important;
            color: \(theme.textCSSHex) !important;
            background-color: \(theme.backgroundCSSHex) !important;
            text-align: \(settings.textAlignment.rawValue) !important;
            word-spacing: \(String(format: "%.1f", settings.wordSpacing))px !important;
            letter-spacing: \(String(format: "%.2f", settings.letterSpacing))px !important;
            margin-left: \(String(format: "%.1f", settings.marginLevel.cssPercentage))% !important;
            margin-right: \(String(format: "%.1f", settings.marginLevel.cssPercentage))% !important;
            -webkit-hyphens: \(settings.textAlignment == .justified ? "auto" : "none") !important;
            hyphens: \(settings.textAlignment == .justified ? "auto" : "none") !important;
        }

        p {
            margin-bottom: \(Int(settings.paragraphSpacing))px !important;
        }

        a, a:link, a:visited {
            color: \(theme.linkCSSHex) !important;
        }

        ::selection {
            background-color: \(theme.selectionCSSHex) !important;
        }

        """

        // Add hyphenation for justified text
        if settings.textAlignment == .justified {
            css += """

            p, div, span, li, td, th, dd, dt, blockquote {
                -webkit-hyphens: auto !important;
                hyphens: auto !important;
                overflow-wrap: break-word !important;
                word-break: break-word !important;
            }

            """
        }

        // Override heading fonts to use the same family for consistency
        css += """

        h1, h2, h3, h4, h5, h6 {
            font-family: \(settings.fontFamily.cssValue) !important;
            color: \(theme.textCSSHex) !important;
        }

        /* Ensure images and figures adapt to theme */
        img {
            max-width: 100% !important;
            height: auto !important;
        }

        figure {
            margin-left: 0 !important;
            margin-right: 0 !important;
        }

        figcaption {
            color: \(theme.textCSSHex) !important;
            font-family: \(settings.fontFamily.cssValue) !important;
        }
        """

        return css
    }

    // MARK: - Reader Integration

    func applyToReader(_ navigator: Any) {
        // This method generates CSS that can be applied to a Readium navigator.
        // The actual injection depends on how the reader VC integrates with this service.
        // EPUBNavigatorViewController.submitPreferences() is the Readium 3 path,
        // but this CSS can also be injected via evaluateJavaScript on the WKWebView.
        //
        // Integration example (in TPPEPUBViewController):
        //   let css = typographyService.cssForCurrentSettings()
        //   let js = "document.getElementById('palace-typography')?.remove();" +
        //            "var s = document.createElement('style');" +
        //            "s.id = 'palace-typography';" +
        //            "s.textContent = `\(css)`;" +
        //            "document.head.appendChild(s);"
        //   webView.evaluateJavaScript(js)

        let css = cssForCurrentSettings()
        let escapedCSS = css
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "\n", with: "\\n")

        let js = """
        (function() {
            var existing = document.getElementById('palace-typography');
            if (existing) existing.remove();
            var s = document.createElement('style');
            s.id = 'palace-typography';
            s.textContent = `\(escapedCSS)`;
            document.head.appendChild(s);
        })();
        """

        // Attempt to find the WKWebView inside the navigator and inject
        if let vc = navigator as? UIViewController {
            injectCSS(js: js, in: vc.view)
        }
    }

    /// Recursively searches for WKWebViews in the view hierarchy and evaluates JavaScript.
    private func injectCSS(js: String, in view: UIView) {
        // We check for evaluateJavaScript to avoid a hard WebKit dependency at the protocol level
        for subview in view.subviews {
            let webView: NSObject = subview
            if webView.responds(to: NSSelectorFromString("evaluateJavaScript:completionHandler:")) {
                webView.perform(
                    NSSelectorFromString("evaluateJavaScript:completionHandler:"),
                    with: js,
                    with: nil
                )
            }
            injectCSS(js: js, in: subview)
        }
    }

    // MARK: - Persistence

    private static func loadSettings(from defaults: UserDefaults) -> TypographySettings {
        guard let data = defaults.data(forKey: userDefaultsKey),
              let settings = try? JSONDecoder().decode(TypographySettings.self, from: data) else {
            return TypographyPreset.classic.typographySettings
        }
        return settings
    }

    private func persist(_ settings: TypographySettings, to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: TypographyService.userDefaultsKey)
        }
    }

    // MARK: - Helpers

    private func clamp(_ value: CGFloat, min minVal: CGFloat, max maxVal: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, minVal), maxVal)
    }
}

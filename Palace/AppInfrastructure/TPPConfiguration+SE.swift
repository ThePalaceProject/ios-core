//
//  TPPConfiguration+SE.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 9/9/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation

extension TPPConfiguration {

    static let registryHashKey = "registryHashKey"

    static let betaUrl = URL(string: "https://registry.palaceproject.io/libraries/qa")!
    static let prodUrl = URL(string: "https://registry.palaceproject.io/libraries")!

    static let betaUrlHash = betaUrl.absoluteString.md5().base64EncodedStringUrlSafe().trimmingCharacters(in: ["="])
    static let prodUrlHash = prodUrl.absoluteString.md5().base64EncodedStringUrlSafe().trimmingCharacters(in: ["="])

    static func customUrl(settings: TPPSettings = TPPSettings()) -> URL? {
        guard let raw = settings.customLibraryRegistryServer?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        // A full URL (scheme + path) is fetched verbatim so a developer can
        // target an exact endpoint — e.g. the bare /libraries feed older clients
        // parse directly. A bare host preserves the historical
        // https://<host>/libraries/qa form.
        if isExplicitURL(raw) {
            guard let url = URL(string: raw) else { return nil }
            // PP-4698: "Enable Hidden Libraries" (useBetaLibraries) requests the
            // hidden/testing libraries, expressed as availability=all. On the
            // explicit-URL branch the crawler is bypassed, so it is applied here
            // (the bare-host branch below stays on the crawler, which appends
            // availability=all itself for its /qa path — see
            // LibraryRegistryCrawler.crawlableURL; injecting it here too would
            // double-append). With the toggle off the URL is fetched exactly as
            // typed, including any availability the developer set themselves.
            return settings.useBetaLibraries ? url.settingQueryItem(name: "availability", value: "all") : url
        }
        return URL(string: "https://\(raw)/libraries/qa")
    }

    /// True when the configured custom registry is a full, explicit URL the
    /// developer wants fetched verbatim — no /libraries/qa suffix, no crawlable
    /// rewrite. Lets dev settings target an exact endpoint such as the
    /// non-crawlable /libraries feed.
    ///
    /// Only true when the explicit string actually parses to a URL, so it never
    /// diverges from `customUrl()` (which returns nil for an unparseable
    /// explicit string) — otherwise the loader would take the explicit-URL fetch
    /// branch for a URL that does not exist.
    static func customRegistryIsExplicitURL(settings: TPPSettings = TPPSettings()) -> Bool {
        guard let raw = settings.customLibraryRegistryServer?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              isExplicitURL(raw) else { return false }
        return URL(string: raw) != nil
    }

    private static func isExplicitURL(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.hasPrefix("https://") || lower.hasPrefix("http://")
    }

    /// Checks if registry changed
    @objc
    static var registryChanged: Bool {
        (UserDefaults.standard.string(forKey: registryHashKey) ?? "") != prodUrlHash
    }

    /// Updates registry key
    @objc
    static func updateSavedeRegistryKey() {
        UserDefaults.standard.set(prodUrlHash, forKey: registryHashKey)
    }

    static func customUrlHash(settings: TPPSettings = TPPSettings()) -> String? {
        customUrl(settings: settings)?.absoluteString.md5().base64EncodedStringUrlSafe().trimmingCharacters(in: ["="])
    }

    /// Converts a base registry URL to the crawlable endpoint URL.
    static func crawlableURL(from baseURL: URL) -> URL {
        LibraryRegistryCrawler.crawlableURL(from: baseURL)
    }

    @objc static func mainColor() -> UIColor {
        UIColor.defaultLabelColor()
    }

    @objc static func palaceRed() -> UIColor {
        if #available(iOS 13, *) {
            if let color = UIColor(named: "PalaceRed") {
                return color
            }
        }

        return UIColor(red: 248.0/255.0, green: 56.0/255.0, blue: 42.0/255.0, alpha: 1.0)
    }

    @objc static func iconLogoBlueColor() -> UIColor {
        UIColor(named: "ColorIconLogoBlue") ?? .systemBlue
    }

    @objc static func audiobookIconColor() -> UIColor {
        UIColor(named: "ColorAudiobookBackground") ?? .systemGray
    }

    @objc static func iconLogoGreenColor() -> UIColor {
        UIColor(red: 141.0/255.0, green: 199.0/255.0, blue: 64.0/255.0, alpha: 1.0)
    }

    static func cardCreationEnabled() -> Bool {
        return true
    }

    @objc static func iconColor() -> UIColor {
        if #available(iOS 13, *) {
            return UIColor(named: "ColorIcon") ?? .black
        } else {
            return .black
        }
    }

    @objc static func compatiblePrimaryColor() -> UIColor {
        if #available(iOS 13, *) {
            return UIColor.label
        } else {
            return .black
        }
    }

    @objc static func compatibleTextColor() -> UIColor {
        if #available(iOS 13, *) {
            return UIColor(named: "ColorInverseLabel") ?? .white
        } else {
            return .white
        }
    }
}

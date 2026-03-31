//
//  TPPConfiguration+SE.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 9/9/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation
import UIKit

extension TPPConfiguration {

    // MARK: - Ported from TPPConfiguration.m

    @objc static func mainFeedURL() -> URL? {
        if let customURL = TPPSettings.shared.customMainFeedURL {
            return customURL
        }
        return TPPSettings.shared.accountMainFeedURL
    }

    @objc static func minimumVersionURL() -> URL? {
        URL(string: "http://www.librarysimplified.org/simplye-client/minimum-version")
    }

    @objc static func accentColor() -> UIColor {
        UIColor(red: 0.0 / 255.0, green: 144.0 / 255.0, blue: 196.0 / 255.0, alpha: 1.0)
    }

    @objc static func backgroundColor() -> UIColor {
        if let color = UIColor(named: "ColorBackground") {
            return color
        }
        return UIColor(white: 250.0 / 255.0, alpha: 1.0)
    }

    @objc static func readerBackgroundColor() -> UIColor {
        UIColor(white: 250.0 / 255.0, alpha: 1.0)
    }

    @objc static func readerBackgroundDarkColor() -> UIColor {
        UIColor(white: 5.0 / 255.0, alpha: 1.0)
    }

    @objc static func readerBackgroundSepiaColor() -> UIColor {
        UIColor(red: 250.0 / 255.0, green: 244.0 / 255.0, blue: 232.0 / 255.0, alpha: 1.0)
    }

    @objc static func backgroundMediaOverlayHighlightColor() -> UIColor {
        .yellow
    }

    @objc static func backgroundMediaOverlayHighlightDarkColor() -> UIColor {
        .orange
    }

    @objc static func backgroundMediaOverlayHighlightSepiaColor() -> UIColor {
        .yellow
    }

    @objc static func systemFontFamilyName() -> String {
        "OpenSans"
    }

    @objc static func systemFontName() -> String {
        "OpenSans-Regular"
    }

    @objc static func semiBoldSystemFontName() -> String {
        "OpenSans-SemiBold"
    }

    @objc static func boldSystemFontName() -> String {
        "OpenSans-Bold"
    }

    @objc static func defaultTOCRowHeight() -> CGFloat {
        56
    }

    @objc static func defaultBookmarkRowHeight() -> CGFloat {
        100
    }

    @objc static func defaultAppearance() -> UINavigationBarAppearance {
        appearance(withBackgroundColor: backgroundColor())
    }

    @objc static func appearance(withBackgroundColor backgroundColor: UIColor) -> UINavigationBarAppearance {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = backgroundColor
        appearance.titleTextAttributes = [
            .font: UIFont.semiBoldPalaceFont(ofSize: 18.0)
        ]
        return appearance
    }

    // MARK: - Registry & Colors (original SE extension)

    static let registryHashKey = "registryHashKey"

    static let betaUrl = URL(string: "https://registry.palaceproject.io/libraries/qa")!
    static let prodUrl = URL(string: "https://registry.palaceproject.io/libraries")!

    static let betaUrlHash = betaUrl.absoluteString.md5().base64EncodedStringUrlSafe().trimmingCharacters(in: ["="])
    static let prodUrlHash = prodUrl.absoluteString.md5().base64EncodedStringUrlSafe().trimmingCharacters(in: ["="])

    static func customUrl(settings: TPPSettings = .shared) -> URL? {
        guard let server = settings.customLibraryRegistryServer else { return nil }
        return URL(string: "https://\(server)/libraries/qa")
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

    static func customUrlHash() -> String? {
        customUrl()?.absoluteString.md5().base64EncodedStringUrlSafe().trimmingCharacters(in: ["="])
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
        UIColor(named: "ColorIconLogoBlue")!
    }

    @objc static func audiobookIconColor() -> UIColor {
        UIColor(named: "ColorAudiobookBackground")!
    }

    @objc static func iconLogoGreenColor() -> UIColor {
        UIColor(red: 141.0/255.0, green: 199.0/255.0, blue: 64.0/255.0, alpha: 1.0)
    }

    static func cardCreationEnabled() -> Bool {
        return true
    }

    @objc static func iconColor() -> UIColor {
        if #available(iOS 13, *) {
            return UIColor(named: "ColorIcon")!
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
            return UIColor(named: "ColorInverseLabel")!
        } else {
            return .white
        }
    }
}

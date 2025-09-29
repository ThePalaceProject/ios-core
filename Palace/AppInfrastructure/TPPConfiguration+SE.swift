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

  static func customUrl() -> URL? {
    guard let server = TPPSettings.shared.customLibraryRegistryServer else {
      return nil
    }
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

    return UIColor(red: 248.0 / 255.0, green: 56.0 / 255.0, blue: 42.0 / 255.0, alpha: 1.0)
  }

  @objc static func iconLogoBlueColor() -> UIColor {
    UIColor(named: "ColorIconLogoBlue")!
  }

  @objc static func audiobookIconColor() -> UIColor {
    UIColor(named: "ColorAudiobookBackground")!
  }

  @objc static func iconLogoGreenColor() -> UIColor {
    UIColor(red: 141.0 / 255.0, green: 199.0 / 255.0, blue: 64.0 / 255.0, alpha: 1.0)
  }

  static func cardCreationEnabled() -> Bool {
    true
  }

  @objc static func iconColor() -> UIColor {
    if #available(iOS 13, *) {
      UIColor(named: "ColorIcon")!
    } else {
      .black
    }
  }

  @objc static func compatiblePrimaryColor() -> UIColor {
    if #available(iOS 13, *) {
      UIColor.label
    } else {
      .black
    }
  }

  @objc static func compatibleTextColor() -> UIColor {
    if #available(iOS 13, *) {
      UIColor(named: "ColorInverseLabel")!
    } else {
      .white
    }
  }
}

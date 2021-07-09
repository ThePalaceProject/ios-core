//
//  TPPConfiguration+SE.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 9/9/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation

extension TPPConfiguration {
  
  static let betaUrl = URL(string: "https://libraryregistry.librarysimplified.org/libraries/qa")!
  static let prodUrl = URL(string: "https://libraryregistry.librarysimplified.org/libraries")!
  
  static let betaUrlHash = betaUrl.absoluteString.md5().base64EncodedStringUrlSafe().trimmingCharacters(in: ["="])
  static let prodUrlHash = prodUrl.absoluteString.md5().base64EncodedStringUrlSafe().trimmingCharacters(in: ["="])

  static func customUrl() -> URL? {
    guard let server = TPPSettings.shared.customLibraryRegistryServer else { return nil }
    return URL(string: "https://\(server)/libraries/qa")
  }
  
  static func customUrlHash() -> String? {
    customUrl()?.absoluteString.md5().base64EncodedStringUrlSafe().trimmingCharacters(in: ["="])
  }
  
  @objc static func mainColor() -> UIColor {
    let libAccount = AccountsManager.sharedInstance().currentAccount
    if let mainColor = libAccount?.details?.mainColor {
      return TPPAppTheme.themeColorFromString(name: mainColor)
    }
    return UIColor.defaultLabelColor()
  }

  @objc static func iconLogoBlueColor() -> UIColor {
    if #available(iOS 13, *) {
      if let color = UIColor(named: "ColorIconLogoBlue") {
        return color
      }
    }

    return UIColor(red: 17.0/255.0, green: 50.0/255.0, blue: 84.0/255.0, alpha: 1.0)
  }

  @objc static func iconLogoGreenColor() -> UIColor {
    UIColor(red: 141.0/255.0, green: 199.0/255.0, blue: 64.0/255.0, alpha: 1.0)
  }

  static func cardCreationEnabled() -> Bool {
    return true
  }
  
  @objc static func iconColor() -> UIColor {
    UIApplication.darkModeEnabled ? .white : .black
  }
}

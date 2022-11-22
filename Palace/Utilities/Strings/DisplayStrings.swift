//
//  DisplayStrings.swift
//  Palace
//
//  Created by Maurice Carrier on 12/4/21.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

import Foundation

struct DisplayStrings {
  
  struct Settings {
    static let settings = NSLocalizedString("Settings", comment: "")
    static let libraries = NSLocalizedString("Libraries", comment: "A title for a list of libraries the user may select or add to.")
    static let addLibrary = NSLocalizedString("Add Library", comment: "Title of button to add a new library")
    static let aboutApp = NSLocalizedString("AboutApp", comment: "")
    static let softwareLicenses = NSLocalizedString("SoftwareLicenses", comment: "")
    static let privacyPolicy = NSLocalizedString("PrivacyPolicy", comment: "")
    static let eula = NSLocalizedString("EULA", comment: "")
    static let developerSettings = NSLocalizedString("Testing", comment: "Developer Settings")
  }
  
  struct Error {
    static let loadFailedError = NSLocalizedString("The page could not load due to a conection error.", comment: "")
  }
}

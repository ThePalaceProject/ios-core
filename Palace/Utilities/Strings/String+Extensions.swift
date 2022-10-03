//
//  String+Extensions.swift
//  Palace
//
//  Created by Maurice Work on 10/2/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

extension String {
  var localized: String {
    let localizedString = NSLocalizedString(self, comment: "")
    if localizedString != self {
      return localizedString
    }
    
    guard let fileURLs = Bundle.main.urls(forResourcesWithExtension: "strings", subdirectory: nil) else {
      return self
    }
  
    return fileURLs
      .filter { !$0.lastPathComponent.contains("Localizable") }
      .reduce(self) { translatedString, fileUrl in
        guard let tableName = fileUrl.lastPathComponent.split(separator: ".").first else {
          return translatedString
        }
  
        let translation = Bundle.main.localizedString(forKey: self, value: self, table: String(tableName))
        return translation != self ? translation : translatedString
      }
  }
}

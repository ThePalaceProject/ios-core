//
//  TPPLCPLicense.swift
//  Palace
//
//  Created by Vladimir Fedorov on 01.11.2021.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

#if LCP

import Foundation

// TODO: Convert to Codable struct once TPPMyBookDownloadCenter is rewritten in Swift.

/// LCP License representation.
/// This class is used to get license identifier to use after fulfillment is done.
@objc class TPPLCPLicense: NSObject, Codable {
  /// License ID
  private var id: String
  
  /// Objective-C visible identifier
  @objc var identifier: String {
    id
  }
  
  /// Initializes with license URL
  @objc init?(url: URL) {
    if let data = try? Data(contentsOf: url),
       let license = try? JSONDecoder().decode(TPPLCPLicense.self, from: data) {
      self.id = license.id
    } else {
      return nil
    }
  }
}

#endif

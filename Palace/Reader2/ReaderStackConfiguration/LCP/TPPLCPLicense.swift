//
//  TPPLCPLicense.swift
//  Palace
//
//  Created by Vladimir Fedorov on 01.11.2021.
//  Copyright © 2021 The Palace Project. All rights reserved.
//

#if LCP

import Foundation
import R2Shared

struct TPPLCPLicenseLink: Codable {
  let rel: String?
  let href: String?
  let type: String?
  let title: String?
  let length: Int?
  let hash: String?
}

enum TPPLCPLicenseRel: String {
  case publication
}

// TODO: Convert to Codable struct once TPPMyBookDownloadCenter is rewritten in Swift.

/// LCP License representation.
/// This class is used to get license identifier to use after fulfillment is done.
@objc class TPPLCPLicense: NSObject, Codable {
  /// License ID
  private var id: String
  
  let links: [TPPLCPLicenseLink]
  
  /// Objective-C visible identifier
  @objc var identifier: String {
    id
  }
  
  /// Initializes with license URL
  @objc init?(url: URL) {
    if let data = try? Data(contentsOf: url),
       let license = try? JSONDecoder().decode(TPPLCPLicense.self, from: data) {
      self.id = license.id
      self.links = license.links
    } else {
      return nil
    }
  }
  
  func firstLink(withRel rel: TPPLCPLicenseRel) -> TPPLCPLicenseLink? {
    links.filter({ $0.rel == rel.rawValue }).first
  }
}

#endif

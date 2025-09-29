//
//  TPPPDFPageBookmark.swift
//  Palace
//
//  Created by Vladimir Fedorov on 11.08.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

/// Page bookmark object for page synchronization between devices
@objc class TPPPDFPageBookmark: NSObject, Codable, Bookmark {
  let type: String
  let page: Int
  var annotationID: String?

  enum CodingKeys: String, CodingKey {
    case type = "@type"
    case page
  }

  init(page: Int, annotationID: String? = nil) {
    type = Types.locatorPage.rawValue
    self.page = page
    self.annotationID = annotationID
  }

  enum Types: String {
    case locatorPage = "LocatorPage"
  }
}

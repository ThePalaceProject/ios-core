//
//  TPPPDFPage+serialization.swift
//  Palace
//
//  Created by Vladimir Fedorov on 22.06.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

extension TPPPDFPage {
  
  /// Location string for `TPPBookLocation` object
  var locationString: String? {
    guard let jsonData = try? JSONEncoder().encode(self),
          let jsonString = String(data: jsonData, encoding: .utf8)
    else {
      return nil
    }
    return jsonString
  }
  
  /// Bookmark selector for reading position synchronization
  var bookmarkSelector: String? {
    let bookmark = TPPPDFPageBookmark(page: pageNumber)
    guard let jsonData = try? JSONEncoder().encode(bookmark), let jsonString = String(data: jsonData, encoding: .utf8) else {
      return nil
    }
    return jsonString
  }
}

//
//  TPPPDFLocation.swift
//  Palace
//
//  Created by Vladimir Fedorov on 29.06.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI

// MARK: - TPPPDFLocation

/// TOC and search location
struct TPPPDFLocation {
  let title: String?
  let subtitle: String?
  let pageLabel: String?
  let pageNumber: Int
  let level: Int

  init(title: String?, subtitle: String?, pageLabel: String?, pageNumber: Int, level: Int = 0) {
    self.title = title
    self.subtitle = subtitle
    self.pageLabel = pageLabel
    self.pageNumber = pageNumber
    self.level = level
  }
}

// MARK: Identifiable

extension TPPPDFLocation: Identifiable {
  var id: String {
    let t = title ?? ""
    let s = subtitle ?? ""
    let pv = pageLabel ?? ""
    return "\(pageNumber)-\(pv)-\(s)-\(t)-\(level)"
  }
}

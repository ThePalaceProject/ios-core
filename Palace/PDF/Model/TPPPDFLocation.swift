//
//  TPPPDFLocation.swift
//  Palace
//
//  Created by Vladimir Fedorov on 29.06.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import SwiftUI

/// TOC and search location
struct TPPPDFLocation {
  let title: String?
  let subtitle: String?
  let pageValue: String?
  let pageNumber: Int
}

extension TPPPDFLocation: Identifiable {
  var id: String {
    let t = title ?? ""
    let s = subtitle ?? ""
    let pv = pageValue ?? ""
    return "\(pageNumber)-\(pv)-\(s)-\(t)"
  }
}

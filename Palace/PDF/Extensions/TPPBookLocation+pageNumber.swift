//
//  TPPBookLocation+pageNumber.swift
//  Palace
//
//  Created by Vladimir Fedorov on 22.06.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

extension TPPBookLocation {

  /// Page number in `TPPBookLocation` object
  var pageNumber: Int? {
    guard let locationData = locationString.data(using: .utf8),
          let locationPage = try? JSONDecoder().decode(TPPPDFPage.self, from: locationData) else {
      return nil
    }
    return locationPage.pageNumber
  }
}

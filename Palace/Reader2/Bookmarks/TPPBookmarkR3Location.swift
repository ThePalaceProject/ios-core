//
//  TPPBookmarkR3Location.swift
//  Palace
//
//  Created by Maurice Carrier on 11/19/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation
import ReadiumShared

class TPPBookmarkR3Location {
  var resourceIndex: Int
  var locator: Locator
  var creationDate: Date

  init(resourceIndex: Int, locator: Locator, creationDate: Date = Date()) {
    self.resourceIndex = resourceIndex
    self.locator = locator
    self.creationDate = creationDate
  }
}

extension TPPBookmarkR3Location {
  /// Creates a `TPPBookmarkR3Location` from a given `Locator`.
  ///
  /// - Parameters:
  ///   - locator: The `Locator` representing the reading position.
  ///   - publication: The `Publication` containing the reading material.
  /// - Returns: An optional `TPPBookmarkR3Location` if the `Locator` resolves successfully.
  static func from(locator: Locator, in publication: Publication, creationDate: Date = Date()) -> TPPBookmarkR3Location? {
    let href = locator.href

    guard let resourceIndex = publication.readingOrder.firstIndex(where: { $0.href == href.string }) else {
      return nil
    }

    return TPPBookmarkR3Location(resourceIndex: resourceIndex, locator: locator, creationDate: creationDate)
  }
}

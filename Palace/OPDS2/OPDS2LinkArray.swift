//
//  OPDS2LinkArray.swift
//  Palace
//
//  Created by Vladimir Fedorov on 02.08.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

extension Array where Element == OPDS2Link {
  /// Returns links with the specified `rel` attribute value
  /// - Parameter rel: `rel` attribute value
  /// - Returns: Links with the specified `rel` attribute value
  func all(rel: OPDS2LinkRel) -> [Element] {
    self.filter { $0.rel == rel.rawValue }
  }
  
  /// Returns the first link with the specified `rel` attribute
  /// - Parameter rel: `rel` attribute value
  /// - Returns: The first link with the specified `rel` attribute; `nil` if none found.
  func first(rel: OPDS2LinkRel) -> Element? {
    all(rel: rel).first
  }
}

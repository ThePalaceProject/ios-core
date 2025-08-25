//
//  String+Extensions.swift
//  Palace
//
//  Created by Maurice Carrier on 3/29/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

extension String {
  static func isDate(_ date1: String, moreRecentThan date2: String, with delay: TimeInterval) -> Bool {
    let dateFormatter = ISO8601DateFormatter()
    guard let d1 = dateFormatter.date(from: date1), let d2 = dateFormatter.date(from: date2) else {
      return false
    }
    return d1.addingTimeInterval(delay) > d2
  }
}

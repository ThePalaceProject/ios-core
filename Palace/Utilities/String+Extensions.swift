//
//  String+Extensions.swift
//  Palace
//
//  Created by Maurice Carrier on 3/29/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

extension String {
  static func isDate(_ dateOne: String?, moreRecentThan dateTwo: String?, with margin: TimeInterval) -> Bool {
    let dateFormatter = ISO8601DateFormatter()
    
    guard let dateOne = dateOne, let dateTwo = dateTwo,
          let date1 = dateFormatter.date(from: dateOne),
          let date2 = dateFormatter.date(from: dateTwo) else {
      return false
    }
    
    let timeInterval = date1.timeIntervalSince(date2)
    return timeInterval > margin
  }
}


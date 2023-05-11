//
//  String+Extensions.swift
//  Palace
//
//  Created by Maurice Carrier on 3/29/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation

@objc public extension NSString {
  @objc class func isDate(_ dateOne: NSString, moreRecentThan dateTwo: NSString, with margin: Int) -> Bool {
    let dateFormatter = ISO8601DateFormatter()
    
    guard let date1 = dateFormatter.date(from: String(dateOne)),
          let date2 = dateFormatter.date(from: String(dateTwo)) else {
      return false
    }
    
    let timeInterval = date1.timeIntervalSince(date2)
    return timeInterval > TimeInterval(margin)
  }
}

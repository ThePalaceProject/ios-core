//
//  EmailAddress.swift
//  Palace
//
//  Created by Maurice Carrier on 5/24/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//  https://www.swiftbysundell.com/articles/validating-email-addresses/
//

import Foundation

@objc class EmailAddress: NSObject, RawRepresentable, Codable {
  @objc let rawValue: String

  required init?(rawValue: String) {
    let sanitizedString = rawValue.replacingOccurrences(of: " ", with: "")
    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    let range = NSRange(sanitizedString.startIndex..<sanitizedString.endIndex, in: sanitizedString)
    let matches = detector?.matches(in: sanitizedString, range: range)

    guard let match = matches?.first, matches?.count == 1 else {
      return nil
    }

    guard match.url?.scheme == "mailto", match.range == range else {
      return nil
    }

    self.rawValue = sanitizedString.replacingOccurrences(of: "mailto:", with: "")
  }
}

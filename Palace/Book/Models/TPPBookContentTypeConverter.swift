//
//  TPPBookContentTypeConverter.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 8/17/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation

class TPPBookContentTypeConverter: NSObject {
  @objc class func stringValue(of bookContentType: TPPBookContentType) -> String {
    switch bookContentType {
    case .EPUB:
      return "Epub"
    case .audiobook:
      return "AudioBook"
    case .PDF:
      return "PDF"
    case .unsupported:
      return "Unsupported"
    default:
      return "Unexpected enum value: \(bookContentType.rawValue)"
    }
  }
}

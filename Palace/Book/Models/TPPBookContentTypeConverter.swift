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
    case .epub:
      "Epub"
    case .audiobook:
      "AudioBook"
    case .pdf:
      "PDF"
    case .unsupported:
      "Unsupported"
    default:
      "Unexpected enum value: \(bookContentType.rawValue)"
    }
  }
}

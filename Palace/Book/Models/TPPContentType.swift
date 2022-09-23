//
//  TPPContentType.swift
//  Palace
//
//  Created by Maurice Carrier on 9/19/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

@objc enum TPPBookContentType: Int {
  case epub
  case audiobook
  case pdf
  case unsupported
  
  static func from(mimeType: String?) -> TPPBookContentType {
    guard let mimeType = mimeType else {
      return .unsupported
    }
    
    if TPPOPDSAcquisitionPath.audiobookTypes().contains(mimeType) {
      return .audiobook
    } else if mimeType == ContentTypeEpubZip || mimeType == ContentTypeOctetStream {
      return .epub
    } else if mimeType == ContentTypeOpenAccessPDF {
      return .pdf
    }

    return .unsupported
  }
}

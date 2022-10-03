//
//  TPPBook+Extensions.swift
//  Palace
//
//  Created by Maurice Carrier on 6/7/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

@objc extension TPPBook {
  typealias Strings = DisplayStrings.TPPBook

  var bearerToken: String? {
    get {
      let _bearerToken: TPPKeychainVariable<String> = self.identifier.asKeychainVariable(with: bookTokenLock)
      return _bearerToken.read()
    }

    set {
      let keychainTransaction = TPPKeychainVariableTransaction(accountInfoLock: bookTokenLock)

      let _bearerToken: TPPKeychainVariable<String> = self.identifier.asKeychainVariable(with: bookTokenLock)
      keychainTransaction.perform {
        _bearerToken.write(newValue)
      }
    }
  }
  
  /// Readable book format based on its content type
  var format: String {
    switch defaultBookContentType {
    case .epub: return Strings.epubContentType
    case .pdf: return Strings.pdfContentType
    case .audiobook: return Strings.audiobookContentType
    case .unsupported: return Strings.unsupportedContentType
    }
  }

  var hasSample: Bool { sample != nil }
  var hasAudiobookSample: Bool { hasSample && defaultBookContentType == .audiobook }
}

extension TPPBook {
  var sample: Sample? {
    guard let acquisition = self.sampleAcquisition else { return nil }
    switch self.defaultBookContentType {
    case .epub, .pdf:
        guard let sampleType = SampleType(rawValue: acquisition.type) else { return nil }
        return EpubSample(url: acquisition.hrefURL, type: sampleType)
    case .audiobook:
        guard let sampleType = SampleType(rawValue: acquisition.type) else { return nil }
        return AudiobookSample(url: acquisition.hrefURL, type: sampleType)
    default:
      return nil
    }
  }
}

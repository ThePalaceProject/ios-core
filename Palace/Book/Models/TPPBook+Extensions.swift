//
//  TPPBook+Extensions.swift
//  Palace
//
//  Created by Maurice Carrier on 6/7/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation

@objc extension TPPBook {
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
  
  // TODO update once development is complete
//  var hasSamples: Bool { !samples.isEmpty }
  var hasSamples: Bool { true }
}

extension TPPBook {
  var samples: [Sample] {
    let sampleAcquisitions = self.acquisitions?.filter { $0.relation == .sample }

    switch self.defaultBookContentType() {
    case .EPUB, .PDF:
      return sampleAcquisitions?.compactMap { acquisition in
          return EpubSample(url: acquisition.hrefURL)
      } ?? []
    case .audiobook:
      return sampleAcquisitions?.compactMap { acquisition in
          return AudiobookSample(url: acquisition.hrefURL)
    } ?? []
    default:
      return []
    }
  }
}

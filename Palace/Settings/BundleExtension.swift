//
//  BundleExtension.swift
//  Palace
//
//  Created by Vladimir Fedorov on 30.09.2021.
//  Copyright © 2021 The Palace Project. All rights reserved.
//
import Foundation

@objc
enum TPPEnvironment: NSInteger {
  case debug, testFlight, production
}

/**
 This solution is based on this discussion:
 https://stackoverflow.com/questions/26081543/how-to-tell-at-runtime-whether-an-ios-app-is-running-through-a-testflight-beta-i
 */
extension Bundle {
  
  @objc
  var applicationEnvironment: TPPEnvironment {
    #if DEBUG
    return .debug
    #else
    guard let path = self.appStoreReceiptURL?.path else {
      return .production
    }
    // Sandbox receipt means the app is in TestFlight environment.
    if path.contains("sandboxReceipt") {
      return .testFlight
    } else {
      return .production
    }
    #endif
  }
}

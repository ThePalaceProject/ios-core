//
//  TPPDRMAuthorizingMock.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 10/14/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation
@testable import Palace

class TPPDRMAuthorizingMock: NSObject, TPPDRMAuthorizing {
  var workflowsInProgress = false
  let deviceID = "drmDeviceID"
  let userID = "drmUserID"
  
  // MARK: - Configurable Test Properties
  
  /// Controls what `isUserAuthorized` returns. Default is `true`.
  var isUserAuthorizedReturnValue = true
  
  /// Tracks whether `authorize` was called.
  var authorizeWasCalled = false
  
  /// Counts how many times `authorize` was called.
  var authorizeCallCount = 0
  
  /// Tracks whether `deauthorize` was called.
  var deauthorizeWasCalled = false
  
  /// Counts how many times `deauthorize` was called.
  var deauthorizeCallCount = 0

  func isUserAuthorized(_ userID: String!, withDevice device: String!) -> Bool {
    return isUserAuthorizedReturnValue
  }

  func authorize(withVendorID vendorID: String!, username: String!, password: String!, completion: ((Bool, Error?, String?, String?) -> Void)!) {
    authorizeWasCalled = true
    authorizeCallCount += 1
    completion(true, nil, deviceID, userID)
  }

  func deauthorize(withUsername username: String!, password: String!, userID: String!, deviceID: String!, completion: ((Bool, Error?) -> Void)!) {
    deauthorizeWasCalled = true
    deauthorizeCallCount += 1
    completion(true, nil)
  }
  
  /// Resets all tracking properties. Call in test tearDown.
  func reset() {
    isUserAuthorizedReturnValue = true
    authorizeWasCalled = false
    authorizeCallCount = 0
    deauthorizeWasCalled = false
    deauthorizeCallCount = 0
  }
}

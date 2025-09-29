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

  func isUserAuthorized(_: String!, withDevice _: String!) -> Bool {
    true
  }

  func authorize(
    withVendorID _: String!,
    username _: String!,
    password _: String!,
    completion: ((Bool, Error?, String?, String?) -> Void)!
  ) {
    completion(true, nil, deviceID, userID)
  }

  func deauthorize(
    withUsername _: String!,
    password _: String!,
    userID _: String!,
    deviceID _: String!,
    completion: ((Bool, Error?) -> Void)!
  ) {
    completion(true, nil)
  }
}

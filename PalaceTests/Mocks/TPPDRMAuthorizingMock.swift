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

  func isUserAuthorized(_ userID: String!, withDevice device: String!) -> Bool {
    return true
  }

  func authorize(withVendorID vendorID: String!, username: String!, password: String!, completion: ((Bool, Error?, String?, String?) -> Void)!) {
    completion(true, nil, deviceID, userID)
  }

  func deauthorize(withUsername username: String!, password: String!, userID: String!, deviceID: String!, completion: ((Bool, Error?) -> Void)!) {
    completion(true, nil)
  }
}

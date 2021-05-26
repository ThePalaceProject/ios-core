//
//  TPPUserAccountProviderMock.swift
//  The Palace Project
//
//  Created by Ernest Fan on 2021-03-11.
//  Copyright © 2021 NYPL Labs. All rights reserved.
//

import Foundation
@testable import Palace

class TPPUserAccountProviderMock: NSObject, NYPLUserAccountProvider {
  private static let userAccountMock = TPPUserAccountMock()
  
  var needsAuth: Bool
  
  static func sharedAccount(libraryUUID: String?) -> NYPLUserAccount {
    return userAccountMock
  }
  
  override init() {
    needsAuth = false
    
    super.init()
  }
}

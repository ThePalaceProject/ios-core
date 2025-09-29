//
//  TPPAgeCheckChoiceStorageMock.swift
//  The Palace Project
//
//  Created by Ernest Fan on 2021-03-11.
//  Copyright © 2021 NYPL Labs. All rights reserved.
//

import Foundation
@testable import Palace

class TPPAgeCheckChoiceStorageMock: NSObject, TPPAgeCheckChoiceStorage {
  var userPresentedAgeCheck: Bool

  override init() {
    userPresentedAgeCheck = false
    super.init()
  }
}

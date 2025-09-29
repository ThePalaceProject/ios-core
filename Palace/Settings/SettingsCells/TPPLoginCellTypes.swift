//
//  TPPLoginCellTypes.swift
//  The Palace Project
//
//  Created by Jacek Szyja on 23/06/2020.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation

// MARK: - TPPAuthMethodCellType

@objcMembers
class TPPAuthMethodCellType: NSObject {
  let authenticationMethod: AccountDetails.Authentication

  init(authenticationMethod: AccountDetails.Authentication) {
    self.authenticationMethod = authenticationMethod
  }
}

// MARK: - TPPInfoHeaderCellType

@objcMembers
class TPPInfoHeaderCellType: NSObject {
  let information: String

  init(information: String) {
    self.information = information
  }
}

// MARK: - TPPSamlIdpCellType

@objcMembers
class TPPSamlIdpCellType: NSObject {
  let idp: OPDS2SamlIDP

  init(idp: OPDS2SamlIDP) {
    self.idp = idp
  }
}

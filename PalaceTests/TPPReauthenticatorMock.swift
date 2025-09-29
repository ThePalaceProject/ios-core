//
//  TPPReauthenticatorMock.swift
//  PalaceTests
//
//  Created by Maurice Carrier on 9/6/23.
//  Copyright © 2023 The Palace Project. All rights reserved.
//

import Foundation
@testable import Palace

// MARK: - TPPReauthenticatorMock

@objc class TPPReauthenticatorMock: NSObject, Reauthenticator {
  var reauthenticationPerformed: Bool = false

  @objc func authenticateIfNeeded(
    _ user: TPPUserAccount,
    usingExistingCredentials _: Bool,
    authenticationCompletion: (() -> Void)?
  ) {
    reauthenticationPerformed = true
    user.credentials = TPPCredentials(authToken: "Token", barcode: "barcode", pin: "pin")
    authenticationCompletion?()
  }
}

extension TPPCredentials {
  init?(authToken: String? = nil, barcode: String? = nil, pin: String? = nil, expirationDate _: Date? = nil) {
    if let authToken = authToken {
      self = .token(authToken: authToken, barcode: barcode, pin: pin)
    } else if let barcode = barcode, let pin = pin {
      self = .barcodeAndPin(barcode: barcode, pin: pin)
    } else {
      return nil
    }
  }
}

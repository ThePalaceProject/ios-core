//
//  TPPSignInOutBusinessLogicUIDelegateMock.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 2/3/21.
//  Copyright © 2021 NYPL Labs. All rights reserved.
//

import Foundation
@testable import Palace

class TPPSignInOutBusinessLogicUIDelegateMock: NSObject, TPPSignInOutBusinessLogicUIDelegate {
  func businessLogicWillSignOut(_: TPPSignInBusinessLogic) {}

  func businessLogic(
    _: TPPSignInBusinessLogic,
    didEncounterSignOutError _: Error?,
    withHTTPStatusCode _: Int
  ) {}

  func businessLogicDidFinishDeauthorizing(_: TPPSignInBusinessLogic) {}

  func businessLogicDidCancelSignIn(_: TPPSignInBusinessLogic) {}

  var context = "Unit Tests Context"

  func businessLogicWillSignIn(_: TPPSignInBusinessLogic) {}

  func businessLogicDidCompleteSignIn(_: TPPSignInBusinessLogic) {}

  func businessLogic(
    _: TPPSignInBusinessLogic,
    didEncounterValidationError _: Error?,
    userFriendlyErrorTitle _: String?,
    andMessage _: String?
  ) {}

  func dismiss(animated _: Bool, completion: (() -> Void)?) {
    completion?()
  }

  func present(
    _: UIViewController,
    animated _: Bool,
    completion: (() -> Void)?
  ) {
    completion?()
  }

  var username: String? = "username"

  var pin: String? = "pin"

  var usernameTextField: UITextField?

  var PINTextField: UITextField?

  var forceEditability: Bool = false
}

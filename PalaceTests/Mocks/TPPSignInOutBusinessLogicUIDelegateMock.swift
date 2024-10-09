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
  func businessLogicWillSignOut(_ businessLogic: TPPSignInBusinessLogic) {
  }

  func businessLogic(_ logic: TPPSignInBusinessLogic,
                     didEncounterSignOutError error: Error?,
                     withHTTPStatusCode httpStatusCode: Int) {
  }

  func businessLogicDidFinishDeauthorizing(_ logic: TPPSignInBusinessLogic) {
  }

  func businessLogicDidCancelSignIn(_ businessLogic: TPPSignInBusinessLogic) {
  }

  var context = "Unit Tests Context"

  func businessLogicWillSignIn(_ businessLogic: TPPSignInBusinessLogic) {
  }

  func businessLogicDidCompleteSignIn(_ businessLogic: TPPSignInBusinessLogic) {
  }

  func businessLogic(_ logic: TPPSignInBusinessLogic,
                     didEncounterValidationError error: Error?,
                     userFriendlyErrorTitle title: String?,
                     andMessage message: String?) {
  }

  func dismiss(animated flag: Bool, completion: (() -> Void)?) {
    completion?()
  }

  func present(_ viewControllerToPresent: UIViewController,
               animated flag: Bool,
               completion: (() -> Void)?) {
    completion?()
  }

  var username: String? = "username"

  var pin: String? = "pin"

  var usernameTextField: UITextField? = nil

  var PINTextField: UITextField? = nil

  var forceEditability: Bool = false
}

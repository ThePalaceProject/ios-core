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
  
  // MARK: - Call Tracking for Tests
  var didCallWillSignOut = false
  var didCallDidFinishDeauthorizing = false
  var didFinishDeauthorizingHandler: (() -> Void)?
  
  // MARK: - Sign-In Flow Tracking
  var didCallWillSignIn = false
  var didCallDidCompleteSignIn = false
  var didCallDidCancelSignIn = false
  var didCallDidReceiveCredentials = false
  var willSignInCallCount = 0
  var didCompleteSignInCallCount = 0
  var didReceiveCredentialsCallCount = 0
  
  // Track isLoading state transitions
  var isLoading = false
  var loadingStateChanges: [Bool] = []
  
  func businessLogicWillSignOut(_ businessLogic: TPPSignInBusinessLogic) {
    didCallWillSignOut = true
  }

  func businessLogic(_ logic: TPPSignInBusinessLogic,
                     didEncounterSignOutError error: Error?,
                     withHTTPStatusCode httpStatusCode: Int) {
  }

  func businessLogicDidFinishDeauthorizing(_ logic: TPPSignInBusinessLogic) {
    didCallDidFinishDeauthorizing = true
    didFinishDeauthorizingHandler?()
  }

  func businessLogicDidCancelSignIn(_ businessLogic: TPPSignInBusinessLogic) {
    didCallDidCancelSignIn = true
    isLoading = false
    loadingStateChanges.append(false)
  }

  var context = "Unit Tests Context"

  func businessLogicWillSignIn(_ businessLogic: TPPSignInBusinessLogic) {
    didCallWillSignIn = true
    willSignInCallCount += 1
    isLoading = true
    loadingStateChanges.append(true)
  }

  func businessLogicDidCompleteSignIn(_ businessLogic: TPPSignInBusinessLogic) {
    didCallDidCompleteSignIn = true
    didCompleteSignInCallCount += 1
    isLoading = false
    loadingStateChanges.append(false)
  }
  
  func businessLogicDidReceiveCredentials(_ businessLogic: TPPSignInBusinessLogic) {
    didCallDidReceiveCredentials = true
    didReceiveCredentialsCallCount += 1
    // Simulate the real behavior: keep loading true as DRM processing starts
    isLoading = true
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

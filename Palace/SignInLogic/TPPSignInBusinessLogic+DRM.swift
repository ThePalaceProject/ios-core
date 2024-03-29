//
//  TPPSignInBusinessLogic+DRM.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 10/28/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation

#if FEATURE_DRM_CONNECTOR

extension TPPSignInBusinessLogic {

  /// Extract authorization credentials from binary data and perform DRM
  /// authorization request.
  ///
  /// - Parameters:
  ///   - data: The binary data containing the DRM authorization info.
  ///   - loggingContext: Information to report when logging errors.
  func drmAuthorizeUserData(_ data: Data, loggingContext: [String: Any]) {
    let profileDoc: UserProfileDocument
    do {
      profileDoc = try UserProfileDocument.fromData(data)
    } catch {
      TPPErrorLogger.logUserProfileDocumentAuthError(error as NSError,
                                                      summary:"SignIn: unable to parse user profile doc",
                                                      barcode: nil,
                                                      metadata:loggingContext)
      finalizeSignIn(forDRMAuthorization: false,
                     errorMessage: "Error parsing user profile document")
      return
    }

    if let authID = profileDoc.authorizationIdentifier {
      userAccount.setAuthorizationIdentifier(authID)
    } else {
      TPPErrorLogger.logError(withCode: .noAuthorizationIdentifier,
                               summary: "SignIn: no authorization ID in user profile doc",
                               metadata: loggingContext)
    }

    guard
      let drm = profileDoc.drm?.first,
      drm.vendor != nil,
      let clientToken = drm.clientToken else {

        let drm = profileDoc.drm?.first
        Log.info(#file, "\nLicensor: \(drm?.licensor ?? ["N/A": "N/A"])")

        TPPErrorLogger.logError(withCode: .noLicensorToken,
                                 summary: "SignIn: no licensor token in user profile doc",
                                 metadata: loggingContext)

        finalizeSignIn(forDRMAuthorization: false,
                       errorMessage: "No credentials were received to authorize access to books with DRM.")
        return
    }


    Log.info(#file, "\nLicensor: \(drm.licensor)")
    userAccount.setLicensor(drm.licensor)

    var licensorItems = clientToken.replacingOccurrences(of: "\n", with: "").components(separatedBy: "|")
    let tokenPassword = licensorItems.last
    licensorItems.removeLast()
    let tokenUsername = (licensorItems as NSArray).componentsJoined(by: "|")

    drmAuthorize(username: tokenUsername,
                 password: tokenPassword,
                 loggingContext: loggingContext)
  }

  /// Perform the DRM authorization request with the given credentials
  ///
  /// - Parameters:
  ///   - username: Adobe DRM token username.
  ///   - password: Adobe DRM token password. The only reason why this is
  ///   optional is because ADEPT already handles `nil` values, so we don't
  ///   have to do the same here.
  ///   - loggingContext: Information to report when logging errors.
  private func drmAuthorize(username: String,
                            password: String?,
                            loggingContext: [String: Any]) {

    let vendor = userAccount.licensor?["vendor"] as? String

    Log.info(#file, """
      ***DRM Auth/Activation Attempt***
      Token username: \(username)
      Token password: \(password ?? "N/A")
      VendorID: \(vendor ?? "N/A")
      """)

    drmAuthorizer?
      .authorize(withVendorID: vendor,
                 username: username,
                 password: password) { success, error, deviceID, userID in

                  // make sure to cancel the previously scheduled selector
                  // from the same thread it was scheduled on
                  TPPMainThreadRun.asyncIfNeeded { [weak self] in
                    if let self = self {
                      NSObject.cancelPreviousPerformRequests(withTarget: self)
                    }
                  }

                  Log.info(#file, """
                    Activation success: \(success)
                    Error: \(error?.localizedDescription ?? "N/A")
                    DeviceID: \(deviceID ?? "N/A")
                    UserID: \(userID ?? "N/A")
                    ***DRM Auth/Activation completion***
                    """)

                  var success = success

                  if success, let userID = userID, let deviceID = deviceID {
                    TPPMainThreadRun.asyncIfNeeded {
                      self.userAccount.setUserID(userID)
                      self.userAccount.setDeviceID(deviceID)
                    }
                  } else {
                    success = false
                    TPPErrorLogger.logLocalAuthFailed(error: error as NSError?,
                                                       library: self.libraryAccount,
                                                       metadata: loggingContext)
                  }

                  self.finalizeSignIn(forDRMAuthorization: success,
                                      error: error as NSError?)
    }

    TPPMainThreadRun.asyncIfNeeded { [weak self] in
      self?.perform(#selector(self?.dismissAfterUnexpectedDRMDelay), with: self, afterDelay: 25)
    }
  }

  @objc func dismissAfterUnexpectedDRMDelay(_ arg: Any) {
    TPPMainThreadRun.asyncIfNeeded {
      let title = Strings.Error.signInErrorTitle
      let message = Strings.Error.signInErrorDescription

      let alert = UIAlertController(title: title, message: message,
                                    preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: Strings.Generic.ok,
                                    style: .default) { [weak self] action in
                                      self?.uiDelegate?.dismiss(animated: true,
                                                                completion: nil)
      })

      TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert,
                                                    viewController: nil,
                                                    animated: true,
                                                    completion: nil)
    }
  }

  @objc func logInIfUserAuthorized() {
    if let drmAuthorizer = drmAuthorizer,
      !drmAuthorizer.isUserAuthorized(userAccount.userID,
                                      withDevice: userAccount.deviceID) {

      if userAccount.hasBarcodeAndPIN() && !isValidatingCredentials {
        if let usernameTextField = uiDelegate?.usernameTextField,
          let PINTextField = uiDelegate?.PINTextField
        {
          usernameTextField.text = userAccount.barcode
          PINTextField.text = userAccount.PIN
        }

        logIn()
      }
    }
  }
}

#endif

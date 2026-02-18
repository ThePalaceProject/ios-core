//
//  TPPSignInBusinessLogic+UI.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 10/26/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import UIKit

extension TPPSignInBusinessLogic {

  /// Finalizes the sign in process by updating the user account for the
  /// library we are signing in to and calling the completion handler in
  /// case that was set, as well as dismissing the presented view controller
  /// in case the `uiDelegate` was a modal.
  /// - Note: This does not log the error/message to Crashlytics.
  /// - Parameters:
  ///   - drmSuccess: whether the DRM authorization was successful or not.
  ///   Ignored if the app is built without DRM support.
  ///   - error: The error encountered during sign-in, if any.
  ///   - errorMessage: Error message to display, taking priority over `error`.
  ///   This can be a localization key.
  func finalizeSignIn(forDRMAuthorization drmSuccess: Bool,
                      error: Error? = nil,
                      errorMessage: String? = nil) {
    Log.info(#file, "🔐 [FINALIZE] finalizeSignIn() called")
    Log.info(#file, "🔐 [FINALIZE] DRM success: \(drmSuccess)")
    Log.info(#file, "🔐 [FINALIZE] Error: \(error?.localizedDescription ?? "nil")")
    Log.info(#file, "🔐 [FINALIZE] Library account ID: \(libraryAccountID)")
    Log.info(#file, "🔐 [FINALIZE] Auth token available: \(authToken != nil)")
    Log.info(#file, "🔐 [FINALIZE] Patron available: \(patron != nil)")
    Log.info(#file, "🔐 [FINALIZE] Cookies available: \(cookies?.count ?? 0)")
    
    TPPMainThreadRun.asyncIfNeeded {
      Log.info(#file, "🔐 [FINALIZE] Running on main thread")
      
      defer {
        Log.info(#file, "🔐 [FINALIZE] Calling businessLogicDidCompleteSignIn")
        self.uiDelegate?.businessLogicDidCompleteSignIn(self)
      }

      Log.info(#file, "🔐 [FINALIZE] Calling updateUserAccount()...")
      self.updateUserAccount(forDRMAuthorization: drmSuccess,
                             withBarcode: self.uiDelegate?.username,
                             pin: self.uiDelegate?.pin,
                             authToken: self.authToken,
                             expirationDate: self.authTokenExpiration,
                             patron: self.patron,
                             cookies: self.cookies
      )
      Log.info(#file, "🔐 [FINALIZE] updateUserAccount() completed")
      
      // CRITICAL: Verify credentials were persisted to keychain
      // This refresh forces re-read from keychain to confirm persistence
      let credentialsPersisted = self.userAccount.refreshCredentialsFromKeychain()
      if credentialsPersisted {
        Log.info(#file, "🔐 [FINALIZE] ✅ Credentials verified as persisted to keychain")
      } else {
        Log.error(#file, "🔐 [FINALIZE] ❌ WARNING: Credentials may not have been persisted!")
        Log.error(#file, "🔐 [FINALIZE]   Library ID: \(self.libraryAccountID)")
        Log.error(#file, "🔐 [FINALIZE]   Auth token was: \(self.authToken != nil)")
      }

      #if FEATURE_DRM_CONNECTOR
      guard drmSuccess else {
        Log.warn(#file, "🔐 [FINALIZE] ⚠️ DRM authorization failed - showing error alert")
        NotificationCenter.default.post(name: .TPPSyncEnded, object: nil)

        let alert = TPPAlertUtils.alert(title: Strings.Error.loginErrorTitle,
                                         message: errorMessage,
                                         error: error as NSError?)
        TPPPresentationUtils.safelyPresent(alert, animated: true)
        return
      }
      #endif

      // no need to force a login, as we just logged in successfully
      self.ignoreSignedInState = false
      Log.info(#file, "🔐 [FINALIZE] Set ignoreSignedInState = false")

      let completionHandler = self.refreshAuthCompletion
      self.refreshAuthCompletion = nil

      if !self.isLoggingInAfterSignUp, let vc = self.uiDelegate as? UIViewController {
        // don't dismiss anything if the vc is not even on the view stack
        if vc.view.superview != nil || vc.presentingViewController != nil {
          Log.info(#file, "🔐 [FINALIZE] Dismissing UI and calling completion handler")
          self.uiDelegate?.dismiss(animated: true, completion: completionHandler)
          return
        }
      }

      Log.info(#file, "🔐 [FINALIZE] Calling completion handler directly")
      completionHandler?()
      Log.info(#file, "🔐 [FINALIZE] ✅ finalizeSignIn() completed successfully")
    }
  }

  /// Performs log out verifying that no book registry syncing
  /// or book download/return authorizations are in progress.
  /// - Returns: An alert the caller needs to present in case there's syncing
  /// or book downloading/returning currently happening.
  @objc func logOutOrWarn() -> UIAlertController? {

    let title = Strings.TPPSigninBusinessLogic.signout
    let msg: String
    if bookRegistry.isSyncing {
      msg = Strings.TPPSigninBusinessLogic.annotationSyncMessage
    } else if let drm = drmAuthorizer, drm.workflowsInProgress {
      msg = Strings.TPPSigninBusinessLogic.pendingDownloadMessage
    } else {
      performLogOut()
      return nil
    }

    let alert = UIAlertController(title: title,
                                  message: msg,
                                  preferredStyle: .alert)
    alert.addAction(
      UIAlertAction(title: title,
                    style: .destructive,
                    handler: { _ in
                      self.performLogOut()
      }))
    alert.addAction(
      UIAlertAction(title: Strings.Generic.wait,
                    style: .cancel,
                    handler: nil))

    return alert
  }
}

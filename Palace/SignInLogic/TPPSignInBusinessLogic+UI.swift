//
//  TPPSignInBusinessLogic+UI.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 10/26/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import UIKit
import PalaceBookRegistry

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
        // `TPPMainThreadRun.asyncIfNeeded` guarantees this body runs on the main
        // thread. The body touches `@MainActor` state (`UIViewController.view`/
        // `.superview`/`.presentingViewController`, `TPPAlertUtils`,
        // `TPPPresentationUtils`), so assert the isolation the hop already
        // provides. `assumeIsolated` preserves the exact sync-if-already-on-main
        // ordering the `defer`-driven `businessLogicDidCompleteSignIn` callback
        // depends on (a `Task { @MainActor }` swap would defer and reorder it).
        TPPMainThreadRun.asyncIfNeeded {
          MainActor.assumeIsolated {
            defer {
                self.uiDelegate?.businessLogicDidCompleteSignIn(self)
            }

            // Cancel any pending sign-out for this library so that
            // a stale DRM deauthorization callback cannot wipe these new
            // credentials after we save them.
            self.cancelPendingSignOut()

            let barcode = self.capturedBarcode ?? self.uiDelegate?.username
            let pin = self.capturedPin ?? self.uiDelegate?.pin

            self.updateUserAccount(forDRMAuthorization: drmSuccess,
                                   withBarcode: barcode,
                                   pin: pin,
                                   authToken: self.authToken,
                                   expirationDate: self.authTokenExpiration,
                                   patron: self.patron,
                                   cookies: self.cookies
            )

            #if FEATURE_DRM_CONNECTOR
            guard drmSuccess else {
                NotificationCenter.default.post(name: .TPPSyncEnded, object: nil)

                let alert = TPPAlertUtils.alert(title: Strings.Error.loginErrorTitle,
                                                message: errorMessage,
                                                error: error as NSError?)
                TPPPresentationUtils.safelyPresent(alert, animated: true)
                return
            }
            #endif

            // ignoreSignedInState is cleared by `.userAccountUpdated` dispatch
            // inside `updateUserAccount`. Restore the persisted auth state too.
            self.userAccount.markLoggedIn()

            let completionHandler = self.refreshAuthCompletion
            self.refreshAuthCompletion = nil

            if !self.isLoggingInAfterSignUp, let vc = self.uiDelegate as? UIViewController {
                if vc.view.superview != nil || vc.presentingViewController != nil {
                    self.uiDelegate?.dismiss(animated: true, completion: completionHandler)
                    return
                }
            }

            completionHandler?()
          }
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

        // `UIAlertController`/`UIAlertAction` inits + `addAction` are
        // `@MainActor`-isolated, and the `UIAlertAction` handler is a
        // non-Sendable `@MainActor` closure. `logOutOrWarn()` is a synchronous
        // UI method whose only callers are `@MainActor` (`AccountDetailViewModel`
        // is `@MainActor`; the developer-settings VC is a `UIViewController`),
        // so the main-actor precondition provably holds. `assumeIsolated`
        // asserts that for the `complete`-mode checker without a signature
        // change (keeping every `@objc`/synchronous caller source-compatible)
        // and without deferring — the alert must be returned synchronously.
        return MainActor.assumeIsolated {
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
}

//
//  TPPSignInBusinessLogic+DRM.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 10/28/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation
import PalaceLogging

#if FEATURE_DRM_CONNECTOR

extension TPPSignInBusinessLogic {

    /// Saves DRM credentials from the user profile document without performing
    /// Adobe device activation. Activation is deferred to borrow time (PP-3649).
    ///
    /// Profile document parsing is best-effort: if it fails, sign-in still
    /// succeeds because the server already accepted the patron's credentials
    /// (HTTP 200). Wiping credentials on a parse failure was the cause of
    /// (barcode disappearing after sign-in).
    ///
    /// - Parameters:
    ///   - data: The binary data containing the DRM authorization info.
    ///   - loggingContext: Information to report when logging errors.
    func saveDRMCredentials(_ data: Data, loggingContext: [String: Any]) {
        guard let profileDoc = try? UserProfileDocument.fromData(data) else {
            TPPErrorLogger.logUserProfileDocumentAuthError(
                NSError(domain: "ProfileDoc", code: -1),
                summary: "SignIn: unable to parse user profile doc (non-fatal)",
                barcode: uiDelegate?.username,
                metadata: loggingContext)
            finalizeSignIn(forDRMAuthorization: true)
            return
        }

        if let authID = profileDoc.authorizationIdentifier {
            userAccount.setAuthorizationIdentifier(authID)
        } else {
            TPPErrorLogger.logError(withCode: .noAuthorizationIdentifier,
                                    summary: "SignIn: no authorization ID in user profile doc",
                                    metadata: loggingContext)
        }

        if let drm = profileDoc.drm?.first,
           drm.vendor != nil,
           drm.clientToken != nil {
            Log.info(#file, "Saving DRM licensor credentials (activation deferred to borrow time)")
            userAccount.setLicensor(drm.licensor)
        } else {
            Log.info(#file, "No Adobe DRM credentials in profile doc — library may not use Adobe DRM")
        }

        finalizeSignIn(forDRMAuthorization: true)
    }

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
                                                           summary: "SignIn: unable to parse user profile doc",
                                                           barcode: nil,
                                                           metadata: loggingContext)
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

        // Box the non-Sendable loggingContext in the (@MainActor) enclosing
        // scope so the @Sendable authorize-completion captures the Sendable box,
        // not the raw [String: Any].
        let contextBox = DRMLoggingContextBox(loggingContext: loggingContext)

        drmAuthorizer?
            .authorize(withVendorID: vendor,
                       username: username,
                       password: password) { success, error, deviceID, userID in

                // Swift 6: the @objc DRM protocol completion is @Sendable
                // (NYPLADEPT's ObjC block imports @Sendable) and fires from the
                // Adobe activation thread. All work below touches @MainActor
                // state (userAccount / libraryAccount / finalizeSignIn), so hop
                // to the main actor once, carrying the non-Sendable error +
                // loggingContext in a documented box. Behavior preserved: the
                // cancel -> set-IDs -> finalize order is unchanged and now runs
                // as one main-actor unit. This is ordering-neutral, not a fix:
                // the off-main callback path already serialized these steps via
                // main-queue FIFO (and finalizeSignIn does not read the IDs).
                let box = DRMAuthCompletionBox(error: error, loggingContext: contextBox.loggingContext)
                Task { @MainActor in

                    // cancel the previously scheduled unexpected-delay selector
                    NSObject.cancelPreviousPerformRequests(withTarget: self)

                    Log.info(#file, """
                        Activation success: \(success)
                        Error: \(box.error?.localizedDescription ?? "N/A")
                        DeviceID: \(deviceID ?? "N/A")
                        UserID: \(userID ?? "N/A")
                        ***DRM Auth/Activation completion***
                        """)

                    var success = success

                    if success, let userID = userID, let deviceID = deviceID {
                        self.userAccount.setUserID(userID)
                        self.userAccount.setDeviceID(deviceID)
                    } else {
                        success = false
                        TPPErrorLogger.logLocalAuthFailed(error: box.error as NSError?,
                                                          library: self.libraryAccount,
                                                          metadata: box.loggingContext)
                    }

                    self.finalizeSignIn(forDRMAuthorization: success,
                                        error: box.error as NSError?)
                }
            }

        // Skip the 25-second timeout timer in test environments to prevent
        // the timer from keeping the test process alive after tests complete
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if !isRunningTests {
            TPPMainThreadRun.asyncIfNeeded { [weak self] in
                self?.perform(#selector(self?.dismissAfterUnexpectedDRMDelay), with: self, afterDelay: 25)
            }
        }
    }

    @objc func dismissAfterUnexpectedDRMDelay(_ arg: Any) {
        // `UIAlertController`/`UIAlertAction` + `TPPAlertUtils` are
        // `@MainActor`-isolated; `asyncIfNeeded` already guarantees main-thread
        // execution, so assert the isolation for the `complete`-mode checker.
        TPPMainThreadRun.asyncIfNeeded {
            MainActor.assumeIsolated {
                let title = Strings.Error.signInErrorTitle
                let message = Strings.Error.signInErrorDescription

                let alert = UIAlertController(title: title, message: message,
                                              preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: Strings.Generic.ok,
                                              style: .default) { [weak self] _ in
                    self?.uiDelegate?.dismiss(animated: true,
                                              completion: nil)
                })

                TPPAlertUtils.presentFromViewControllerOrNil(alertController: alert,
                                                             viewController: nil,
                                                             animated: true,
                                                             completion: nil)
            }
        }
    }

    @objc func logInIfUserAuthorized() {
        if let drmAuthorizer = drmAuthorizer,
           !drmAuthorizer.isUserAuthorized(userAccount.userID,
                                           withDevice: userAccount.deviceID) {

            if userAccount.hasBarcodeAndPIN() && !isValidatingCredentials {
                // `UITextField.text` is `@MainActor`-isolated; this `@objc`
                // DRM entry point runs on the main actor. Assert the isolation
                // for the `complete`-mode checker without changing the sync
                // signature.
                MainActor.assumeIsolated {
                    if let usernameTextField = uiDelegate?.usernameTextField,
                       let PINTextField = uiDelegate?.PINTextField {
                        usernameTextField.text = userAccount.barcode
                        PINTextField.text = userAccount.PIN
                    }
                }

                logIn()
            }
        }
    }
}

#endif

/// Carrier for the non-Sendable `error` / `loggingContext` handed to the
/// `@Sendable` DRM-authorization completion and hopped once onto the main
/// actor. `@unchecked Sendable`: both fields are read-only after construction
/// and consumed on the main actor exactly once.
private struct DRMAuthCompletionBox: @unchecked Sendable {
    let error: Error?
    let loggingContext: [String: Any]
}

/// Carrier for the non-Sendable `loggingContext` captured by the `@Sendable`
/// DRM-authorization completion. Built in the enclosing `@MainActor` scope;
/// read-only after construction.
private struct DRMLoggingContextBox: @unchecked Sendable {
    let loggingContext: [String: Any]
}

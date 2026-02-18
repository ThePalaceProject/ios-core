//
//  TPPSignInBusinessLogic+SignOut.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 11/3/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation
import WebKit

extension TPPSignInBusinessLogic {

  /// Main entry point for logging a user out.
  ///
  /// - Important: Requires to be called from the main thread.
func performLogOut() {
#if FEATURE_DRM_CONNECTOR
    uiDelegate?.businessLogicWillSignOut(self)
    
    guard var request = self.makeRequest(for: .signOut, context: "Sign Out") else {
      return
    }

    request.timeoutInterval = 45
    
    let barcode = userAccount.barcode
    networker.executeRequest(request, enableTokenRefresh: false) { [weak self] result in
      switch result {
      case .success(let data, let response):
        self?.processLogOut(data: data,
                            response: response,
                            for: request,
                            barcode: barcode)
      case .failure(let errorWithProblemDoc, let response):
        TPPUserAccount.sharedAccount().removeAll()        
        self?.processLogOutError(errorWithProblemDoc,
                                 response: response,
                                 for: request,
                                 barcode: barcode)
      }
    }
    
#else
    if self.bookRegistry.isSyncing {
      let alert = TPPAlertUtils.alert(
        title: "SettingsAccountViewControllerCannotLogOutTitle",
        message: "SettingsAccountViewControllerCannotLogOutMessage")
      uiDelegate?.present(alert, animated: true, completion: nil)
    } else {
      completeLogOutProcess()
    }
#endif
  }

  #if FEATURE_DRM_CONNECTOR
  private func processLogOut(data: Data,
                             response: URLResponse?,
                             for request: URLRequest,
                             barcode: String?) {
    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

    let profileDoc: UserProfileDocument
    do {
      profileDoc = try UserProfileDocument.fromData(data)
    } catch {
      Log.error(#file, "Unable to parse user profile at sign out (HTTP \(statusCode): Adobe device deauthorization won't be possible.")
      TPPErrorLogger.logUserProfileDocumentAuthError(
        error as NSError,
        summary: "SignOut: unable to parse user profile doc",
        barcode: barcode,
        metadata: [
          "Request": request.loggableString,
          "Response": response ?? "N/A",
          "HTTP status code": statusCode
      ])
      self.uiDelegate?.businessLogic(self,
                                     didEncounterSignOutError: error,
                                     withHTTPStatusCode: statusCode)
      return
    }

    if let drm = profileDoc.drm?.first,
      let clientToken = drm.clientToken, drm.vendor != nil {

      // Set the fresh Adobe token info into the user account so that the
      // following `deauthorizeDevice` call can use it.
      self.userAccount.setLicensor(drm.licensor)
      Log.info(#file, "Licensor token updated to \(clientToken) for adobe user ID \(self.userAccount.userID ?? "N/A")")
    } else {
      Log.error(#file, "Licensor token invalid: \(profileDoc.toJson())")
    }

    self.deauthorizeDevice()
  }

  private func processLogOutError(_ errorWithProblemDoc: TPPUserFriendlyError,
                                  response: URLResponse?,
                                  for request: URLRequest,
                                  barcode: String?) {
    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

    if statusCode == 401 {
      self.deauthorizeDevice()
    }

    TPPErrorLogger.logNetworkError(
      errorWithProblemDoc,
      summary: "SignOut: token refresh failed",
      request: request,
      response: response,
      metadata: [
        "AuthMethod": self.selectedAuthentication?.methodDescription ?? "N/A",
        "Hashed barcode": barcode?.md5hex() ?? "N/A",
        "HTTP status code": statusCode])

    self.uiDelegate?.businessLogic(self,
                                   didEncounterSignOutError: errorWithProblemDoc,
                                   withHTTPStatusCode: statusCode)
  }
  #endif
  
  private func completeLogOutProcess() {
    // Deregister FCM token BEFORE removing credentials (DELETE request needs auth)
    // Also reset the flag so token re-registers on next sign-in
    if let account = AccountsManager.shared.account(libraryAccountID) {
      NotificationService.shared.deleteToken(for: account)
      account.hasUpdatedToken = false
    }
    
    bookDownloadsCenter.reset(libraryAccountID)
    bookRegistry.reset(libraryAccountID)
    userAccount.removeAll()
    selectedIDP = nil
    
    // Clear WebView data to fully sign out of SAML/OAuth IdPs (e.g., Google)
    // Without this, the IdP session remains cached and auto-signs in on next attempt
    // CRITICAL: Wait for WebView data to be cleared BEFORE notifying UI that sign-out is complete
    // This prevents SAML IdP auto-sign-in when user tries to borrow after signing out
    clearWebViewData { [weak self] in
      // UI delegate callback MUST be on main thread
      // (This method can be called from Adobe DRM callback on background thread)
      DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        self.uiDelegate?.businessLogicDidFinishDeauthorizing(self)
      }
    }
  }
  
  /// Clears all WebView data including cookies, cache, local storage, and session data.
  /// This ensures SAML/OAuth identity providers are fully signed out.
  /// - Parameter completion: Called when all WebView data and cookies have been cleared.
  ///   This is critical for SAML sign-out to prevent IdP auto-sign-in.
  private func clearWebViewData(completion: @escaping () -> Void) {
    // Skip WebKit cleanup in test environments (no UI context)
    #if DEBUG
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
      completion()
      return
    }
    #endif
    
    // WebKit operations MUST run on the main thread
    DispatchQueue.main.async {
      let dataStore = WKWebsiteDataStore.default()
      let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
      
      dataStore.fetchDataRecords(ofTypes: dataTypes) { records in
        dataStore.removeData(ofTypes: dataTypes, for: records) {
          // Also clear shared cookie storage (synchronous)
          if let cookies = HTTPCookieStorage.shared.cookies {
            for cookie in cookies {
              HTTPCookieStorage.shared.deleteCookie(cookie)
            }
          }
          
          // CRITICAL: Only call completion AFTER both WebKit data AND cookies are cleared
          // This ensures SAML IdP sessions are fully invalidated before sign-out completes
          completion()
        }
      }
    }
  }

  #if FEATURE_DRM_CONNECTOR
  private func deauthorizeDevice() {
    guard let licensor = userAccount.licensor else {
      Log.warn(#file, "No Licensor available to deauthorize device. Will remove user credentials anyway.")
      TPPErrorLogger.logInvalidLicensor(withAccountID: libraryAccountID)
      completeLogOutProcess()
      return
    }

    var licensorItems = (licensor["clientToken"] as? String)?
      .replacingOccurrences(of: "\n", with: "")
      .components(separatedBy: "|")
    let tokenPassword = licensorItems?.last
    licensorItems?.removeLast()
    let tokenUsername = licensorItems?.joined(separator: "|")
    let adobeUserID = userAccount.userID
    let adobeDeviceID = userAccount.deviceID

    if let drmAuthorizer = drmAuthorizer {
      drmAuthorizer.deauthorize(
        withUsername: tokenUsername,
        password: tokenPassword,
        userID: adobeUserID,
        deviceID: adobeDeviceID) { [weak self] success, error in
          if !success {
            // DRM deauthorization failures are expected (e.g., E_DEACT_USER_MISMATCH when user changes PIN)
            // Just log locally and continue - the user should still be able to log out
            Log.warn(#file, "DRM deauthorization failed (expected): \(error?.localizedDescription ?? "unknown")")
          }

          // Check if self was deallocated during the DRM callback
          guard let strongSelf = self else {
            // Skip WebKit cleanup in test environments (no UI context)
            #if DEBUG
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
              return
            }
            #endif
            
            // Even if self is nil, we need to complete the logout process
            // Call static/global cleanup methods directly
            DispatchQueue.main.async {
              // Clear WebView data directly
              let dataStore = WKWebsiteDataStore.default()
              let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
              dataStore.fetchDataRecords(ofTypes: dataTypes) { records in
                dataStore.removeData(ofTypes: dataTypes, for: records) {
                  // Clear cookies AFTER WebView data to ensure complete cleanup
                  if let cookies = HTTPCookieStorage.shared.cookies {
                    for cookie in cookies {
                      HTTPCookieStorage.shared.deleteCookie(cookie)
                    }
                  }
                }
              }
            }
            return
          }
          
          strongSelf.completeLogOutProcess()
      }
    } else {
      self.completeLogOutProcess()
    }
  }
  #endif
}

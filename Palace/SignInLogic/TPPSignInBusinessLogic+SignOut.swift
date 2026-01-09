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
    Log.info(#file, "🚪 [LOGOUT] performLogOut() called on thread: \(Thread.isMainThread ? "MAIN" : "BACKGROUND")")
    
#if FEATURE_DRM_CONNECTOR
    Log.info(#file, "🚪 [LOGOUT] DRM connector enabled - starting DRM sign-out flow")
    
    uiDelegate?.businessLogicWillSignOut(self)
    Log.info(#file, "🚪 [LOGOUT] Called uiDelegate.businessLogicWillSignOut")
    
    guard var request = self.makeRequest(for: .signOut, context: "Sign Out") else {
      Log.error(#file, "🚪 [LOGOUT] Failed to create sign-out request!")
      return
    }

    request.timeoutInterval = 45
    Log.info(#file, "🚪 [LOGOUT] Making sign-out network request to: \(request.url?.absoluteString ?? "nil")")
    
    let barcode = userAccount.barcode
    networker.executeRequest(request, enableTokenRefresh: false) { [weak self] result in
      Log.info(#file, "🚪 [LOGOUT] Network request completed on thread: \(Thread.isMainThread ? "MAIN" : "BACKGROUND")")
      switch result {
      case .success(let data, let response):
        Log.info(#file, "🚪 [LOGOUT] Network request SUCCESS - calling processLogOut")
        self?.processLogOut(data: data,
                            response: response,
                            for: request,
                            barcode: barcode)
      case .failure(let errorWithProblemDoc, let response):
        Log.info(#file, "🚪 [LOGOUT] Network request FAILED: \(errorWithProblemDoc.localizedDescription)")
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
    Log.info(#file, "🚪 [LOGOUT] processLogOut() called")
    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
    Log.info(#file, "🚪 [LOGOUT] HTTP status code: \(statusCode)")

    let profileDoc: UserProfileDocument
    do {
      profileDoc = try UserProfileDocument.fromData(data)
      Log.info(#file, "🚪 [LOGOUT] Parsed user profile document successfully")
    } catch {
      Log.error(#file, "🚪 [LOGOUT] Failed to parse user profile: \(error)")
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
      Log.info(#file, "🚪 [LOGOUT] Calling uiDelegate.businessLogic(didEncounterSignOutError)")
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
      Log.info(#file, "\nLicensory token updated to \(clientToken) for adobe user ID \(self.userAccount.userID ?? "N/A")")
    } else {
      Log.error(#file, "\nLicensor token invalid: \(profileDoc.toJson())")
    }

    Log.info(#file, "🚪 [LOGOUT] Calling deauthorizeDevice()")
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
    Log.info(#file, "🚪 [LOGOUT] completeLogOutProcess() called on thread: \(Thread.isMainThread ? "MAIN" : "BACKGROUND")")
    
    Log.info(#file, "🚪 [LOGOUT] Resetting bookDownloadsCenter...")
    bookDownloadsCenter.reset(libraryAccountID)
    
    Log.info(#file, "🚪 [LOGOUT] Resetting bookRegistry...")
    bookRegistry.reset(libraryAccountID)
    
    Log.info(#file, "🚪 [LOGOUT] Calling userAccount.removeAll()...")
    userAccount.removeAll()
    
    selectedIDP = nil
    Log.info(#file, "🚪 [LOGOUT] Cleared selectedIDP")
    
    // Clear WebView data to fully sign out of SAML/OAuth IdPs (e.g., Google)
    // Without this, the IdP session remains cached and auto-signs in on next attempt
    Log.info(#file, "🚪 [LOGOUT] Calling clearWebViewData()...")
    clearWebViewData()
    
    // UI delegate callback MUST be on main thread
    // (This method can be called from Adobe DRM callback on background thread)
    Log.info(#file, "🚪 [LOGOUT] Dispatching uiDelegate callback to main thread...")
    DispatchQueue.main.async { [weak self] in
      Log.info(#file, "🚪 [LOGOUT] Main thread callback executing - self is \(self == nil ? "NIL" : "valid")")
      guard let self = self else {
        Log.error(#file, "🚪 [LOGOUT] ERROR: self is nil in main thread callback!")
        return
      }
      Log.info(#file, "🚪 [LOGOUT] Calling uiDelegate.businessLogicDidFinishDeauthorizing - delegate is \(self.uiDelegate == nil ? "NIL" : "valid")")
      self.uiDelegate?.businessLogicDidFinishDeauthorizing(self)
      Log.info(#file, "🚪 [LOGOUT] ✅ uiDelegate.businessLogicDidFinishDeauthorizing completed!")
    }
  }
  
  /// Clears all WebView data including cookies, cache, local storage, and session data.
  /// This ensures SAML/OAuth identity providers are fully signed out.
  private func clearWebViewData() {
    // WebKit operations MUST run on the main thread
    DispatchQueue.main.async {
      let dataStore = WKWebsiteDataStore.default()
      let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
      
      dataStore.fetchDataRecords(ofTypes: dataTypes) { records in
        Log.info(#file, "Clearing \(records.count) WebView data records for sign-out")
        dataStore.removeData(ofTypes: dataTypes, for: records) {
          Log.info(#file, "WebView data cleared successfully")
        }
      }
      
      // Also clear shared cookie storage
      if let cookies = HTTPCookieStorage.shared.cookies {
        Log.info(#file, "Clearing \(cookies.count) HTTP cookies for sign-out")
        for cookie in cookies {
          HTTPCookieStorage.shared.deleteCookie(cookie)
        }
      }
    }
  }

  #if FEATURE_DRM_CONNECTOR
  private func deauthorizeDevice() {
    Log.info(#file, "🚪 [LOGOUT] deauthorizeDevice() called on thread: \(Thread.isMainThread ? "MAIN" : "BACKGROUND")")
    
    guard let licensor = userAccount.licensor else {
      Log.warn(#file, "🚪 [LOGOUT] No Licensor available - skipping DRM deauthorization")
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
 
    Log.info(#file, """
    🚪 [LOGOUT] ***DRM Deactivation Attempt***
    Licensor: \(licensor)
    Token Username: \(tokenUsername ?? "N/A")
    Token Password: \(tokenPassword ?? "N/A")
    AdobeUserID: \(adobeUserID ?? "N/A")
    AdobeDeviceID: \(adobeDeviceID ?? "N/A")
    """)

    if let drmAuthorizer = drmAuthorizer {
      Log.info(#file, "🚪 [LOGOUT] DRM authorizer exists - calling deauthorize()...")
      drmAuthorizer.deauthorize(
        withUsername: tokenUsername,
        password: tokenPassword,
        userID: adobeUserID,
        deviceID: adobeDeviceID) { [weak self] success, error in
          Log.info(#file, "🚪 [LOGOUT] DRM deauthorize callback received on thread: \(Thread.isMainThread ? "MAIN" : "BACKGROUND")")
          Log.info(#file, "🚪 [LOGOUT] DRM deauthorize result: success=\(success), error=\(error?.localizedDescription ?? "nil")")
          
          if success {
            Log.info(#file, "🚪 [LOGOUT] *** Successful DRM Deactivation ***")
          } else {
            Log.warn(#file, "🚪 [LOGOUT] DRM deauthorization failed, but continuing with logout")
            // Even though we failed, let the user continue to log out.
            // The most likely reason is a user changing their PIN.
            TPPErrorLogger.logError(error,
                                     summary: "User lost an activation on signout: ADEPT error",
                                     metadata: [
                                      "AdobeUserID": adobeUserID ?? "N/A",
                                      "DeviceID": adobeDeviceID ?? "N/A",
                                      "Licensor": licensor,
                                      "AdobeTokenUsername": tokenUsername ?? "N/A",
                                      "AdobeTokenPassword": tokenPassword ?? "N/A"])
          }

          Log.info(#file, "🚪 [LOGOUT] Calling completeLogOutProcess() from DRM callback...")
          self?.completeLogOutProcess()
          Log.info(#file, "🚪 [LOGOUT] completeLogOutProcess() returned from DRM callback")
      }
    } else {
      Log.warn(#file, "🚪 [LOGOUT] No DRM authorizer - calling completeLogOutProcess() directly")
      self.completeLogOutProcess()
    }
  }
  #endif
}

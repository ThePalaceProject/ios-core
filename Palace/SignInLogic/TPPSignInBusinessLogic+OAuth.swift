//
//  TPPSignInBusinessLogic+OAuth.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 10/9/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation

extension TPPSignInBusinessLogic {
  //----------------------------------------------------------------------------
  func oauthLogIn() {
    // for this kind of authentication, we want to redirect user to Safari to
    // conduct the process
    guard let oauthURL = selectedAuthentication?.oauthIntermediaryUrl else {
      TPPErrorLogger.logError(withCode: .noURL,
                               summary: "Nil OAuth intermediary URL",
                               metadata: [
                                "authMethod": selectedAuthentication?.methodDescription ?? "N/A",
                                "context": uiDelegate?.context ?? "N/A"])
      return
    }

    guard var urlComponents = URLComponents(url: oauthURL, resolvingAgainstBaseURL: true) else {
      TPPErrorLogger.logError(withCode: .malformedURL,
                               summary: "Malformed OAuth intermediary URL",
                               metadata: [
                                "authMethod": selectedAuthentication?.methodDescription ?? "N/A",
                                "OAUth Intermediary URL": oauthURL.absoluteString,
                                "context": uiDelegate?.context ?? "N/A"])
      return
    }

    let redirectParam = URLQueryItem(
      name: "redirect_uri",
      value: urlSettingsProvider.universalLinksURL.absoluteString)
    urlComponents.queryItems?.append(redirectParam)

    guard let finalURL = urlComponents.url else {
      TPPErrorLogger.logError(withCode: .malformedURL,
                               summary: "Unable to create URL for OAuth login",
                               metadata: [
                                "authMethod": selectedAuthentication?.methodDescription ?? "N/A",
                                "OAUth Intermediary URL": oauthURL.absoluteString,
                                "redirectParam": redirectParam,
                                "context": uiDelegate?.context ?? "N/A"])
      return
    }

    NotificationCenter.default
      .addObserver(self,
                   selector: #selector(handleRedirectURL(_:)),
                   name: .TPPAppDelegateDidReceiveCleverRedirectURL,
                   object: nil)

    TPPMainThreadRun.asyncIfNeeded {
      UIApplication.shared.open(finalURL)
    }
  }

  //----------------------------------------------------------------------------
  private func universalLinkRedirectURLContainsPayload(_ urlStr: String) -> Bool {
    return urlStr.contains("error")
      || (urlStr.contains("access_token") && urlStr.contains("patron_info"))
  }

  //----------------------------------------------------------------------------
  
  // As per Apple Developer Documentation, selector for NSNotification must have
  // one and only one argument (an instance of NSNotification).
  // See https://developer.apple.com/documentation/foundation/nsnotificationcenter/1415360-addobserver
  // for more information.
  @objc func handleRedirectURL(_ notification: Notification) {
    self.handleRedirectURL(notification, completion: nil)
  }
  
  // this is used by both Clever and SAML authentication
  @objc func handleRedirectURL(_ notification: Notification, completion: ((_ error: Error?, _ errorTitle: String?, _ errorMessage: String?)->())?) {
    Log.info(#file, "🔐 [REDIRECT] handleRedirectURL() called")
    Log.info(#file, "🔐 [REDIRECT] Library account ID: \(libraryAccountID)")
    Log.info(#file, "🔐 [REDIRECT] Auth method: \(selectedAuthentication?.methodDescription ?? "N/A")")
    Log.info(#file, "🔐 [REDIRECT] Is SAML: \(selectedAuthentication?.isSaml == true)")
    
    NotificationCenter.default
      .removeObserver(self, name: .TPPAppDelegateDidReceiveCleverRedirectURL, object: nil)

    guard let url = notification.object as? URL else {
      Log.error(#file, "🔐 [REDIRECT] ❌ ERROR: No URL in notification object")
      TPPErrorLogger.logError(withCode: .noURL,
                               summary: "Sign-in redirection error",
                               metadata: [
                                "authMethod": selectedAuthentication?.methodDescription ?? "N/A",
                                "context": uiDelegate?.context ?? "N/A"])
      completion?(nil, nil, nil)
      return
    }

    let urlStr = url.absoluteString
    Log.info(#file, "🔐 [REDIRECT] Received URL: \(urlStr.prefix(100))...")
    
    guard urlStr.hasPrefix(urlSettingsProvider.universalLinksURL.absoluteString),
      universalLinkRedirectURLContainsPayload(urlStr) else {
        Log.error(#file, "🔐 [REDIRECT] ❌ ERROR: URL missing payload or wrong prefix")
        Log.error(#file, "🔐 [REDIRECT]   Expected prefix: \(urlSettingsProvider.universalLinksURL.absoluteString)")
        Log.error(#file, "🔐 [REDIRECT]   Contains error: \(urlStr.contains("error"))")
        Log.error(#file, "🔐 [REDIRECT]   Contains access_token: \(urlStr.contains("access_token"))")
        Log.error(#file, "🔐 [REDIRECT]   Contains patron_info: \(urlStr.contains("patron_info"))")

        TPPErrorLogger.logError(withCode: .unrecognizedUniversalLink,
                                 summary: "Sign-in redirection error: missing payload",
                                 metadata: [
                                  "loginURL": urlStr,
                                  "context": uiDelegate?.context ?? "N/A"])
        completion?(nil,
                    Strings.Error.loginErrorTitle,
                    Strings.Error.loginErrorDescription)
        return
    }

    var kvpairs = [String: String]()
    // Oauth method provides the auth token as a fragment while SAML as a
    // query parameter
    guard let payload = { url.fragment ?? url.query }() else {
      Log.error(#file, "🔐 [REDIRECT] ❌ ERROR: No fragment or query in URL")
      TPPErrorLogger.logError(withCode: .unrecognizedUniversalLink,
                               summary: "Sign-in redirection error: payload not in fragment nor query params",
                               metadata: [
                                "loginURL": urlStr,
                                "context": uiDelegate?.context ?? "N/A"])
      completion?(nil, nil, nil)
      return
    }
    
    Log.info(#file, "🔐 [REDIRECT] Payload source: \(url.fragment != nil ? "fragment" : "query")")
    Log.debug(#file, "🔐 [REDIRECT] Payload length: \(payload.count) characters")

    for param in payload.components(separatedBy: "&") {
      let elts = param.components(separatedBy: "=")
      guard elts.count >= 2, let key = elts.first, let value = elts.last else {
        continue
      }
      kvpairs[key] = value
    }
    
    Log.info(#file, "🔐 [REDIRECT] Parsed \(kvpairs.count) key-value pairs from payload")
    Log.info(#file, "🔐 [REDIRECT] Keys present: \(kvpairs.keys.sorted().joined(separator: ", "))")

    if
      let rawError = kvpairs["error"],
      let error = rawError.replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
      let parsedError = error.parseJSONString as? [String: Any] {
      Log.error(#file, "🔐 [REDIRECT] ❌ ERROR: Server returned error in payload")
      Log.error(#file, "🔐 [REDIRECT]   Error: \(parsedError)")

      completion?(nil,
                  Strings.Error.loginErrorTitle,
                 parsedError["title"] as? String)
      return
    }

    guard
      let authToken = kvpairs["access_token"],
      let patronInfo = kvpairs["patron_info"],
      let patron = patronInfo.replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
      let parsedPatron = patron.parseJSONString as? [String: Any] else {
        Log.error(#file, "🔐 [REDIRECT] ❌ ERROR: Failed to parse auth token or patron info")
        Log.error(#file, "🔐 [REDIRECT]   access_token present: \(kvpairs["access_token"] != nil)")
        Log.error(#file, "🔐 [REDIRECT]   patron_info present: \(kvpairs["patron_info"] != nil)")

        TPPErrorLogger.logError(withCode: .authDataParseFail,
                                 summary: "Sign-in redirection error: Unable to parse auth info",
                                 metadata: [
                                  "payloadDictionary": kvpairs,
                                  "redirectURL": url,
                                  "context": uiDelegate?.context ?? "N/A"])
        completion?(nil, nil, nil)
        return
    }
    
    Log.info(#file, "🔐 [REDIRECT] ✅ Successfully extracted auth data:")
    Log.info(#file, "🔐 [REDIRECT]   Auth token length: \(authToken.count) characters")
    Log.info(#file, "🔐 [REDIRECT]   Auth token prefix: \(authToken.prefix(20))...")
    Log.info(#file, "🔐 [REDIRECT]   Patron keys: \(parsedPatron.keys.sorted().joined(separator: ", "))")
    if let patronName = parsedPatron["name"] as? String {
      Log.info(#file, "🔐 [REDIRECT]   Patron name: \(patronName)")
    }

    self.authToken = authToken
    self.patron = parsedPatron
    Log.info(#file, "🔐 [REDIRECT] Stored authToken and patron in businessLogic")
    Log.info(#file, "🔐 [REDIRECT] Calling validateCredentials()...")
    
    validateCredentials()
    
    Log.info(#file, "🔐 [REDIRECT] validateCredentials() initiated (async)")
    completion?(nil, nil, nil)
  }
}

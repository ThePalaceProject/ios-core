//
//  TPPSignInBusinessLogic+OAuth.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 10/9/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import Foundation

extension TPPSignInBusinessLogic {
  // ----------------------------------------------------------------------------
  func oauthLogIn() {
    // for this kind of authentication, we want to redirect user to Safari to
    // conduct the process
    guard let oauthURL = selectedAuthentication?.oauthIntermediaryUrl else {
      TPPErrorLogger.logError(
        withCode: .noURL,
        summary: "Nil OAuth intermediary URL",
        metadata: [
          "authMethod": selectedAuthentication?.methodDescription ?? "N/A",
          "context": uiDelegate?.context ?? "N/A"
        ]
      )
      return
    }

    guard var urlComponents = URLComponents(url: oauthURL, resolvingAgainstBaseURL: true) else {
      TPPErrorLogger.logError(
        withCode: .malformedURL,
        summary: "Malformed OAuth intermediary URL",
        metadata: [
          "authMethod": selectedAuthentication?.methodDescription ?? "N/A",
          "OAUth Intermediary URL": oauthURL.absoluteString,
          "context": uiDelegate?.context ?? "N/A"
        ]
      )
      return
    }

    let redirectParam = URLQueryItem(
      name: "redirect_uri",
      value: urlSettingsProvider.universalLinksURL.absoluteString
    )
    urlComponents.queryItems?.append(redirectParam)

    guard let finalURL = urlComponents.url else {
      TPPErrorLogger.logError(
        withCode: .malformedURL,
        summary: "Unable to create URL for OAuth login",
        metadata: [
          "authMethod": selectedAuthentication?.methodDescription ?? "N/A",
          "OAUth Intermediary URL": oauthURL.absoluteString,
          "redirectParam": redirectParam,
          "context": uiDelegate?.context ?? "N/A"
        ]
      )
      return
    }

    NotificationCenter.default
      .addObserver(
        self,
        selector: #selector(handleRedirectURL(_:)),
        name: .TPPAppDelegateDidReceiveCleverRedirectURL,
        object: nil
      )

    TPPMainThreadRun.asyncIfNeeded {
      UIApplication.shared.open(finalURL)
    }
  }

  // ----------------------------------------------------------------------------
  private func universalLinkRedirectURLContainsPayload(_ urlStr: String) -> Bool {
    urlStr.contains("error")
      || (urlStr.contains("access_token") && urlStr.contains("patron_info"))
  }

  // ----------------------------------------------------------------------------

  // As per Apple Developer Documentation, selector for NSNotification must have
  // one and only one argument (an instance of NSNotification).
  // See https://developer.apple.com/documentation/foundation/nsnotificationcenter/1415360-addobserver
  // for more information.
  @objc func handleRedirectURL(_ notification: Notification) {
    handleRedirectURL(notification, completion: nil)
  }

  // this is used by both Clever and SAML authentication
  @objc func handleRedirectURL(
    _ notification: Notification,
    completion: ((_ error: Error?, _ errorTitle: String?, _ errorMessage: String?) -> Void)?
  ) {
    NotificationCenter.default
      .removeObserver(self, name: .TPPAppDelegateDidReceiveCleverRedirectURL, object: nil)

    guard let url = notification.object as? URL else {
      TPPErrorLogger.logError(
        withCode: .noURL,
        summary: "Sign-in redirection error",
        metadata: [
          "authMethod": selectedAuthentication?.methodDescription ?? "N/A",
          "context": uiDelegate?.context ?? "N/A"
        ]
      )
      completion?(nil, nil, nil)
      return
    }

    let urlStr = url.absoluteString
    guard urlStr.hasPrefix(urlSettingsProvider.universalLinksURL.absoluteString),
          universalLinkRedirectURLContainsPayload(urlStr)
    else {
      TPPErrorLogger.logError(
        withCode: .unrecognizedUniversalLink,
        summary: "Sign-in redirection error: missing payload",
        metadata: [
          "loginURL": urlStr,
          "context": uiDelegate?.context ?? "N/A"
        ]
      )
      completion?(
        nil,
        Strings.Error.loginErrorTitle,
        Strings.Error.loginErrorDescription
      )
      return
    }

    var kvpairs = [String: String]()
    // Oauth method provides the auth token as a fragment while SAML as a
    // query parameter
    guard let payload = { url.fragment ?? url.query }() else {
      TPPErrorLogger.logError(
        withCode: .unrecognizedUniversalLink,
        summary: "Sign-in redirection error: payload not in fragment nor query params",
        metadata: [
          "loginURL": urlStr,
          "context": uiDelegate?.context ?? "N/A"
        ]
      )
      completion?(nil, nil, nil)
      return
    }

    for param in payload.components(separatedBy: "&") {
      let elts = param.components(separatedBy: "=")
      guard elts.count >= 2, let key = elts.first, let value = elts.last else {
        continue
      }
      kvpairs[key] = value
    }

    if
      let rawError = kvpairs["error"],
      let error = rawError.replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
      let parsedError = error.parseJSONString as? [String: Any]
    {
      completion?(
        nil,
        Strings.Error.loginErrorTitle,
        parsedError["title"] as? String
      )
      return
    }

    guard
      let authToken = kvpairs["access_token"],
      let patronInfo = kvpairs["patron_info"],
      let patron = patronInfo.replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
      let parsedPatron = patron.parseJSONString as? [String: Any]
    else {
      TPPErrorLogger.logError(
        withCode: .authDataParseFail,
        summary: "Sign-in redirection error: Unable to parse auth info",
        metadata: [
          "payloadDictionary": kvpairs,
          "redirectURL": url,
          "context": uiDelegate?.context ?? "N/A"
        ]
      )
      completion?(nil, nil, nil)
      return
    }

    self.authToken = authToken
    self.patron = parsedPatron
    validateCredentials()
    completion?(nil, nil, nil)
  }
}

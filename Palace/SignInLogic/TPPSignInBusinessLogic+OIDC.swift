//
//  TPPSignInBusinessLogic+OIDC.swift
//  The Palace Project
//
//  Created by Maurice Carrier on 2/26/26.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import AuthenticationServices

extension TPPSignInBusinessLogic {

    /// Initiates the OIDC sign-in flow using `ASWebAuthenticationSession`.
    ///
    /// The Circulation Manager's authenticate endpoint handles the full OIDC
    /// authorization code exchange with the identity provider. On success it
    /// redirects back to the app's universal link URL with `access_token` and
    /// `patron_info` query/fragment parameters — the same contract used by the
    /// OAuth intermediary flow.
    func oidcLogIn() {
        guard let oidcURL = selectedAuthentication?.oidcAuthenticationUrl else {
            TPPErrorLogger.logError(
                withCode: .noURL,
                summary: "Nil OIDC authentication URL",
                metadata: [
                    "authMethod": selectedAuthentication?.methodDescription ?? "N/A",
                    "context": uiDelegate?.context ?? "N/A"
                ])
            return
        }

        guard var urlComponents = URLComponents(url: oidcURL, resolvingAgainstBaseURL: true) else {
            TPPErrorLogger.logError(
                withCode: .malformedURL,
                summary: "Malformed OIDC authentication URL",
                metadata: [
                    "authMethod": selectedAuthentication?.methodDescription ?? "N/A",
                    "oidcURL": oidcURL.absoluteString,
                    "context": uiDelegate?.context ?? "N/A"
                ])
            return
        }

        let redirectURI = urlSettingsProvider.universalLinksURL.absoluteString
        let redirectParam = URLQueryItem(name: "redirect_uri", value: redirectURI)
        if urlComponents.queryItems != nil {
            urlComponents.queryItems?.append(redirectParam)
        } else {
            urlComponents.queryItems = [redirectParam]
        }

        guard let finalURL = urlComponents.url else {
            TPPErrorLogger.logError(
                withCode: .malformedURL,
                summary: "Unable to create URL for OIDC login",
                metadata: [
                    "authMethod": selectedAuthentication?.methodDescription ?? "N/A",
                    "oidcURL": oidcURL.absoluteString,
                    "context": uiDelegate?.context ?? "N/A"
                ])
            return
        }

        let callbackScheme = urlSettingsProvider.universalLinksURL.scheme

        let session = ASWebAuthenticationSession(
            url: finalURL,
            callbackURLScheme: callbackScheme
        ) { [weak self] callbackURL, error in
            guard let self = self else { return }

            if let error = error as? ASWebAuthenticationSessionError,
               error.code == .canceledLogin {
                TPPMainThreadRun.asyncIfNeeded {
                    self.uiDelegate?.businessLogicDidCancelSignIn(self)
                }
                return
            }

            if let error = error {
                TPPErrorLogger.logError(
                    withCode: .appLogicInconsistency,
                    summary: "OIDC ASWebAuthenticationSession failed",
                    metadata: [
                        "error": error.localizedDescription,
                        "context": self.uiDelegate?.context ?? "N/A"
                    ])
                TPPMainThreadRun.asyncIfNeeded {
                    self.uiDelegate?.businessLogic(
                        self,
                        didEncounterValidationError: error,
                        userFriendlyErrorTitle: Strings.Error.loginErrorTitle,
                        andMessage: error.localizedDescription)
                }
                return
            }

            guard let callbackURL = callbackURL else {
                TPPErrorLogger.logError(
                    withCode: .noURL,
                    summary: "OIDC callback returned nil URL",
                    metadata: ["context": self.uiDelegate?.context ?? "N/A"])
                return
            }

            let notification = Notification(
                name: .TPPAppDelegateDidReceiveCleverRedirectURL,
                object: callbackURL,
                userInfo: nil)

            self.handleRedirectURL(notification)
        }

        TPPMainThreadRun.asyncIfNeeded { [weak self] in
            guard let self = self else { return }

            if let presentationAnchor = self.uiDelegate as? ASWebAuthenticationPresentationContextProviding {
                session.presentationContextProvider = presentationAnchor
            } else {
                session.presentationContextProvider = self
            }
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension TPPSignInBusinessLogic: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.mainKeyWindow ?? ASPresentationAnchor()
    }
}

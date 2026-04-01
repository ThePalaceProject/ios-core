//
// TPPSignInBusinessLogic+OIDC.swift
// The Palace Project
//
// Created by Maurice Carrier on 2/26/26.
// Copyright © 2026 The Palace Project. All rights reserved.
//

import AuthenticationServices
import stduritemplate

extension TPPSignInBusinessLogic {

    /// Custom URL scheme for OIDC callbacks.
    /// Mirrors Android's `palace-oidc-callback` scheme. The CM redirects to
    /// this scheme with `access_token` and `patron_info` parameters after the
    /// identity provider completes authentication.
    static let oidcCallbackScheme = "palace-oidc-callback"
    static let oidcCallbackHost  = "org.thepalaceproject.oidc"

    /// Builds the callback URL the CM should redirect to after OIDC login.
    /// Format: `palace-oidc-callback://org.thepalaceproject.oidc/callback`
    private var oidcRedirectURI: String {
        "\(Self.oidcCallbackScheme)://\(Self.oidcCallbackHost)/callback"
    }

    /// Registered redirect URI supplied to the CM's logout endpoint.
    /// The CM requires this parameter even for REST API calls to validate the request.
    private var oidcPostLogoutRedirectURI: String {
        "\(Self.oidcCallbackScheme)://\(Self.oidcCallbackHost)/logout"
    }

    /// Returns `true` when the error is an `NSURLErrorUnsupportedURL` (-1002) whose
    /// failing URL starts with the OIDC callback scheme.
    ///
    /// On a successful RP-initiated logout the CM responds with a redirect to
    /// `palace-oidc-callback://…/logout?logout_status=success`. URLSession cannot
    /// follow custom-scheme redirects and surfaces this as NSURLErrorUnsupportedURL.
    /// Detecting this pattern lets us log success rather than a spurious warning.
    private static func isOIDCLogoutCallbackRedirect(_ error: Error) -> Bool {
        func hasCallbackSchemeURL(_ nsError: NSError) -> Bool {
            let key = NSURLErrorFailingURLStringErrorKey
            if let url = nsError.userInfo[key] as? String,
               url.hasPrefix("\(oidcCallbackScheme)://") {
                return true
            }
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                return hasCallbackSchemeURL(underlying)
            }
            return false
        }
        return hasCallbackSchemeURL(error as NSError)
    }

    /// Calls the CM's OIDC logout endpoint as an authenticated REST request.
    ///
    /// The CM's logout endpoint (`rel="logout"`) requires:
    ///  - `Authorization: Bearer <token>` to identify the patron's session
    ///  - `post_logout_redirect_uri` (when the link is a URI template)
    ///
    /// Whether to expand the href as an RFC 6570 template is determined by the
    /// `"templated": true` flag on the logout link in the auth document — this
    /// avoids hard-coding assumptions that the endpoint will always be templated.
    ///
    /// Because the access token is cleared from the keychain by `userAccount.removeAll()`
    /// before this method is called, the token must be captured beforehand and passed in
    /// as `accessToken`.
    ///
    /// Logout is best-effort: any server error calls `completion` without
    /// surfacing anything to the patron, since local credentials are already cleared.
    func oidcLogOut(accessToken: String?, completion: @escaping () -> Void) {
        guard let logoutHref = selectedAuthentication?.oidcLogoutHref else {
            completion()
            return
        }

        guard let token = accessToken else {
            Log.warn(#file, "OIDC logout: no access token available — skipping CM session invalidation")
            completion()
            return
        }

        let expandedHref: String
        if selectedAuthentication?.oidcLogoutHrefIsTemplated == true {
            do {
                expandedHref = try StdUriTemplate.expand(
                    logoutHref,
                    substitutions: ["post_logout_redirect_uri": oidcPostLogoutRedirectURI]
                )
            } catch {
                Log.warn(#file, "OIDC logout URI template expansion failed: \(error) — skipping CM session invalidation")
                completion()
                return
            }
        } else {
            expandedHref = logoutHref
        }

        guard let logoutURL = URL(string: expandedHref) else {
            Log.warn(#file, "OIDC logout URL could not be constructed — skipping CM session invalidation")
            completion()
            return
        }

        var request = URLRequest(url: logoutURL, applyingCustomUserAgent: true)
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        Log.debug(#file, "OIDC logout: calling CM end-session endpoint: \(logoutURL)")

        networker.executeRequest(request, enableTokenRefresh: false) { result in
            switch result {
            case .success:
                Log.debug(#file, "OIDC logout: CM session invalidated successfully")
            case .failure(let error, _):
                // The CM redirects to our post_logout_redirect_uri on success, e.g.:
                //   palace-oidc-callback://org.thepalaceproject.oidc/logout?logout_status=success
                // URLSession cannot follow custom-scheme redirects and surfaces this
                // as NSURLErrorUnsupportedURL (-1002). If the failing URL is our callback
                // scheme, the logout succeeded — this is not a real failure.
                if Self.isOIDCLogoutCallbackRedirect(error) {
                    Log.debug(#file, "OIDC logout: CM redirected to callback scheme — session invalidated successfully")
                } else {
                    Log.warn(#file, "OIDC logout: CM session invalidation failed (best-effort): \(error.localizedDescription)")
                }
            }
            completion()
        }
    }

    /// Initiates the OIDC sign-in flow using `ASWebAuthenticationSession`.
    ///
    /// The Circulation Manager's authenticate endpoint handles the full OIDC
    /// authorization code exchange with the identity provider (including PKCE).
    /// On success it redirects back to our custom URI scheme with
    /// `access_token` and `patron_info` query parameters.
    ///
    /// Per RFC 8252 and the team's decision, the system browser is used (not a
    /// WebView). Google actively blocks in-app WebViews, so this is required
    /// for Google-backed IdPs. The CM handles refresh tokens server-side; the
    /// app never sees them.
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

        let redirectParam = URLQueryItem(name: "redirect_uri", value: oidcRedirectURI)
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

        let session = ASWebAuthenticationSession(
            url: finalURL,
            callbackURLScheme: Self.oidcCallbackScheme
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

            self.handleOIDCCallback(callbackURL)
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

    /// Parses the OIDC callback URL returned by the CM after the IdP
    /// authentication completes. Extracts `access_token` and `patron_info`
    /// from query parameters or fragment, then validates credentials.
    func handleOIDCCallback(_ url: URL) {
        let urlStr = url.absoluteString
        Log.info(#file, "OIDC callback received: \(urlStr.prefix(120))...")

        guard let payload = url.query ?? url.fragment else {
            TPPErrorLogger.logError(
                withCode: .unrecognizedUniversalLink,
                summary: "OIDC callback has no query or fragment",
                metadata: [
                    "callbackURL": urlStr,
                    "context": uiDelegate?.context ?? "N/A"
                ])
            return
        }

        var kvpairs = [String: String]()
        for param in payload.components(separatedBy: "&") {
            let elts = param.components(separatedBy: "=")
            guard elts.count >= 2, let key = elts.first, let value = elts.last else {
                continue
            }
            kvpairs[key] = value
        }

        if let rawError = kvpairs["error"],
           let error = rawError
            .replacingOccurrences(of: "+", with: " ")
            .removingPercentEncoding,
           let parsedError = error.parseJSONString as? [String: Any] {
            TPPMainThreadRun.asyncIfNeeded { [weak self] in
                guard let self = self else { return }
                self.uiDelegate?.businessLogic(
                    self,
                    didEncounterValidationError: NSError(domain: "OIDC", code: 0),
                    userFriendlyErrorTitle: Strings.Error.loginErrorTitle,
                    andMessage: parsedError["title"] as? String ?? error)
            }
            return
        }

        guard
            let authToken = kvpairs["access_token"],
            let patronInfo = kvpairs["patron_info"],
            let patron = patronInfo
                .replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding,
            let parsedPatron = patron.parseJSONString as? [String: Any]
        else {
            TPPErrorLogger.logError(
                withCode: .authDataParseFail,
                summary: "OIDC callback missing access_token or patron_info",
                metadata: [
                    "callbackURL": urlStr,
                    "keysPresent": kvpairs.keys.sorted().joined(separator: ", "),
                    "context": uiDelegate?.context ?? "N/A"
                ])
            return
        }

        self.authToken = authToken
        self.patron = parsedPatron
        validateCredentials()
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension TPPSignInBusinessLogic: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.mainKeyWindow ?? ASPresentationAnchor()
    }
}

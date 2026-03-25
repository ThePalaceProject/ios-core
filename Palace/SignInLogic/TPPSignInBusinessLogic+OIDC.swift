//
// TPPSignInBusinessLogic+OIDC.swift
// The Palace Project
//
// Created by Maurice Carrier on 2/26/26.
// Copyright © 2026 The Palace Project. All rights reserved.
//

import AuthenticationServices

extension TPPSignInBusinessLogic {

    /// Custom URL scheme for OIDC callbacks.
    /// Mirrors Android's `palace-oidc-callback` scheme. The CM redirects to
    /// this scheme with `access_token` and `patron_info` parameters after the
    /// identity provider completes authentication.
    static let oidcCallbackScheme = "palace-oidc-callback"
    static let oidcCallbackHost  = "org.thepalaceproject.oidc"

    /// Post-logout redirect URI sent to the CM's end_session endpoint.
    /// Uses the `/logout` path to distinguish the redirect from a login callback.
    static let oidcPostLogoutRedirectURI =
        "\(oidcCallbackScheme)://\(oidcCallbackHost)/logout"

    /// Builds the callback URL the CM should redirect to after OIDC login.
    /// Format: `palace-oidc-callback://org.thepalaceproject.oidc/callback`
    private var oidcRedirectURI: String {
        "\(Self.oidcCallbackScheme)://\(Self.oidcCallbackHost)/callback"
    }

    /// Terminates the OIDC browser session by opening the CM's end_session
    /// endpoint in an `ASWebAuthenticationSession`.
    ///
    /// This mirrors the `clearWebViewData()` pattern used for SAML/OAuth: after
    /// local credentials are wiped we must also invalidate the identity
    /// provider's session that lives in the system Safari cookie store —
    /// otherwise a subsequent OIDC login silently auto-authenticates the patron.
    ///
    /// The end_session URL is advertised by the CM via the "logout" rel link
    /// in the OIDC authentication document as an RFC 6570 URI template. When
    /// absent, `completion` is called immediately so the pipeline is never
    /// blocked. Logout is best-effort: errors call `completion` without
    /// surfacing anything to the patron.
    func oidcLogOut(completion: @escaping () -> Void) {
        // ASWebAuthenticationSession has no valid presentation context in the
        // test runner — skip the browser step and complete immediately.
        #if DEBUG
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            completion()
            return
        }
        #endif

        guard let logoutHref = selectedAuthentication?.oidcLogoutHref else {
            completion()
            return
        }

        // The CM advertises the logout endpoint as an RFC 6570 URI template, e.g.:
        //   .../oidc/logout?provider=OpenID+Connect{&post_logout_redirect_uri}
        // The `{&post_logout_redirect_uri}` expression is a "query continuation"
        // operator that expands to `&post_logout_redirect_uri=<encoded-value>`.
        let encodedRedirect = Self.oidcPostLogoutRedirectURI
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            ?? Self.oidcPostLogoutRedirectURI

        let expandedHref: String
        let templateToken = "{&post_logout_redirect_uri}"
        if logoutHref.contains(templateToken) {
            expandedHref = logoutHref.replacingOccurrences(
                of: templateToken,
                with: "&post_logout_redirect_uri=\(encodedRedirect)"
            )
        } else {
            // Non-templated URL: append the parameter in the conventional way.
            guard var components = URLComponents(string: logoutHref) else {
                Log.warn(#file, "OIDC logout href is malformed — skipping browser logout")
                completion()
                return
            }
            let item = URLQueryItem(name: "post_logout_redirect_uri",
                                    value: Self.oidcPostLogoutRedirectURI)
            components.queryItems = (components.queryItems ?? []) + [item]
            expandedHref = components.url?.absoluteString ?? logoutHref
        }

        guard let finalURL = URL(string: expandedHref) else {
            Log.warn(#file, "OIDC logout URL could not be constructed — skipping browser logout")
            completion()
            return
        }

        let session = ASWebAuthenticationSession(
            url: finalURL,
            callbackURLScheme: Self.oidcCallbackScheme
        ) { _, _ in
            completion()
        }

        TPPMainThreadRun.asyncIfNeeded { [weak self] in
            guard let self = self else {
                completion()
                return
            }
            if let anchor = self.uiDelegate as? ASWebAuthenticationPresentationContextProviding {
                session.presentationContextProvider = anchor
            } else {
                session.presentationContextProvider = self
            }
            // Non-ephemeral so the session operates in the shared Safari context
            // where the IdP (e.g. Google) session cookies actually live.
            session.prefersEphemeralWebBrowserSession = false
            session.start()
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

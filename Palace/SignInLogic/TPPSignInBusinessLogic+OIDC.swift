//
// TPPSignInBusinessLogic+OIDC.swift
// The Palace Project
//
// Created by Maurice Carrier on 2/26/26.
// Copyright © 2026 The Palace Project. All rights reserved.
//

import AuthenticationServices
import stduritemplate
import PalaceLogging
import PalaceUtilities

extension TPPSignInBusinessLogic {

    /// Custom URL scheme for OIDC callbacks.
    /// Mirrors Android's `palace-oidc-callback` scheme. The CM redirects to
    /// this scheme with `access_token` and `patron_info` parameters after the
    /// identity provider completes authentication.
    // `nonisolated`: immutable scheme/host literals read from nonisolated
    // cross-module call sites — `BorrowOperation.attemptOIDCSilentReauth`
    // (a nonisolated `static async` helper) and `TokenRefreshInterceptor`
    // (main-actor, but reads these to build the OIDC redirect URI). Keeping
    // them off the type's `@MainActor` isolation avoids rippling those sites.
    nonisolated static let oidcCallbackScheme = "palace-oidc-callback"
    nonisolated static let oidcCallbackHost  = "org.thepalaceproject.oidc"

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
    // `nonisolated`: pure NSError inspection, no actor state (mirrors the SAML
    // sibling `isSAMLLogoutCallbackRedirect`).
    private nonisolated static func isOIDCLogoutCallbackRedirect(_ error: Error) -> Bool {
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
    func oidcLogOut(accessToken: String?, completion: @escaping @Sendable () -> Void) {
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

        // PP-4986: built for `libraryAccountID`, not necessarily the current library.
        // PP-5301: `await`, not a completion — a completion arrives off the main
        // actor while this closure inherits the enclosing `@MainActor`
        // isolation, which is the shape that crashed in 3.3.0. The `Task`
        // inherits that isolation and the await resumes inside it, which the
        // `@MainActor` below states at the site rather than leaving it to the
        // class annotation in another file — `completion()` is a caller's
        // closure and must not be delivered off the main actor.
        Task { @MainActor in
            let result = await networker.execute(
                request, enableTokenRefresh: false, accountId: libraryAccountID)
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

        // Test seam. With a canned callback armed, deliver it and present
        // nothing: a unit test cannot dismiss a system browser and a simdrive
        // journey has no credentials for a live IdP consent page, so without
        // this the path from URL composition to credential handling is
        // undrivable. `finalURL` is composed above either way, so the
        // composition this flow gets wrong in practice stays exercised.
        //
        // All the gating lives in `oidcStubCallback`, which is nil in
        // release builds and nil unless a driver explicitly armed it. This
        // injects a callback, not a session: the token below still goes through
        // `validateCredentials()` against the CM, so a fabricated token grants
        // no access.
        if let stub = RemoteFeatureFlags.oidcStubCallback() {
            // Deliberately not describing the mechanism: the branch is dead in
            // Release but the literal can survive into the shipped binary, and
            // naming a sign-in bypass there tells anyone running `strings` what
            // to look for, for no functional benefit.
            Log.info(#file, "OIDC: delivering an injected callback")
            handleOIDCCallback(stub)
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
            // PP-4282 (HelpSpot 17716): the patron-driven "Reset Account"
            // button sets a one-shot UserDefaults flag. When set, force this
            // session to use ephemeral cookies — defeats the Safari-shared-
            // cookie reuse that otherwise survives app deletion for OIDC
            // libraries. Flag self-clears on consumption.
            session.prefersEphemeralWebBrowserSession =
                TPPSignInBusinessLogic.consumeNextOIDCSessionEphemeralFlag()
            session.start()
        }
    }

    /// Decode an `application/x-www-form-urlencoded` value.
    ///
    /// `removingPercentEncoding` alone is not enough: form encoding writes a space
    /// as `+`, which percent-decoding leaves as a literal plus.
    static func formDecoded(_ raw: String) -> String? {
        raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
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
            guard elts.count >= 2, let key = elts.first else {
                continue
            }
            // Join all segments after the key — values can contain '=' (e.g. base64 tokens)
            let value = elts.dropFirst().joined(separator: "=")
            kvpairs[key] = value
        }

        // Two shapes arrive here. The circulation manager sends a JSON object with
        // a `title`; an identity provider following RFC 6749 section 4.1.2.1 sends a
        // bare `error=<code>` plus an optional `error_description`, which is not
        // JSON. This arm used to require the value to parse as a JSON object, so a
        // bare code fell through to the access_token guard below, logged, and
        // returned — a patron who declined consent was left on the sheet with no
        // message at all.
        if let rawError = kvpairs["error"], !rawError.isEmpty {
            let error = Self.formDecoded(rawError) ?? rawError
            let message: String
            if let parsedError = error.parseJSONString as? [String: Any],
               let title = parsedError["title"] as? String {
                message = title
            } else if let description = kvpairs["error_description"]
                        .flatMap(Self.formDecoded), !description.isEmpty {
                message = description
            } else {
                // The code is the only information the response carries. Showing it
                // is not friendly, and it is what the provider said.
                message = error
            }
            // Provider-supplied text with no length contract: an unbounded
            // error_description renders an unreadable alert.
            let bounded = String(message.prefix(300))
            TPPMainThreadRun.asyncIfNeeded { [weak self] in
                guard let self = self else { return }
                self.uiDelegate?.businessLogic(
                    self,
                    didEncounterValidationError: NSError(domain: "OIDC", code: 0),
                    userFriendlyErrorTitle: Strings.Error.loginErrorTitle,
                    andMessage: bounded)
            }
            return
        }

        guard
            let authToken = kvpairs["access_token"],
            let patronInfo = kvpairs["patron_info"],
            let patron = Self.formDecoded(patronInfo),
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

        self.dispatch(.bearerTokenReceived(token: authToken, expiration: nil))
        self.patron = parsedPatron
        // OIDC callback handler is synchronous, so the await needs a Task.
        startSignInTask { await self.validateCredentials() }
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

// `@preconcurrency`: `ASWebAuthenticationPresentationContextProviding` is a
// nonisolated system protocol; the witness returns a `@MainActor` UIWindow and
// is only ever invoked by `ASWebAuthenticationSession` on the main thread.
extension TPPSignInBusinessLogic: @preconcurrency ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Shared resolver — a bare `ASPresentationAnchor()` is a scene-less
        // window and is what iOS rejects with `.presentationContextInvalid`.
        UIApplication.shared.webAuthPresentationAnchor ?? ASPresentationAnchor()
    }
}

//
// TPPSignInBusinessLogic+SAML.swift
// The Palace Project
//
// Copyright © 2026 The Palace Project. All rights reserved.
//
// SP-initiated SAML Single Logout client (PP-3452).
// Mirrors TPPSignInBusinessLogic+OIDC.swift: the CM emits a SAML logout link
// with the same Bearer+URI-template+logout_status contract.
//

import Foundation
import stduritemplate
import PalaceLogging

extension TPPSignInBusinessLogic {

    /// Custom URL scheme used as the `post_logout_redirect_uri` sent to the CM
    /// when initiating SAML SLO. URLSession cannot follow custom-scheme
    /// redirects — the CM's 302 back to this URL surfaces as
    /// `NSURLErrorUnsupportedURL`, which we detect as SLO success.
    static let samlCallbackScheme = "palace-saml-callback"
    static let samlCallbackHost = "org.thepalaceproject.saml"

    /// The full `post_logout_redirect_uri` value sent to the CM.
    static var samlPostLogoutRedirectURI: String {
        "\(samlCallbackScheme)://\(samlCallbackHost)/logout"
    }

    /// Expands the CM's SAML logout href into a callable URL.
    ///
    /// The CM emits the href as an RFC 6570 URI template when `templated: true`:
    ///   `https://cm/SHORT/saml/logout?provider=X{&post_logout_redirect_uri}`
    /// We expand it with our custom-scheme redirect URI. Non-templated hrefs
    /// are used verbatim so that any future CM contract change (dropping the
    /// flag, inlining the param) continues to work.
    ///
    /// - Returns: nil when the template is malformed or the href cannot be
    ///            parsed as a URL. Callers fall back to local-only cleanup.
    static func expandSAMLLogoutHref(_ href: String,
                                     isTemplated: Bool,
                                     postLogoutRedirectURI: String) -> URL? {
        let expanded: String
        if isTemplated {
            do {
                expanded = try StdUriTemplate.expand(
                    href,
                    substitutions: ["post_logout_redirect_uri": postLogoutRedirectURI]
                )
            } catch {
                return nil
            }
        } else {
            expanded = href
        }
        return URL(string: expanded)
    }

    /// Returns `true` when the error is an `NSURLErrorUnsupportedURL` (-1002)
    /// whose failing URL starts with the SAML callback scheme — signalling a
    /// successful CM redirect that URLSession could not follow.
    static func isSAMLLogoutCallbackRedirect(_ error: Error) -> Bool {
        func hasCallbackSchemeURL(_ nsError: NSError) -> Bool {
            let key = NSURLErrorFailingURLStringErrorKey
            if let url = nsError.userInfo[key] as? String,
               url.hasPrefix("\(samlCallbackScheme)://") {
                return true
            }
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                return hasCallbackSchemeURL(underlying)
            }
            return false
        }
        return hasCallbackSchemeURL(error as NSError)
    }

    /// Calls the CM's SAML logout endpoint as an authenticated REST request.
    ///
    /// CM contract (PP-3452 / commit 914bff6):
    ///  - `Authorization: Bearer <token>` to validate the patron's session
    ///  - `post_logout_redirect_uri` via RFC 6570 template
    ///  - CM responds with redirect to `<redirect>?logout_status=success|partial`
    ///
    /// Because the access token is cleared from the keychain by
    /// `userAccount.removeAll()` before this runs, the caller must capture it
    /// beforehand and pass it in.
    ///
    /// Logout is best-effort: any server error calls `completion` without
    /// surfacing anything to the patron, since local credentials are already
    /// cleared at this point in the pipeline.
    func samlLogOut(accessToken: String?, completion: @escaping () -> Void) {
        guard let logoutHref = selectedAuthentication?.samlLogoutHref else {
            completion()
            return
        }

        guard let token = accessToken else {
            Log.warn(#file, "SAML logout: no access token available — skipping CM session invalidation")
            completion()
            return
        }

        guard let logoutURL = Self.expandSAMLLogoutHref(
            logoutHref,
            isTemplated: selectedAuthentication?.samlLogoutHrefIsTemplated == true,
            postLogoutRedirectURI: Self.samlPostLogoutRedirectURI
        ) else {
            Log.warn(#file, "SAML logout: URL could not be constructed — skipping CM session invalidation")
            completion()
            return
        }

        var request = URLRequest(url: logoutURL, applyingCustomUserAgent: true)
        request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        Log.debug(#file, "SAML logout: calling CM saml_logout_redirect: \(logoutURL)")

        networker.executeRequest(request, enableTokenRefresh: false) { result in
            switch result {
            case .success:
                Log.debug(#file, "SAML logout: CM session invalidated successfully")
            case .failure(let error, _):
                // URLSession surfaces the CM's 302 to palace-saml-callback://
                // as NSURLErrorUnsupportedURL. That is the success signal.
                if Self.isSAMLLogoutCallbackRedirect(error) {
                    Log.debug(#file, "SAML logout: CM redirected to callback scheme — session invalidated successfully")
                } else {
                    Log.warn(#file, "SAML logout: CM session invalidation failed (best-effort): \(error.localizedDescription)")
                }
            }
            completion()
        }
    }
}

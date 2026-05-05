import UIKit
import WebKit

// MARK: - Protocols for dependency injection

/// What TPPSAMLHelper needs from the sign-in orchestrator.
/// Decouples the helper from the concrete TPPSignInBusinessLogic class.
protocol SAMLAuthContext: AnyObject {
    var selectedIDP: OPDS2SamlIDP? { get }
    var urlSettingsProvider: NYPLUniversalLinksSettings & NYPLFeedURLProvider { get }
    var savedCookies: [HTTPCookie] { get }
    func handleSAMLRedirect(url: URL, cookies: [HTTPCookie],
                            completion: @escaping (Error?, String?, String?) -> Void)
    func reportError(_ error: Error, title: String, message: String)
}

/// What TPPSAMLHelper needs to present the SAML WebView.
/// Decouples UI presentation from business logic.
protocol SAMLWebViewPresenting: AnyObject {
    func presentSAMLWebView(url: URL, cookies: [HTTPCookie],
                            loginCompletion: @escaping (URL, [HTTPCookie]) -> Void,
                            loginCancel: @escaping () -> Void)
    func dismissSAMLWebView(animated: Bool, completion: (() -> Void)?)
}

// MARK: - SAML Helper

class TPPSAMLHelper {

    // MARK: - Phase 5: SAML state stored on helper, not businessLogic

    /// Cookies obtained during the SAML login flow.
    var cookies: [HTTPCookie]?

    /// The IDP the user selected for this SAML login attempt.
    var selectedIDP: OPDS2SamlIDP?

    // MARK: - Dependencies (Phase 1+2: protocol-based, no force-unwrap)

    private weak var context: SAMLAuthContext?
    private weak var presenter: SAMLWebViewPresenting?

    /// Legacy bridge: the business logic instance, used only during the
    /// transition period until all callers adopt the protocol-based init.
    weak var businessLogic: TPPSignInBusinessLogic? {
        didSet {
            // Wire up the legacy bridge — businessLogic serves as both
            // context and presenter (via its UI delegate).
            if let bl = businessLogic {
                _legacyContext = LegacySAMLAuthContext(businessLogic: bl)
                _legacyPresenter = LegacySAMLWebViewPresenter(businessLogic: bl)
                context = _legacyContext
                presenter = _legacyPresenter
            }
        }
    }
    private var _legacyContext: LegacySAMLAuthContext?
    private var _legacyPresenter: LegacySAMLWebViewPresenter?

    /// Designated initializer — protocol-based DI, no force-unwrap.
    init(context: SAMLAuthContext, presenter: SAMLWebViewPresenting) {
        self.context = context
        self.presenter = presenter
    }

    /// Legacy initializer — used by TPPSignInBusinessLogic during transition.
    /// The `businessLogic` property must be set immediately after init.
    init() {}

    // MARK: - Login

    func logIn(loginCancelHandler: @escaping () -> Void) {
        guard let context = context else {
            Log.warn(#file, "[SAML-REAUTH-FIX] logIn aborted: context is nil")
            return
        }
        guard let idpURL = context.selectedIDP?.url else {
            Log.warn(#file, "[SAML-REAUTH-FIX] logIn aborted: selectedIDP url is nil")
            return
        }

        var urlComponents = URLComponents(url: idpURL, resolvingAgainstBaseURL: true)
        let redirectURI = URLQueryItem(name: "redirect_uri", value: context.urlSettingsProvider.universalLinksURL.absoluteString)
        if urlComponents?.queryItems == nil {
            urlComponents?.queryItems = [redirectURI]
        } else {
            urlComponents?.queryItems?.append(redirectURI)
        }

        guard let url = urlComponents?.url else {
            Log.warn(#file, "[SAML-REAUTH-FIX] logIn aborted: url construction failed")
            return
        }

        // ============================================================================
        // [SAML-REAUTH-FIX] HelpSpot 17716 — Cornell Shibboleth stuck-state bandage
        // ============================================================================
        // Hypothesis: stale cookies in `userAccount.cookies` (persisted across
        // sessions) are being injected into the SAML re-auth WKWebView. For some
        // IdP/cookie-state combinations (Cornell Shibboleth specifically) this
        // produces a redirect chain the webview can't follow, surfacing as
        // "WebView provisional navigation failed: Frame load interrupted" — which
        // is exactly the pattern in Adam Chandler's sysdiagnose (4 Frame-load-
        // interrupted events on 2026-04-30, all preceded by /patrons/me/ 401s).
        //
        // Bandage: pass an empty cookie array to the SAML webview. The webview
        // is already on `WKWebsiteDataStore.nonPersistent()` (verified at
        // TPPCookiesWebViewController.swift line 94/101), so this gives the
        // webview a truly clean state. The IdP will either honor any existing
        // session cookie it holds device-wide (Safari/system) or prompt for
        // credentials. Either path is recoverable; the stale-injection path is
        // not.
        //
        // Trade-off: returning patrons may see a credential prompt more often.
        // For stuck patrons on Cornell SAML, "occasional prompt" is strictly
        // better than "spinner forever for 3 weeks." Targeted at TestFlight
        // verification on Adam's device first.
        let originalSavedCookieCount = context.savedCookies.count
        let originalSavedCookieNames = context.savedCookies.map { $0.name }
        let cookiesToInject: [HTTPCookie] = []

        Log.info(#file, "[SAML-REAUTH-FIX] BANDAGE ACTIVE — passing 0 cookies to SAML webview (was \(originalSavedCookieCount) cookies). Cookie names dropped: \(originalSavedCookieNames). IdP host: \(idpURL.host ?? "unknown")")

        // Belt-and-suspenders: also wipe WKWebsiteDataStore.default() cookies
        // for the IdP domain. The cookies VC uses nonPersistent() so the data
        // store doesn't carry these into the auth flow, but other parts of the
        // app (e.g., previous TPPCookiesWebViewController instances) may have
        // leaked cookies into the default store. Force a clean slate.
        let dataStore = WKWebsiteDataStore.default()
        let cookieDataType: Set<String> = [WKWebsiteDataTypeCookies]
        dataStore.fetchDataRecords(ofTypes: cookieDataType) { records in
            let total = records.count
            let idpHost = idpURL.host?.lowercased() ?? ""
            let idpRecords = records.filter { record in
                let name = record.displayName.lowercased()
                // Heuristic match: any record whose displayName overlaps the IdP host.
                // Shibboleth typically lives at shibboleth.<institution>.edu or
                // weblogin.<institution>.edu — match on second-level domain too.
                if idpHost.contains(name) || name.contains(idpHost) { return true }
                let parts = idpHost.split(separator: ".")
                if parts.count >= 2 {
                    let registrable = parts.suffix(2).joined(separator: ".")
                    if name.contains(registrable) { return true }
                }
                return false
            }
            Log.info(#file, "[SAML-REAUTH-FIX] WKWebsiteDataStore default — found \(total) cookie records, \(idpRecords.count) match IdP host '\(idpHost)'. Wiping the matches.")
            dataStore.removeData(ofTypes: cookieDataType, for: idpRecords) {
                Log.info(#file, "[SAML-REAUTH-FIX] WKWebsiteDataStore wipe complete for IdP host '\(idpHost)'")
            }
        }

        let loginCompletionHandler: (URL, [HTTPCookie]) -> Void = { [weak self] url, cookies in
            guard let self = self else { return }
            self.cookies = cookies
            Log.info(#file, "[SAML-REAUTH-FIX] auth completed — captured \(cookies.count) cookie(s) from IdP. Cookie names: \(cookies.map { $0.name }). Redirect URL host: \(url.host ?? "unknown")")

            context.handleSAMLRedirect(url: url, cookies: cookies) { error, errorTitle, errorMessage in
                self.presenter?.dismissSAMLWebView(animated: true) {
                    // Report error after dismiss completes (if any).
                    // In the legacy path, context is LegacySAMLAuthContext which
                    // delegates error reporting to businessLogic.uiDelegate.
                    if let error = error, let errorTitle = errorTitle, let errorMessage = errorMessage {
                        Log.warn(#file, "[SAML-REAUTH-FIX] post-auth error title=\(errorTitle), message=\(errorMessage), error=\(error.localizedDescription)")
                        context.reportError(error, title: errorTitle, message: errorMessage)
                    } else {
                        Log.info(#file, "[SAML-REAUTH-FIX] post-auth completed successfully (no error)")
                    }
                }
            }
        }

        Log.info(#file, "[SAML-REAUTH-FIX] presenting SAML webview, idpHost=\(idpURL.host ?? "unknown"), passing 0 cookies (bandage), redirectURI=\(context.urlSettingsProvider.universalLinksURL.absoluteString)")
        presenter?.presentSAMLWebView(
            url: url,
            cookies: cookiesToInject,
            loginCompletion: loginCompletionHandler,
            loginCancel: loginCancelHandler
        )
    }

    // MARK: - Phase 5: Clear state on sign-out

    func clearState() {
        cookies = nil
        selectedIDP = nil
    }
}

// MARK: - Legacy Bridge Adapters

/// Wraps TPPSignInBusinessLogic to conform to SAMLAuthContext.
private class LegacySAMLAuthContext: SAMLAuthContext {
    weak var businessLogic: TPPSignInBusinessLogic?

    init(businessLogic: TPPSignInBusinessLogic) {
        self.businessLogic = businessLogic
    }

    var selectedIDP: OPDS2SamlIDP? {
        businessLogic?.selectedIDP
    }

    var urlSettingsProvider: NYPLUniversalLinksSettings & NYPLFeedURLProvider {
        guard let businessLogic = businessLogic else {
            preconditionFailure("LegacySAMLAuthContext accessed after businessLogic was deallocated")
        }
        return businessLogic.urlSettingsProvider
    }

    var savedCookies: [HTTPCookie] {
        businessLogic?.userAccount.cookies ?? []
    }

    func handleSAMLRedirect(url: URL, cookies: [HTTPCookie],
                            completion: @escaping (Error?, String?, String?) -> Void) {
        guard let businessLogic = businessLogic else { return }
        businessLogic.cookies = cookies

        let redirectNotification = Notification(name: .TPPAppDelegateDidReceiveCleverRedirectURL, object: url, userInfo: nil)
        businessLogic.handleRedirectURL(redirectNotification) { error, errorTitle, errorMessage in
            // NOTE: Dismiss is NOT called here — that's the presenter's
            // responsibility (called by TPPSAMLHelper.logIn's completion).
            // Error reporting is deferred to after dismiss completes.
            completion(error, errorTitle, errorMessage)
        }
    }

    func reportError(_ error: Error, title: String, message: String) {
        guard let businessLogic = businessLogic else { return }
        DispatchQueue.main.async {
            businessLogic.uiDelegate?.businessLogic(
                businessLogic,
                didEncounterValidationError: error,
                userFriendlyErrorTitle: title,
                andMessage: message
            )
        }
    }
}

/// Wraps TPPSignInBusinessLogic's UI delegate to conform to SAMLWebViewPresenting.
private class LegacySAMLWebViewPresenter: SAMLWebViewPresenting {
    weak var businessLogic: TPPSignInBusinessLogic?

    init(businessLogic: TPPSignInBusinessLogic) {
        self.businessLogic = businessLogic
    }

    func presentSAMLWebView(url: URL, cookies: [HTTPCookie],
                            loginCompletion: @escaping (URL, [HTTPCookie]) -> Void,
                            loginCancel: @escaping () -> Void) {
        guard let businessLogic = businessLogic else { return }

        let model = TPPCookiesWebViewModel(
            cookies: cookies,
            request: URLRequest(url: url),
            loginCompletionHandler: loginCompletion,
            loginCancelHandler: loginCancel,
            bookFoundHandler: nil,
            problemFoundHandler: nil,
            autoPresentIfNeeded: false
        )

        let cookiesVC = TPPCookiesWebViewController(model: model)
        let navigationWrapper = UINavigationController(rootViewController: cookiesVC)

        businessLogic.uiDelegate?.present(navigationWrapper, animated: true, completion: nil)
    }

    func dismissSAMLWebView(animated: Bool, completion: (() -> Void)?) {
        businessLogic?.uiDelegate?.dismiss(animated: animated, completion: completion)
    }
}

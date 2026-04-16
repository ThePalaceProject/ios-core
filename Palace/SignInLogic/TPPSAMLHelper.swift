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
        guard let context = context else { return }
        guard let idpURL = context.selectedIDP?.url else {
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
            return
        }

        // Phase 3: Filter expired cookies before sending to IdP
        let savedCookies = context.savedCookies.filter { cookie in
            guard let expires = cookie.expiresDate else { return true }
            return expires > Date()
        }

        let filteredCount = context.savedCookies.count - savedCookies.count
        if filteredCount > 0 {
            Log.info(#file, "SAML: filtered \(filteredCount) expired cookie(s)")
        }

        let loginCompletionHandler: (URL, [HTTPCookie]) -> Void = { [weak self] url, cookies in
            guard let self = self else { return }
            self.cookies = cookies

            context.handleSAMLRedirect(url: url, cookies: cookies) { error, errorTitle, errorMessage in
                self.presenter?.dismissSAMLWebView(animated: true) {
                    // Error reporting is handled by the context (TPPSignInBusinessLogic)
                    // which will call its uiDelegate if needed.
                }
            }
        }

        presenter?.presentSAMLWebView(
            url: url,
            cookies: savedCookies,
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
        businessLogic!.urlSettingsProvider
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
            DispatchQueue.main.async {
                businessLogic.uiDelegate?.dismiss(animated: true) {
                    if let error = error, let errorTitle = errorTitle, let errorMessage = errorMessage {
                        businessLogic.uiDelegate?.businessLogic(businessLogic, didEncounterValidationError: error, userFriendlyErrorTitle: errorTitle, andMessage: errorMessage)
                    }
                }
                completion(error, errorTitle, errorMessage)
            }
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

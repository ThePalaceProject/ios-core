#if canImport(UIKit)
import UIKit
import WebKit
import PalaceLogging

// MARK: - Public protocols for dependency injection

/// What `TPPSAMLHelper` needs to read the universal-links redirect URI for
/// SAML callbacks. Main target's `TPPSettings` (or any other settings
/// provider) declares conformance via an extension.
public protocol UniversalLinksProviding: AnyObject {
    var universalLinksURL: URL { get }
}

/// What `TPPSAMLHelper` needs from the sign-in orchestrator. Decouples the
/// helper from the concrete `TPPSignInBusinessLogic` class so the package
/// has no app-target dependency.
@MainActor public protocol SAMLAuthContext: AnyObject {
    /// Resolved URL of the user-selected IdP for this SAML attempt.
    var selectedIDPURL: URL? { get }
    /// Cached cookies for re-using the IdP session, expired ones filtered
    /// upstream by the helper before they hit the WebView.
    var savedCookies: [HTTPCookie] { get }

    func handleSAMLRedirect(url: URL, cookies: [HTTPCookie],
                            completion: @escaping (Error?, String?, String?) -> Void)
    func reportError(_ error: Error, title: String, message: String)
}

/// What `TPPSAMLHelper` needs to present the SAML WebView. The main target
/// implements this against `SignInWebSheetPresenter` (or any other
/// presentation surface) and injects it.
@MainActor public protocol SAMLWebViewPresenting: AnyObject {
    func presentSAMLWebView(url: URL, cookies: [HTTPCookie],
                            loginCompletion: @escaping (URL, [HTTPCookie]) -> Void,
                            loginCancel: @escaping () -> Void)
    func dismissSAMLWebView(animated: Bool, completion: (() -> Void)?)
}

// MARK: - SAML Helper

@MainActor public class TPPSAMLHelper {

    /// Cookies obtained during the SAML login flow. Cleared on `clearState()`.
    public var cookies: [HTTPCookie]?

    private weak var context: SAMLAuthContext?
    private weak var presenter: SAMLWebViewPresenting?
    private let universalLinksProvider: any UniversalLinksProviding

    /// Designated initializer — protocol-based DI, no force-unwrap.
    /// `context` and `presenter` are weak; pass them as long-lived
    /// collaborators (typically `TPPSignInBusinessLogic` and a
    /// presenter adapter living on the businessLogic side).
    public init(
        universalLinksProvider: any UniversalLinksProviding,
        context: SAMLAuthContext,
        presenter: SAMLWebViewPresenting
    ) {
        self.universalLinksProvider = universalLinksProvider
        self.context = context
        self.presenter = presenter
    }

    // MARK: - Login

    public func logIn(loginCancelHandler: @escaping () -> Void) {
        guard let context = context else { return }
        guard let idpURL = context.selectedIDPURL else { return }

        var urlComponents = URLComponents(url: idpURL, resolvingAgainstBaseURL: true)
        let redirectURI = URLQueryItem(
            name: "redirect_uri",
            value: universalLinksProvider.universalLinksURL.absoluteString
        )
        if urlComponents?.queryItems == nil {
            urlComponents?.queryItems = [redirectURI]
        } else {
            urlComponents?.queryItems?.append(redirectURI)
        }

        guard let url = urlComponents?.url else { return }

        // Filter expired cookies before sending to IdP
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

            context.handleSAMLRedirect(url: url, cookies: cookies) { [weak self] error, errorTitle, errorMessage in
                self?.presenter?.dismissSAMLWebView(animated: true) {
                    // Report error after dismiss completes (if any).
                    if let error = error,
                       let errorTitle = errorTitle,
                       let errorMessage = errorMessage {
                        context.reportError(error, title: errorTitle, message: errorMessage)
                    }
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

    /// Clears the SAML side-channel state on sign-out.
    public func clearState() {
        cookies = nil
    }
}
#endif


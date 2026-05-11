//
//  LegacySAMLAuthAdapter.swift
//  The Palace Project
//
//  Bridges TPPSignInBusinessLogic to PalaceAuth's SAMLAuthContext +
//  SAMLWebViewPresenting protocols. The legacy bridge adapters used to live
//  inside TPPSAMLHelper.swift, but that file moved into the PalaceAuth
//  package (swarm_ea663ab6, impl 1) and the package can't reach
//  TPPSignInBusinessLogic, OPDS2SamlIDP, or SignInWebSheetPresenter — those
//  remain in the main target. So the adapters live here, in main target,
//  and conform to the public protocols re-exported from PalaceAuth.
//
//  Construction site: TPPSignInBusinessLogic's designated init wires
//  `LegacySAMLAuthContext` and `LegacySAMLWebViewPresenter` into the helper
//  via `init(universalLinksProvider:context:presenter:)`.
//

import Foundation
import UIKit
import PalaceAuth

/// Wraps the businessLogic-injected `urlSettingsProvider` in PalaceAuth's
/// `UniversalLinksProviding` protocol. The injected type is
/// `NYPLUniversalLinksSettings & NYPLFeedURLProvider` (legacy ObjC protocols
/// that happen to expose `universalLinksURL`); this adapter forwards the URL
/// read so the package doesn't have to know about the legacy protocols.
final class UniversalLinksAdapter: NSObject, UniversalLinksProviding {
    private let provider: NYPLUniversalLinksSettings

    init(provider: NYPLUniversalLinksSettings) {
        self.provider = provider
    }

    var universalLinksURL: URL { provider.universalLinksURL }
}

/// Adapts `TPPSignInBusinessLogic` to `PalaceAuth.SAMLAuthContext` so the
/// helper can read the selected IdP, cached cookies, drive the redirect
/// payload through the existing OAuth/SAML handler, and surface errors
/// through the UI delegate.
///
/// Both adapters here are deliberately NOT `@MainActor` so they can be
/// constructed from `TPPSignInBusinessLogic`'s nonisolated designated
/// initializer. Every callback either re-enters main via `Task { @MainActor }`
/// or `DispatchQueue.main.async`; the underlying calls to UIKit, SwiftUI, and
/// `TPPSignInBusinessLogic` all bounce through the main thread before
/// touching anything actor-isolated.
final class LegacySAMLAuthContext: NSObject, SAMLAuthContext {
    weak var businessLogic: TPPSignInBusinessLogic?

    var selectedIDPURL: URL? {
        // OPDS2SamlIDP.url is read off the businessLogic's stored property.
        // The TPPSAMLHelper calls this from the main-thread login flow
        // (TPPSignInBusinessLogic.requestCredentials → samlHelper.logIn).
        businessLogic?.selectedIDP?.url
    }

    var savedCookies: [HTTPCookie] {
        businessLogic?.userAccount.cookies ?? []
    }

    func handleSAMLRedirect(url: URL,
                            cookies: [HTTPCookie],
                            completion: @escaping (Error?, String?, String?) -> Void) {
        // Caller invokes us from the main thread; stay on the same hop.
        guard let businessLogic = businessLogic else {
            completion(nil, nil, nil)
            return
        }
        // Mirror legacy behaviour: stash cookies on the businessLogic so
        // downstream credential-sync code can read them, then reuse the
        // OAuth/SAML redirect handler that already knows how to parse
        // the token/patron payload off a universal-link URL.
        businessLogic.cookies = cookies
        let redirectNotification = Notification(
            name: .TPPAppDelegateDidReceiveCleverRedirectURL,
            object: url,
            userInfo: nil
        )
        businessLogic.handleRedirectURL(redirectNotification) { error, errorTitle, errorMessage in
            completion(error, errorTitle, errorMessage)
        }
    }

    func reportError(_ error: Error, title: String, message: String) {
        // Dispatch onto main since the UI delegate methods drive UIKit alerts.
        DispatchQueue.main.async { [weak self] in
            guard let businessLogic = self?.businessLogic else { return }
            businessLogic.uiDelegate?.businessLogic(
                businessLogic,
                didEncounterValidationError: error,
                userFriendlyErrorTitle: title,
                andMessage: message
            )
        }
    }
}

/// Adapts the SwiftUI `SignInWebSheetPresenter` to PalaceAuth's
/// `SAMLWebViewPresenting`. Mirrors the legacy `LegacySAMLWebViewPresenter`
/// that lived inside `TPPSAMLHelper.swift` before the package extraction.
///
/// Not `@MainActor` for the same reason as `LegacySAMLAuthContext`: it must be
/// constructible from a nonisolated init. Each method hops to main via
/// `Task { @MainActor }` before touching the SwiftUI presenter.
final class LegacySAMLWebViewPresenter: NSObject, SAMLWebViewPresenting {
    weak var uiDelegate: TPPSignInBusinessLogicUIDelegate?

    func presentSAMLWebView(url: URL,
                            cookies: [HTTPCookie],
                            loginCompletion: @escaping (URL, [HTTPCookie]) -> Void,
                            loginCancel: @escaping () -> Void) {
        // The actual presenter walks to the topmost VC; we don't need the
        // uiDelegate to be a VC. This matches the legacy `presentOnTop`
        // path that MyBooksDownloadCenter / BookSignInRedirectHandler use.
        let request = URLRequest(url: url)

        Task { @MainActor in
            let universalLinks = AppContainer.production().settings.universalLinksURL
            let model = SignInWebSheetViewModel(
                cookies: cookies,
                request: request,
                universalLinksURL: universalLinks,
                autoPresentIfNeeded: false,
                loginCompletionHandler: loginCompletion,
                loginCancelHandler: loginCancel
            )
            SignInWebSheetPresenter.presentOnTop(model: model)
        }
    }

    func dismissSAMLWebView(animated: Bool, completion: (() -> Void)?) {
        Task { @MainActor in
            SignInWebSheetPresenter.dismissTop(animated: animated, completion: completion)
        }
    }
}

// MARK: - TPPSignInValidationContext conformance

/// Bridges `TPPSignInBusinessLogic.selectedAuthentication` (rich
/// `AccountDetails.Authentication`) to the boolean predicates that
/// `PalaceAuth.TPPUserAccountFrontEndValidation` reads. PalaceAuth doesn't
/// see `LoginKeyboard` (it lives on `AccountDetails`); this extension
/// flattens each predicate to a Bool the validator can act on.
extension TPPSignInBusinessLogic: TPPSignInValidationContext {
    public var usernameIsEmailKeyboard: Bool {
        selectedAuthentication?.patronIDKeyboard == .email
    }

    public var pinAllowsAlphanumeric: Bool {
        selectedAuthentication?.pinKeyboard != .numeric
    }

    public var pinMaxLength: UInt {
        selectedAuthentication?.authPasscodeLength ?? 0
    }

    public var hasBarcodeAndPIN: Bool {
        userAccount.hasBarcodeAndPIN()
    }
}

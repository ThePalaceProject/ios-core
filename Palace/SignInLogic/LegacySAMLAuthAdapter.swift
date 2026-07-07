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
import PalaceCatalog

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
/// `@MainActor`: this adapter reads/writes `@MainActor` `TPPSignInBusinessLogic`
/// state synchronously (`selectedIDPURL`, `savedCookies`, `handleSAMLRedirect`)
/// and is only ever constructed from `TPPSignInBusinessLogic.init` (now itself
/// `@MainActor`) and driven by `TPPSAMLHelper` on the main-thread SAML login
/// flow. Its `SAMLAuthContext` conformance is main-actor because the PalaceAuth
/// protocol is `@MainActor` (see RIPPLES.md). The residual `asyncIfNeeded` hops
/// below stay for their sync-if-already-on-main ordering guarantee, but no
/// longer need `assumeIsolated` gymnastics to reach main-actor state — the whole
/// adapter is now main-isolated.
@MainActor
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
        // Hop onto main since the UI delegate methods drive UIKit alerts. Use
        // `TPPMainThreadRun.asyncIfNeeded` (a non-`@Sendable` closure) rather
        // than `DispatchQueue.main.async` (whose closure IS `@Sendable`): the
        // latter would trip the `complete`-mode "capture of non-Sendable
        // self/businessLogic in a @Sendable closure" diagnostic. Behavior is
        // equivalent — the sole caller (`TPPSAMLHelper.logIn`) already invokes
        // this from a main-thread `dismissSAMLWebView` completion, so surfacing
        // the alert synchronously-on-main vs deferred is indistinguishable for
        // a UIKit alert.
        TPPMainThreadRun.asyncIfNeeded { [weak self] in
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
/// `@MainActor` for the same reason as `LegacySAMLAuthContext`: it is
/// constructed from `TPPSignInBusinessLogic.init` (now `@MainActor`), drives the
/// `@MainActor` `SignInWebSheetPresenter`, and its `SAMLWebViewPresenting`
/// conformance is main-actor because the PalaceAuth protocol is `@MainActor`
/// (see RIPPLES.md).
///
/// Holds a reference to the same `urlSettingsProvider` the businessLogic was
/// constructed with so the universal-links URL is read from the injected
/// settings object rather than reaching back through `AppContainer.production()`
/// (which is a singleton seam the rest of the sign-in path no longer touches).
@MainActor
final class LegacySAMLWebViewPresenter: NSObject, SAMLWebViewPresenting {
    private let universalLinksProvider: NYPLUniversalLinksSettings

    /// HelpSpot 17870 — weak back-reference so the presenter can synthesise
    /// a `problemFoundHandler` that bridges `TPPProblemDocument` events from
    /// `SignInWebSheetViewModel.recordProblem(document:)` to
    /// `businessLogic.uiDelegate.businessLogic(_:didEncounterValidationError:
    /// userFriendlyErrorTitle:andMessage:)`. Without this wire-up, a
    /// problem-document served by the CM mid-flow silently dropped on the
    /// floor and the patron saw a hung sheet.
    ///
    /// Option B from the contract: keep the presenter stateless w.r.t. the
    /// businessLogic at init time, set the back-reference post-init from
    /// `TPPSignInBusinessLogic.init` the same way `LegacySAMLAuthContext`
    /// gets its `businessLogic` set. `weak` so we don't extend the
    /// businessLogic's lifetime past `TPPSignInBusinessLogic.deinit`.
    weak var businessLogic: TPPSignInBusinessLogic?

    init(universalLinksProvider: NYPLUniversalLinksSettings) {
        self.universalLinksProvider = universalLinksProvider
    }

    /// Factory for the problem-doc → UI-delegate bridge closure used inside
    /// `presentSAMLWebView`. Exposed at internal access so tests can drive
    /// the synthesised behaviour without standing up a real SwiftUI sheet —
    /// `SignInWebSheetPresenter.presentOnTop` walks the topmost VC, which is
    /// not testable in isolation.
    ///
    /// Pure function shape: given the captured `[weak self]`, returns a
    /// closure that resolves the businessLogic, builds title/message
    /// fallback strings, synthesises an `NSError` with a dedicated SAML
    /// domain so the downstream logger can identify the source, and
    /// dispatches onto the main queue (the delegate drives UIKit alerts).
    func makeProblemFoundHandler() -> (TPPProblemDocument?) -> Void {
        return { [weak self] problemDocument in
            guard let businessLogic = self?.businessLogic else { return }
            let title = problemDocument?.title ?? Strings.Error.loginErrorTitle
            let message = problemDocument?.detail
                ?? problemDocument?.title
                ?? Strings.Error.loginErrorDescription
            let error = NSError(
                domain: "SAML.SignIn.ProblemDocument",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
            // `TPPMainThreadRun.asyncIfNeeded` (non-`@Sendable` closure) instead
            // of `DispatchQueue.main.async` (whose closure is `@Sendable`): the
            // latter trips the `complete`-mode "capture of non-Sendable
            // businessLogic in a @Sendable closure" diagnostic. Behavior-
            // equivalent for surfacing a UIKit alert.
            TPPMainThreadRun.asyncIfNeeded {
                businessLogic.uiDelegate?.businessLogic(
                    businessLogic,
                    didEncounterValidationError: error,
                    userFriendlyErrorTitle: title,
                    andMessage: message
                )
            }
        }
    }

    func presentSAMLWebView(url: URL,
                            cookies: [HTTPCookie],
                            loginCompletion: @escaping (URL, [HTTPCookie]) -> Void,
                            loginCancel: @escaping () -> Void) {
        // The actual presenter walks to the topmost VC; we don't need the
        // uiDelegate to be a VC. This matches the legacy `presentOnTop`
        // path that MyBooksDownloadCenter / BookSignInRedirectHandler use.
        let request = URLRequest(url: url)
        let universalLinks = universalLinksProvider.universalLinksURL
        // HelpSpot 17870 — build the handler ON THE NONISOLATED HOP so the
        // `[weak self]` capture happens before the main hop. The handler itself
        // dispatches to main internally.
        let problemHandler = makeProblemFoundHandler()

        // `TPPMainThreadRun.asyncIfNeeded` (non-`@Sendable` closure) + inner
        // `MainActor.assumeIsolated` instead of `Task { @MainActor in }` (whose
        // closure IS `@Sendable`). The `loginCompletion`/`loginCancel`/
        // `problemHandler` closures come from PalaceAuth's nonisolated
        // `SAMLWebViewPresenting` protocol and are NOT `Sendable`; carrying them
        // into a `@Sendable` Task tripped the `complete`-mode "sending value
        // risks data races" diagnostic (188–198). The non-`@Sendable` hop keeps
        // them off the sending path, and `assumeIsolated` supplies the main-actor
        // context the `@MainActor` `SignInWebSheetViewModel` init and
        // `SignInWebSheetPresenter.presentOnTop` require. The sole caller
        // (`TPPSAMLHelper.logIn`) already runs on the main thread, so presenting
        // synchronously-on-main vs. via a deferred Task is behavior-equivalent.
        TPPMainThreadRun.asyncIfNeeded {
            MainActor.assumeIsolated {
                let model = SignInWebSheetViewModel(
                    cookies: cookies,
                    request: request,
                    universalLinksURL: universalLinks,
                    autoPresentIfNeeded: false,
                    loginCompletionHandler: loginCompletion,
                    loginCancelHandler: loginCancel,
                    problemFoundHandler: problemHandler
                )
                SignInWebSheetPresenter.presentOnTop(model: model)
            }
        }
    }

    func dismissSAMLWebView(animated: Bool, completion: (() -> Void)?) {
        // Non-`@Sendable` main hop + `assumeIsolated` (see `presentSAMLWebView`):
        // the `completion` closure from the nonisolated `SAMLWebViewPresenting`
        // protocol is not `Sendable`, so it must not be carried into a
        // `@Sendable` Task. `SignInWebSheetPresenter.dismissTop` is `@MainActor`.
        TPPMainThreadRun.asyncIfNeeded {
            MainActor.assumeIsolated {
                SignInWebSheetPresenter.dismissTop(animated: animated, completion: completion)
            }
        }
    }
}

// MARK: - TPPSignInValidationContext conformance

/// Bridges `TPPSignInBusinessLogic.selectedAuthentication` (rich
/// `AccountDetails.Authentication`) to the boolean predicates that
/// `PalaceAuth.TPPUserAccountFrontEndValidation` reads. PalaceAuth doesn't
/// see `LoginKeyboard` (it lives on `AccountDetails`); this extension
/// flattens each predicate to a Bool the validator can act on.
// `@preconcurrency`: `TPPSignInValidationContext` (PalaceAuth) is a nonisolated
// protocol, but these witnesses read `@MainActor` instance state
// (`selectedAuthentication`, `userAccount`). The sole consumer,
// `TPPUserAccountFrontEndValidation` (a `UITextFieldDelegate`), only calls them
// on the main thread, so `@preconcurrency` accepts the isolated witnesses and
// inserts a runtime main-actor check at the dynamic-dispatch boundary.
extension TPPSignInBusinessLogic: @preconcurrency TPPSignInValidationContext {
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

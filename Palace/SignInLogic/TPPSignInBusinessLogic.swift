//
//  TPPSignInBusinessLogic.swift
//  The Palace Project
//
//  Created by Ettore Pasquini on 5/5/20.
//  Copyright © 2020 NYPL Labs. All rights reserved.
//

import CoreLocation
import PalaceLogging
import PalaceCatalog
import PalaceAuth

@objc enum TPPAuthRequestType: Int {
    case signIn = 1
    case signOut = 2
}

@objc protocol TPPBookDownloadsDeleting {
    func reset(_ libraryID: String!)
}

@objc protocol TPPBookRegistrySyncing: NSObjectProtocol {
    var isSyncing: Bool {get}
    func reset(_ libraryAccountUUID: String)
    func sync()
}

@objc protocol TPPDRMAuthorizing: NSObjectProtocol {
    var workflowsInProgress: Bool {get}
    func isUserAuthorized(_ userID: String!, withDevice device: String!) -> Bool
    func authorize(withVendorID vendorID: String!, username: String!, password: String!, completion: (@Sendable (Bool, Error?, String?, String?) -> Void)!)
    func deauthorize(withUsername username: String!, password: String!, userID: String!, deviceID: String!, completion: (@Sendable (Bool, Error?) -> Void)!)
}

// NYPLADEPT's conformance to TPPDRMAuthorizing now lives at
// `Palace/Accounts/User/NYPLADEPT+TPPDRMAuthorizing.swift` (added to xcodeproj
// during the swarm_ea663ab6 recovery wiring stage).

// Swift 6 `complete` mode: `TPPSignInBusinessLogic` is a UI-driving auth
// orchestrator — it reads/writes `@MainActor`-isolated UIKit state (alerts,
// `UIApplication.shared`, `WKWebsiteDataStore`), its `uiDelegate` is a UIKit
// view controller / `@MainActor` view model, and every entry point
// (`logIn`, `logOut`, `performForceReset`, card creation, DRM authorize) is
// reached from the main thread. Isolating the whole type to `@MainActor` is
// the correct isolation-only fix: it replaces the ~28 scattered
// `MainActor.assumeIsolated` / non-`@Sendable`-hop workarounds that only
// existed because the type was nonisolated. The two `@objc` provider
// protocols (`TPPSignedInStateProvider`, `TPPCurrentLibraryAccountProvider`)
// are nonisolated `@objc` protocols whose witnesses read main-actor instance
// state, so the conformances carry `@preconcurrency` — the runtime is already
// main-thread-correct (every call site is on main); `@preconcurrency` tells the
// checker to accept the isolated witnesses against the nonisolated requirement.
@MainActor
class TPPSignInBusinessLogic: NSObject, @preconcurrency TPPSignedInStateProvider, @preconcurrency TPPCurrentLibraryAccountProvider {
    var onLocationAuthorizationCompletion: (UINavigationController?, Error?) -> Void = {_, _ in }

    /// Makes a business logic object with a network request executor that
    /// performs no persistent storage for caching.
    convenience init(libraryAccountID: String,
                     libraryAccountsProvider: TPPLibraryAccountsProvider,
                     urlSettingsProvider: NYPLUniversalLinksSettings & NYPLFeedURLProvider,
                     bookRegistry: TPPBookRegistrySyncing,
                     bookDownloadsCenter: TPPBookDownloadsDeleting,
                     userAccountProvider: TPPUserAccountProvider.Type,
                     uiDelegate: TPPSignInOutBusinessLogicUIDelegate?,
                     drmAuthorizer: TPPDRMAuthorizing?) {
        self.init(libraryAccountID: libraryAccountID,
                  libraryAccountsProvider: libraryAccountsProvider,
                  urlSettingsProvider: urlSettingsProvider,
                  bookRegistry: bookRegistry,
                  bookDownloadsCenter: bookDownloadsCenter,
                  userAccountProvider: userAccountProvider,
                  networkExecutor: TPPNetworkExecutor(credentialsProvider: uiDelegate,
                                                      cachingStrategy: .ephemeral,
                                                      delegateQueue: OperationQueue.main),
                  uiDelegate: uiDelegate,
                  drmAuthorizer: drmAuthorizer)
    }

    /// Designated initializer.
    init(libraryAccountID: String,
         libraryAccountsProvider: TPPLibraryAccountsProvider,
         urlSettingsProvider: NYPLUniversalLinksSettings & NYPLFeedURLProvider,
         bookRegistry: TPPBookRegistrySyncing,
         bookDownloadsCenter: TPPBookDownloadsDeleting,
         userAccountProvider: TPPUserAccountProvider.Type,
         networkExecutor: TPPRequestExecuting,
         uiDelegate: TPPSignInOutBusinessLogicUIDelegate?,
         drmAuthorizer: TPPDRMAuthorizing?) {
        self.uiDelegate = uiDelegate
        self.libraryAccountID = libraryAccountID
        self.libraryAccountsProvider = libraryAccountsProvider
        self.urlSettingsProvider = urlSettingsProvider
        self.bookRegistry = bookRegistry
        self.bookDownloadsCenter = bookDownloadsCenter
        self.userAccountProvider = userAccountProvider
        self.networker = networkExecutor
        self.drmAuthorizer = drmAuthorizer
        // Pre-init the SAML adapters; cross-references are wired post-super.init.
        let samlContext = LegacySAMLAuthContext()
        let samlPresenter = LegacySAMLWebViewPresenter(universalLinksProvider: urlSettingsProvider)
        self._samlContext = samlContext
        self._samlPresenter = samlPresenter
        self._samlHelper = TPPSAMLHelper(
            universalLinksProvider: UniversalLinksAdapter(provider: urlSettingsProvider),
            context: samlContext,
            presenter: samlPresenter
        )
        super.init()
        // Now that `self` is fully initialized, wire the back-references.
        // - context: needs businessLogic to surface IDP / cookies / errors.
        // - presenter (HelpSpot 17870): needs businessLogic so its
        //   problem-document handler can route problem-doc events to
        //   `uiDelegate.businessLogic(_:didEncounterValidationError:...)`.
        //   Both are `weak` so no retain cycle vs the adapters that
        //   `_samlHelper` holds weakly.
        samlContext.businessLogic = self
        samlPresenter.businessLogic = self
    }

    /// Signing in and out may imply syncing the book registry.
    let bookRegistry: TPPBookRegistrySyncing

    /// Signing out implies removing book downloads from the device.
    let bookDownloadsCenter: TPPBookDownloadsDeleting

    /// Provides the user account for a given library.
    private let userAccountProvider: TPPUserAccountProvider.Type

    /// THe object determining whether there's an ongoing DRM authorization.
    weak private(set) var drmAuthorizer: TPPDRMAuthorizing?

    /// The primary way for the business logic to communicate with the UI.
    @objc weak var uiDelegate: TPPSignInOutBusinessLogicUIDelegate?

    private var uiContext: String {
        return uiDelegate?.context ?? "Unknown"
    }

    // MARK: - Auth state machine

    /// In-flight auth state managed by `AuthReducer`. The legacy `@objc`
    /// properties below are computed from this state — `authState` is the
    /// single source of truth.
    /// Internal so tests under `@testable import Palace` can assert against
    /// it directly when the public delegate API isn't expressive enough.
    var authState = AuthState()

    /// Run an `AuthAction` through `AuthReducer`. Effects are currently all
    /// `.none`, so we discard the return value.
    func dispatch(_ action: AuthAction) {
        _ = AuthReducer.reduce(&authState, action)
    }

    /// This flag should be set if the instance is used to register new users.
    @objc var isLoggingInAfterSignUp: Bool {
        get { authState.isLoggingInAfterSignUp }
        set { dispatch(.loggingInAfterSignUpFlagSet(newValue)) }
    }

    /// A closure that will be invoked at the end of the sign-in process when
    /// refreshing authentication.
    @objc var refreshAuthCompletion: (() -> Void)?

    // MARK: - OAuth / SAML / Clever Info

    /// The current OAuth token if available.
    var authToken: String? { authState.authToken }

    var authTokenExpiration: Date? { authState.authTokenExpiration }

    /// Barcode/PIN captured at sign-in time so that `finalizeSignIn` does not
    /// need to re-read them from the ViewModel, which may have been cleared by
    /// an intermediate `accountDidChange` notification.
    var capturedBarcode: String? { authState.capturedBarcode }
    var capturedPin: String? { authState.capturedPin }

    /// The current patron info if available. Excluded from `AuthState` by
    /// design — opaque dictionary that's not Equatable and is set/cleared
    /// imperatively via `updateUserAccount`.
    var patron: [String: Any]?

    /// Settings used by OAuth sign-in flows.
    let urlSettingsProvider: NYPLUniversalLinksSettings & NYPLFeedURLProvider

    /// NotificationCenter used by OAuth observer registration / removal.
    /// Production defaults to `.default`; tests may inject an isolated
    /// `NotificationCenter()` so the OAuth `handleRedirectURL` add/remove
    /// pair is verifiable end-to-end without polluting global notifications.
    /// Set in `init` (and overrideable via `setNotificationCenterForTests`
    /// below for callers that already constructed via the legacy initializer).
    var notificationCenter: NotificationCenter = .default

    /// Test seam (see §10.1 of `docs/Testing/Test_Seams_Refactor_Plan.md`):
    /// allows a unit test to swap in an isolated NotificationCenter after
    /// init so the OAuth observer add/remove pair can be exercised against a
    /// hermetic notification bus rather than the global `.default`.
    @objc func setNotificationCenterForTests(_ center: NotificationCenter) {
        self.notificationCenter = center
    }

    /// Cookies used to authenticate. Only required for the SAML flow.
    ///
    /// TODO(wave-4-SignInModal-migration): the SAML refactor's Phases 1, 2,
    /// and 4 (UI decoupling via `SAMLAuthContext` + `SAMLWebViewPresenting`
    /// protocols; force-unwrap elimination; `ignoreSignedInState` →
    /// `AuthReducer`) already landed via swarm_ea663ab6. What REMAINS from
    /// `~/.claude/plans/calm-knitting-thunder.md` is:
    ///   - Phase 3 cookie-validation deduplication (this `cookies` property
    ///     duplicates `samlHelper.cookies`; both are written by
    ///     `LegacySAMLAuthContext.handleSAMLRedirect`).
    ///   - Phase 5 state isolation — moving the SAML-specific cookie cache
    ///     onto the helper exclusively so the businessLogic doesn't
    ///     maintain two parallel sources of truth.
    /// Once `SignInModalSheetPresenter` (PR #1022) lands wave 4's migration
    /// of the 9 remaining `SignInModalPresenter.presentSignInModal` call
    /// sites, the cookies-duplication cleanup can be done in the same pass
    /// (callers will read from `samlHelper.cookies` directly). Until then
    /// both fields are maintained by `LegacySAMLAuthContext.handleSAMLRedirect`
    /// and this property is kept as the legacy mirror.
    ///
    /// swarm_18b0d071 wave 3 Module B is a HARDENING pass — full migration
    /// is explicitly deferred per the swarm's plan.md anti-scope section.
    @objc var cookies: [HTTPCookie]?

    // MARK: - SAML triad (helper + context + presenter)
    //
    // This triad replaces the inline `_legacyContext` / `_legacyPresenter`
    // pair that used to live inside `TPPSAMLHelper` on `develop`. The helper
    // moved into the `PalaceAuth` SPM package as part of the leaf extraction;
    // the two adapter halves stay in the main target (they touch
    // `TPPSignInBusinessLogic`, `OPDS2SamlIDP`, and `SignInWebSheetPresenter`
    // which all remain main-target types), and `TPPSignInBusinessLogic` owns
    // strong references to all three so the helper's `weak` back-references
    // don't deallocate the adapters out from under it.

    /// Performs initiation rites for SAML sign-in.
    /// Eagerly created for backward compatibility; use `samlHelperIfNeeded`
    /// for lazy access when SAML support is not guaranteed.
    private let _samlHelper: TPPSAMLHelper

    /// Strong reference to the SAML context adapter — TPPSAMLHelper holds it
    /// weakly, so without this retain it would be released immediately after
    /// init returns.
    private let _samlContext: LegacySAMLAuthContext

    /// Strong reference to the SAML presenter adapter — see _samlContext.
    private let _samlPresenter: LegacySAMLWebViewPresenter

    /// The SAML helper — always available (eagerly created in init).
    var samlHelper: TPPSAMLHelper { _samlHelper }

    /// Returns the SAML helper only if the current library supports SAML auth.
    /// Returns nil for non-SAML libraries to avoid polluting their state.
    var samlHelperIfNeeded: TPPSAMLHelper? {
        guard isSamlPossible() || selectedAuthentication?.isSaml == true else {
            return nil
        }
        return _samlHelper
    }

    /// This overrides the sign-in state logic to behave as if the user isn't
    /// authenticated. This is useful if we already have credentials, but
    /// the session expired (e.g. SAML flow).
    /// isSignedIn() checks both this flag AND userAccount.authState == .credentialsStale.
    var ignoreSignedInState: Bool { authState.ignoreSignedInState }

    /// This is `true` during the process of validating credentials.
    ///
    /// Credentials validation happens *after* the initial sign-in intent
    /// where the app obtains the credentials in some way (e.g. user
    /// typing them in, or the redirection to 3rd party website for OAuth;
    /// see `logIn`), and *before* doing DRM authorization (see
    /// `drmAuthorizeUserData`).
    @objc var isValidatingCredentials: Bool { authState.isValidatingCredentials }

    // MARK: - Library Accounts Info

    /// The ID of the library this object is signing in to.
    /// - Note: This is also provided by `libraryAccountsProvider::currentAccount`
    /// but that could be returning nil if called too early on.
    @objc let libraryAccountID: String

    /// The object providing library account information.
    let libraryAccountsProvider: TPPLibraryAccountsProvider

    @objc var libraryAccount: Account? {
        return libraryAccountsProvider.account(libraryAccountID)
    }

    var currentAccount: Account? {
        return libraryAccount
    }

    /// State-machine-aware synchronous read of `AccountDetails`. Returns
    /// `nil` when details have not yet transitioned to `.detailsLoaded`
    /// (i.e. `.notLoaded`, `.basicInfoLoaded`, `.detailsLoading`,
    /// `.detailsFailed`, or `.detailsEvicted` — the eviction-marker
    /// sibling added by the swarm_51f248d5 enum split). This preserves the
    /// legacy `account.details?` nil-tolerance for sync UI/`@objc` callers
    /// that cannot adopt the async `awaitReady()` gate without cascading
    /// `async` upward through SwiftUI/UIKit render paths.
    ///
    /// Bucket A migration policy (per ADR `docs/architecture/account-state-machine.md`):
    /// the 6 sub-sites in this file are sync property getters / `@objc`
    /// methods read from SwiftUI render bodies and synchronous UI flows.
    /// Reading `loadState` directly is the state-machine-aware version of
    /// what the legacy `details?` reads did — both return non-nil only
    /// when details are loaded. Migration to the truly-async
    /// `awaitReady()` form happens at user-initiated entry points
    /// (`startRegularCardCreation`, `TPPAgeCheck`, `NotificationService`
    /// hold navigation) where wrapping in a `Task` does not cascade.
    // Internal (not private) so extensions in other files can consume it.
    // Phase 2 (Bucket B) reuses it from `+BookmarkSyncing` to gate the
    // sync-button visibility on the same readiness contract used by the
    // sync sites — there's no reason for a parallel implementation.
    var loadedAccountDetails: AccountDetails? {
        guard let account = libraryAccount else { return nil }
        if case .detailsLoaded(let details) = account.loadState {
            return details
        }
        return nil
    }

    /// Returns a valid password reset URL or `nil`
    ///
    /// Verifies that:
    /// - password reset link exists in authentication document;
    /// - contains a valid URL,
    /// - can be opened by the app.
    private var validPasswordResetUrl: URL? {
        guard let passwordResetHref = libraryAccount?.authenticationDocument?.links?.first(rel: .passwordReset)?.href,
              let passwordResetUrl = URL(string: passwordResetHref),
              // `UIApplication.shared.canOpenURL` is `@MainActor`-isolated. This
              // getter feeds `canResetPassword` / `resetPassword`, both reached
              // only from `@MainActor` UI (`AccountDetailViewModel`), so the
              // main-actor precondition holds. `assumeIsolated` asserts it for
              // the `complete`-mode checker without changing the synchronous
              // getter contract that SwiftUI render bodies depend on.
              MainActor.assumeIsolated({ UIApplication.shared.canOpenURL(passwordResetUrl) }) else {
            return nil
        }
        return passwordResetUrl
    }

    /// Verifies that current library account can reset user password.
    @objc var canResetPassword: Bool {
        validPasswordResetUrl != nil
    }

    /// Opens password reset URL to reset user password.
    ///
    /// This function doesn't show any error; use `canResetPassword` to identify if password can actually be reset.
    @objc func resetPassword() {
        guard let passwordResetUrl = validPasswordResetUrl else {
            return
        }
        // `UIApplication.shared.open` is `@MainActor`-isolated. Only caller is
        // `AccountDetailViewModel.resetPassword()` (`@MainActor`), so the
        // precondition holds; assert it for the `complete`-mode checker without
        // making this `@objc` method `async`.
        MainActor.assumeIsolated {
            UIApplication.shared.open(passwordResetUrl)
        }
    }

    @objc var selectedIDP: OPDS2SamlIDP?
    let locationManager = CLLocationManager()

    private var _selectedAuthentication: AccountDetails.Authentication?

    /// Re-entrancy guard for `awaitReadyThenRetryLogIn(with:)`. Ensures a
    /// `logIn()` that arrives before the auth document has loaded waits for
    /// readiness exactly once. Without this, a `.detailsFailed` terminal
    /// (where `selectedAuthentication` stays nil) could loop the retry.
    private var isAwaitingReadinessForLogIn = false

    @objc var selectedAuthentication: AccountDetails.Authentication? {
        get {
            guard _selectedAuthentication == nil else { return _selectedAuthentication }
            guard userAccount.authDefinition == nil else { return userAccount.authDefinition }
            // Bucket A migration (line 281): state-machine-aware read. Returns
            // `nil` until details are `.detailsLoaded` — same null-tolerance as
            // legacy `libraryAccount?.details?.auths`.
            guard let auths = loadedAccountDetails?.auths else { return nil }
            guard auths.count > 1 else { return auths.first }

            return nil
        }
        set {
            _selectedAuthentication = newValue
        }
    }

    // MARK: - Network Requests Logic

    let networker: TPPRequestExecuting

    /// Creates a request object for signing in or out, depending on
    /// on which authentication mechanism is currently selected.
    /// - Note: If it was impossible to create the request, an error will be
    /// reported.
    /// - Parameters:
    ///   - authType: What kind of authentication request should be created.
    ///   - context: A string for further context for error reporting.
    /// - Returns: A request for signing in or signing out.
    func makeRequest(for authType: TPPAuthRequestType,
                     context: String) -> URLRequest? {

        let authTypeStr = (authType == .signOut ? "signing out" : "signing in")

        // Bucket A migration (line 309): state-machine-aware read of
        // `userProfileUrl`. Sync getter, no async cascade.
        let loadedDetails = loadedAccountDetails
        guard
            let urlStr = loadedDetails?.userProfileUrl,
            let url = URL(string: urlStr) else {
            TPPErrorLogger.logError(
                withCode: .noURL,
                summary: "Error: unable to create URL for \(authTypeStr)",
                metadata: ["library.userProfileUrl": loadedDetails?.userProfileUrl ?? "N/A"])
            return nil
        }

        var req = URLRequest(url: url, applyingCustomUserAgent: true)

        if let selectedAuth = selectedAuthentication,
           selectedAuth.isOauth || selectedAuth.isSaml || selectedAuth.isToken || selectedAuth.isOidc {

            // The nil-coalescing on the authToken covers 2 cases:
            // - sign in, where uiDelegate has the token because we just obtained it
            // externally (via OAuth) but user account may not have been updated yet;
            // - sign out, where the uiDelegate may not have the token unless the user
            // just signed in, but the user account will definitely have it.
            if let authToken = (authToken ?? userAccount.authToken) {
                // Note: this is officially unsupported by the URL loading system
                // in iOS but it does work. It is necessary because the officially
                // supported method of providing authorization info to a request is via
                // `URLAuthenticationChallenge`, which has no api for Bearer token
                // authentication. Basic auth via username + password works fine with
                // challenges (see `NYPLSignInURLSessionChallengeHandler`).
                let authorization = "Bearer \(authToken)"
                req.addValue(authorization, forHTTPHeaderField: "Authorization")
            } else {
                Log.info(#file, "Auth token expected, but none is available.")
                TPPErrorLogger.logError(withCode: .validationWithoutAuthToken,
                                        summary: "Error \(authTypeStr): No token available during OAuth/SAML/OIDC authentication validation",
                                        metadata: [
                                            "isSAML": selectedAuth.isSaml,
                                            "isOAuth": selectedAuth.isOauth,
                                            "isOIDC": selectedAuth.isOidc,
                                            "context": context,
                                            "uiDelegate nil?": uiDelegate == nil ? "y" : "n"])
            }
        }

        return req
    }

    /// After having obtained the credentials for all authentication methods,
    /// including those that require negotiation with 3rd parties (such as
    /// Clever and SAML), validate said credentials against the Circulation
    /// Manager servers and call back to the UI once that's concluded.
    func validateCredentials() {
        dispatch(.credentialsValidationStarted)

        guard let req = makeRequest(for: .signIn, context: uiContext) else {
            let error = NSError(domain: TPPErrorLogger.clientDomain,
                                code: TPPErrorCode.noURL.rawValue,
                                userInfo: [
                                    NSLocalizedDescriptionKey:
                                        Strings.Error.serverConnectionErrorDescription,
                                    NSLocalizedRecoverySuggestionErrorKey:
                                        Strings.Error.serverConnectionErrorSuggestion])
            self.handleNetworkError(error, loggingContext: ["Context": uiContext])
            return
        }

        networker.executeRequest(req, enableTokenRefresh: false) { [weak self] result in
            guard let self = self else { return }

            let loggingContext: [String: Any] = [
                "Request": req.loggableString,
                "Attempted Barcode": self.uiDelegate?.username?.md5hex() ?? "N/A",
                "Context": self.uiContext]

            switch result {
            case .success(let responseData, _):
                self.dispatch(.credentialsValidationSucceeded)
                // Notify delegate that credentials were received and DRM processing is about to begin
                // This allows the UI to show a loading indicator after WebView dismisses
                TPPMainThreadRun.asyncIfNeeded {
                    self.uiDelegate?.businessLogicDidReceiveCredentials?(self)
                }

                #if FEATURE_DRM_CONNECTOR
                // PP-3649: Save DRM credentials from profile document but defer Adobe
                // device activation to borrow time. This avoids burning device activations
                // for users who never borrow Adobe DRM content.
                self.saveDRMCredentials(responseData, loggingContext: loggingContext)
                #else
                self.finalizeSignIn(forDRMAuthorization: true)
                #endif

            case .failure(let errorWithProblemDoc, let response):
                self.handleNetworkError(errorWithProblemDoc as NSError,
                                        response: response,
                                        loggingContext: loggingContext)
            }
        }
    }

    /// Seam-friendly overload (§10.2) that accepts the abstract
    /// `TokenRefreshing` protocol so unit tests can substitute a pure
    /// in-memory mock for the production concrete `TPPNetworkExecutor`.
    /// The original concrete-typed overload below remains for ObjC / source
    /// compatibility with all existing call sites.
    func getBearerToken(username: String,
                        password: String,
                        tokenURL: URL,
                        tokenRefresher: TokenRefreshing,
                        completion: (() -> Void)? = nil) {
        tokenRefresher.executeTokenRefresh(username: username,
                                           password: password,
                                           tokenURL: tokenURL,
                                           accountId: libraryAccountID) { [weak self] result in
            // `executeTokenRefresh` invokes this completion on a BACKGROUND queue
            // (its `Result<…> -> Void` param is neither `@Sendable` nor
            // `@MainActor`). Everything below touches `@MainActor` state — the
            // whole type is `@MainActor`, and `validateCredentials()` /
            // `handleNetworkError()` read `uiContext` → the `@objc @MainActor`
            // `AccountDetailViewModel.context` getter. Running that off-main traps
            // under Swift 6 (`dispatch_assert_queue_fail`) and crashed **Sign In**
            // (Crashlytics, 3.3.0, 2/2 repro). Hop to the main actor first.
            // `nonisolated(unsafe)` keeps the non-Sendable `Result` (its `Error`
            // is a non-Sendable existential) from tripping the region check as it
            // crosses into the task — the value is only read, on main.
            nonisolated(unsafe) let outcome = result
            Task { @MainActor in
                defer { completion?() }
                switch outcome {
                case .success(let tokenResponse):
                    self?.dispatch(.bearerTokenReceived(token: tokenResponse.accessToken,
                                                        expiration: tokenResponse.expirationDate))
                    self?.validateCredentials()
                case .failure(let error):
                    self?.handleNetworkError(error as NSError, loggingContext: ["Context": self?.uiContext as Any])
                }
            }
        }
    }

    func getBearerToken(username: String, password: String, tokenURL: URL, networkExecutor: TPPNetworkExecutor = AppContainer.production().networkExecutor, completion: (() -> Void)? = nil) {
        getBearerToken(username: username,
                       password: password,
                       tokenURL: tokenURL,
                       tokenRefresher: networkExecutor,
                       completion: completion)
    }

    /// Uses the problem document's `title` and `message` fields to
    ///  communicate a user friendly error info to the `uiDelegate`.
    /// Also logs the `error`.
    private func handleNetworkError(_ error: NSError,
                                    response: URLResponse? = nil,
                                    loggingContext: [String: Any]) {
        let problemDoc = error.problemDocument

        // TPPNetworkExecutor already logged the error, but this is more
        // informative
        TPPErrorLogger.logLoginError(error,
                                     library: libraryAccount,
                                     response: response,
                                     problemDocument: problemDoc,
                                     metadata: loggingContext)

        let (title, message) = Self.userFacingSignInError(for: error, problemDocument: problemDoc)
        dispatch(.credentialsValidationFailed(title: title, message: message))

        TPPMainThreadRun.asyncIfNeeded {
            self.uiDelegate?.businessLogic(self,
                                           didEncounterValidationError: error,
                                           userFriendlyErrorTitle: title,
                                           andMessage: message)
        }
    }

    /// Classifies a sign-in failure into a user-facing (title, message) pair.
    /// Precedence: server-supplied problem document > network-connectivity
    /// error > default "invalid credentials". Without the connectivity check,
    /// a dropped Wi-Fi or LTE during sign-in was misreported as bad creds.
    // `nonisolated`: pure error classifier over an `NSError` + optional
    // problem document, no actor state. Kept off `@MainActor` so nonisolated
    // callers (and the PalaceAuth `AuthReducer` mirror) can invoke it directly.
    nonisolated static func userFacingSignInError(
        for error: NSError,
        problemDocument: TPPProblemDocument?
    ) -> (title: String?, message: String?) {
        if let problemDocument {
            return (problemDocument.title, problemDocument.detail)
        }
        if isNetworkConnectivityError(error) {
            return (Strings.Error.networkUnavailableErrorTitle,
                    Strings.Error.networkUnavailableErrorMessage)
        }
        // A transient server hiccup surfaced by TokenRequest after retries were
        // exhausted (5xx / 429 / 408) is NOT bad credentials — show the
        // "try again" message rather than misreporting it as invalid creds
        // (HelpSpot 18046). Reuses the existing network-unavailable copy.
        if isTransientServerError(error) {
            return (Strings.Error.networkUnavailableErrorTitle,
                    Strings.Error.networkUnavailableErrorMessage)
        }
        return (Strings.Error.invalidCredentialsErrorTitle,
                Strings.Error.invalidCredentialsErrorMessage)
    }

    /// True when the error is a transient HTTP failure surfaced by
    /// `TokenRequest` after its bounded retry was exhausted (5xx / 429 / 408).
    /// A genuine 401/403 has a different code and is NOT matched here, so it
    /// still falls through to the "Invalid Credentials" message.
    nonisolated static func isTransientServerError(_ error: NSError) -> Bool {
        guard error.domain == TokenRequest.httpErrorDomain else { return false }
        return error.code == 408 || error.code == 429 || (500...599).contains(error.code)
    }

    /// True when the error is from URLSession indicating the request never
    /// reached the server (lost connection, DNS failure, TLS handshake, etc).
    nonisolated static func isNetworkConnectivityError(_ error: NSError) -> Bool {
        guard error.domain == NSURLErrorDomain else { return false }
        switch error.code {
        case NSURLErrorNotConnectedToInternet,
             NSURLErrorTimedOut,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorDataNotAllowed,
             NSURLErrorInternationalRoamingOff,
             NSURLErrorSecureConnectionFailed:
            return true
        default:
            return false
        }
    }

    @objc func logIn() {
        logIn(with: nil)
    }

    /// Initiates process of signing in with the server.
    @objc func logIn(with tokenURL: URL? = nil) {
        // Nothing to do without a selected auth method. But on a fast
        // (programmatic or quick-tap) sign-in the user can submit before the
        // account's `authentication_document` has finished loading — at which
        // point `selectedAuthentication` resolves to `nil` purely because
        // `loadState` has not yet reached `.detailsLoaded` (the getter reads
        // `loadedAccountDetails?.auths`). The 3.2.0 auth rewrite turned that
        // window into a SILENT no-op: no network request, no error, no UI
        // change (PP basic/token sign-in regression — build 476 → 479). A
        // human types slowly enough that details land first; automation does
        // not. Rather than drop the tap, AWAIT readiness on the user-initiated
        // entry point (the readiness gate that `Account.LoadState` was built
        // for) and re-dispatch once details are loaded. `awaitReady()` returns
        // immediately on the fast path when details are already loaded, so
        // manual sign-in behavior is unchanged.
        guard let wrapped = selectedAuthentication else {
            awaitReadyThenRetryLogIn(with: tokenURL)
            return
        }

        NotificationCenter.default.post(name: .TPPIsSigningIn, object: true)

        dispatch(.credentialCaptureStarted(barcode: uiDelegate?.username, pin: uiDelegate?.pin))

        TPPMainThreadRun.asyncIfNeeded {
            self.uiDelegate?.businessLogicWillSignIn(self)
        }

        // F-011 class-of-bug guard
        switch wrapped.authType {
        case .oauthIntermediary:
            oauthLogIn()
        case .saml:
            samlHelper.logIn {
                self.uiDelegate?.businessLogicDidCancelSignIn(self)
            }
        case .oidc:
            oidcLogIn()
        case .token:
            guard let username = self.uiDelegate?.username,
                  let password = self.uiDelegate?.pin,
                  let tokenURL = tokenURL ?? userAccount.authDefinition?.tokenURL
            else {
                validateCredentials()
                return
            }

            getBearerToken(username: username, password: password, tokenURL: tokenURL)
        case .basic, .coppa, .anonymous, .none:
            validateCredentials()
        }
    }

    /// Awaits the library account's readiness gate, then re-invokes
    /// `logIn(with:)` once details are loaded so a sign-in tap that raced the
    /// `authentication_document` fetch is honored instead of silently dropped.
    ///
    /// This is the user-initiated entry point the `Account.LoadState` /
    /// `awaitReady()` machine was designed to gate (per
    /// `docs/architecture/account-state-machine.md`); the sync read sites keep
    /// their nil-tolerance, but the *action* of signing in waits for readiness.
    ///
    /// - Fast path: when details are already `.detailsLoaded`, `awaitReady()`
    ///   returns immediately and we re-enter `logIn` on the same run loop turn,
    ///   so manual sign-in (where details have long since loaded) is unchanged.
    /// - Failure path: if readiness resolves to `.detailsFailed` /
    ///   `.detailsEvicted` (or `selectedAuthentication` is still nil after a
    ///   successful load — e.g. a genuinely auth-less library), we clear the
    ///   "signing in" state so the UI is not left spinning. The re-entrancy
    ///   guard makes this await-then-retry happen at most once per tap.
    private func awaitReadyThenRetryLogIn(with tokenURL: URL?) {
        guard !isAwaitingReadinessForLogIn else { return }
        guard let account = libraryAccount else { return }
        isAwaitingReadinessForLogIn = true

        // The post-`awaitReady()` work touches main-actor-only state
        // (`selectedAuthentication`, `logIn`, the `.TPPIsSigningIn` post) on a
        // class that is NOT `@MainActor`. Hopping back via `await MainActor.run {
        // … self … }` captures non-Sendable `self` in that `@Sendable` body and
        // trips the `targeted` "capture of 'self' in @Sendable closure"
        // diagnostic. Use the file's existing `TPPMainThreadRun.asyncIfNeeded`
        // main-thread hop (a plain, non-`@Sendable` closure) instead. The
        // re-entrancy guard (`isAwaitingReadinessForLogIn`) is cleared at the END
        // of the main-thread work on both paths — preserving the "at most once
        // per tap" window the `defer` previously provided.
        //
        // FLAGGED (shared-type dependency): the residual `complete`-mode warning
        // "passing closure as a 'sending' parameter" on this `Task` fires
        // because the body captures non-Sendable `account` (`Account`, owned by
        // the Accounts module) and non-Sendable `self` (`TPPSignInBusinessLogic`).
        // Closing it requires either `Account: Sendable` or
        // `TPPSignInBusinessLogic: @MainActor` — both out of scope for an
        // isolation-only pass on this module (see handoff §D/§F). Runtime is
        // correct: `awaitReady()` is awaited, then all state mutation hops to the
        // main thread via the non-`@Sendable` `asyncIfNeeded`.
        Task { [weak self] in
            do {
                _ = try await account.awaitReady()
            } catch {
                Log.warn(#file, "Sign-in awaited readiness but the auth document did not load: \(error)")
                TPPMainThreadRun.asyncIfNeeded { [weak self] in
                    NotificationCenter.default.post(name: .TPPIsSigningIn, object: false)
                    self?.isAwaitingReadinessForLogIn = false
                }
                return
            }

            TPPMainThreadRun.asyncIfNeeded { [weak self] in
                guard let self else { return }
                // Details are loaded now; `selectedAuthentication` resolves via
                // `loadedAccountDetails?.auths`. Re-enter the normal path. If it
                // is STILL nil (auth-less library / single-auth edge), clear the
                // signing-in state rather than recurse — the guard already
                // prevents a second await, so a nil here falls through to the
                // (now harmless) silent return on the recursive call.
                if self.selectedAuthentication != nil {
                    self.logIn(with: tokenURL)
                } else {
                    NotificationCenter.default.post(name: .TPPIsSigningIn, object: false)
                }
                self.isAwaitingReadinessForLogIn = false
            }
        }
    }

    @objc var isAuthenticationDocumentLoading: Bool { authState.isAuthenticationDocumentLoading }

    /// Makes sure we have the `libraryAccount` `details` loading the
    /// authentication document if needed.
    /// - Note: if an error occurs while loading the authentication document,
    /// an error is reported via `TPPErrorLogger`.
    /// - Parameter completion: Always called once we have the library details.
    @objc func ensureAuthenticationDocumentIsLoaded(_ completion: @escaping (Bool) -> Void) {
        if libraryAccount?.details != nil {
            completion(true)
            return
        }

        guard let libraryAccount = libraryAccount else {
            Log.warn(#file, "No library account available — cannot load auth document")
            completion(false)
            return
        }

        dispatch(.authDocumentLoadStarted)
        libraryAccount.loadAuthenticationDocument(using: self) { success in
            // `loadAuthenticationDocument`'s completion fires on the URLSession
            // delegate queue (off-main — `TPPNetworkExecutor` uses `delegateQueue:
            // nil`). `dispatch(_:)` is `@MainActor`-isolated (this whole type is
            // `@MainActor`, driving UIKit alert/VM state), so calling it off-main
            // trips Swift 6's `swift_task_checkIsolated` SIGTRAP and restarts the
            // process — the OIDC/sign-in crash cluster. Hop to main before
            // dispatching and firing the caller's completion.
            DispatchQueue.main.async {
                self.dispatch(.authDocumentLoadCompleted)
                completion(success)
            }
        }
    }

    /// Set up the sign-in business logic to refresh the authentication token
    /// for the currently signed in user.
    ///
    /// This method determines if user input is required in order to keep the
    /// user login session going. If no user input is required, it proceeds
    /// to fetch a new token keeping the user logged in.
    ///
    /// - IMPORTANT: This method is not thread-safe.
    /// - Parameters:
    ///   - usingExistingCredentials: Force using existing credentials for the
    ///   authentication refresh attempt.
    ///   - completion: Block to be run after the authentication refresh attempt
    ///   is performed.
    /// - Returns: `true` if a sign-in UI is needed to refresh authentication.
    @objc func refreshAuthIfNeeded(usingExistingCredentials: Bool,
                                   completion: (() -> Void)?) -> Bool {
        guard
            let authDef = userAccount.authDefinition,
            authDef.isBasic || authDef.isOauth || authDef.isSaml || authDef.isOidc || (authDef.isToken && AppContainer.production().accountsManager.currentUserAccount.authTokenHasExpired)
        else {
            completion?()
            return false
        }

        refreshAuthCompletion = completion

        if let methodType = authDef.asAuthMethodType {
            dispatch(.refreshAuthStarted(authType: methodType,
                                         usingExistingCredentials: usingExistingCredentials))
        }

        // reset authentication if needed
        if authDef.isBrowserBased {
            if !usingExistingCredentials {
                // when the IdP session expired, force the user to pick the
                // IdP again instead of reusing stale cookies/tokens
                userAccount.markCredentialsStale()
                if authDef.isSaml {
                    selectedAuthentication = nil
                }
            }
        }

        if authDef.isToken, let barcode = userAccount.barcode, let pin = userAccount.pin, let tokenURL = userAccount.authDefinition?.tokenURL {
            getBearerToken(username: barcode, password: pin, tokenURL: tokenURL, completion: completion)
        } else if authDef.isBasic {
            if usingExistingCredentials && userAccount.hasBarcodeAndPIN() {
                if uiDelegate == nil {
                    #if DEBUG
                    preconditionFailure("uiDelegate must be set for logIn to work correctly")
                    #else
                    TPPErrorLogger.logError(
                        withCode: .appLogicInconsistency,
                        summary: "uiDelegate missing while refreshing basic auth",
                        metadata: [
                            "usingExistingCredentials": usingExistingCredentials,
                            "hashedBarcode": userAccount.barcode?.md5hex() ?? "N/A"
                        ])
                    #endif
                }
                // `UITextField.text`/`becomeFirstResponder()` are
                // `@MainActor`-isolated. `refreshAuthIfNeeded` runs on the main
                // actor in production (driven by the `TPPReauthenticator` →
                // `SignInModalSheetPresenter` UI path); assert the isolation
                // for the `complete`-mode checker without making this `@objc`
                // Bool-returning method `async`.
                MainActor.assumeIsolated {
                    uiDelegate?.usernameTextField?.text = userAccount.barcode
                    uiDelegate?.PINTextField?.text = userAccount.PIN
                }

                logIn()
                return false
            } else {
                MainActor.assumeIsolated {
                    uiDelegate?.usernameTextField?.text = ""
                    uiDelegate?.PINTextField?.text = ""
                    uiDelegate?.usernameTextField?.becomeFirstResponder()
                }
            }
        }

        return true
    }

    // MARK: - User Account Management

    /// The user account for the library we are signing in to.
    ///
    /// Returns the per-library instance owned by `libraryAccountsProvider`
    /// (AccountsManager). This replaces the old `userAccountProvider.sharedAccount(libraryUUID:)`
    /// path which mutated the legacy singleton's `libraryUUID` and caused
    /// TOCTOU races during account switches.
    @objc var userAccount: TPPUserAccount {
        return libraryAccountsProvider.userAccount(for: libraryAccountID)
    }

    /// Updates the user account for the library we are signing in to.
    /// - Parameters:
    ///   - drmSuccess: whether the DRM authorization was successful or not.
    ///   Ignored if the app is built without DRM support.
    ///   - barcode: The new barcode, if available.
    ///   - pin: The new PIN, if barcode is provided.
    ///   - authToken: the token if `selectedAuthentication` is OAuth or SAML.
    ///   - patron: The patron info for OAuth / SAML authentication.
    ///   - cookies: Cookies for SAML authentication.
    func updateUserAccount(forDRMAuthorization drmSuccess: Bool,
                           withBarcode barcode: String?,
                           pin: String?,
                           authToken: String?,
                           expirationDate: Date?,
                           patron: [String: Any]?,
                           cookies: [HTTPCookie]?) {
        #if FEATURE_DRM_CONNECTOR
        guard drmSuccess else {
            Log.warn(#file, "DRM authorization failed — preserving existing credentials")
            NotificationCenter.default.post(name: .TPPIsSigningIn, object: false)
            return
        }
        #endif

        let selectedAuth = selectedAuthentication
        userAccount.atomicUpdate(for: libraryAccountID) { account in
            if let selectedAuth {
                if selectedAuth.isOauth || selectedAuth.isSaml || selectedAuth.isToken || selectedAuth.isOidc {
                    if let patron {
                        account.setPatron(patron)
                    }
                    if let authToken {
                        account.setAuthToken(authToken, barcode: barcode, pin: pin, expirationDate: expirationDate)
                    } else if let barcode, let pin {
                        account.setBarcode(barcode, PIN: pin)
                    }
                } else if let barcode, let pin {
                    account.setBarcode(barcode, PIN: pin)
                }

                if selectedAuth.isSaml, let cookies {
                    account.setCookies(cookies)
                }
                account.setAuthDefinitionWithoutUpdate(authDefinition: selectedAuth)
            } else if let barcode, let pin {
                account.setBarcode(barcode, PIN: pin)
            }

            account.markLoggedIn()
        }

        if libraryAccountID == libraryAccountsProvider.currentAccountId {
            bookRegistry.sync()
        }

        // Canonical credential store is now TPPUserAccount — clear all
        // in-flight reducer state (token, captured creds, ignoreSignedIn).
        dispatch(.userAccountUpdated)

        NotificationCenter.default.post(name: .TPPIsSigningIn, object: false)
    }

    // MARK: - Available Features Checks

    @objc func librarySupportsBarcodeDisplay() -> Bool {
        // For now, only supports libraries granted access in Accounts.json,
        // is signed in, and has an authorization ID returned from the loans feed.
        return userAccount.hasBarcodeAndPIN() &&
            userAccount.authorizationIdentifier != nil &&
            (selectedAuthentication?.supportsBarcodeDisplay ?? false)
    }

    func isSignedIn() -> Bool {
        // Phase 4: Use auth state instead of boolean flag.
        // credentialsStale means we have credentials but the session expired
        // (e.g. SAML IdP session timeout) — user must re-authenticate.
        if userAccount.authState == .credentialsStale {
            return false
        }
        if ignoreSignedInState {
            return false
        }
        return userAccount.hasCredentials()
    }

    /// - Returns: Whether it is possible to sign up for a new account or not.
    @objc func registrationIsPossible() -> Bool {
        // Bucket A migration (line 732): state-machine-aware read of
        // `signUpUrl`. Sync `@objc`, called from SwiftUI rendering.
        return !isSignedIn() && loadedAccountDetails?.signUpUrl != nil
    }

    @objc func isSamlPossible() -> Bool {
        // Bucket A migration (line 736): state-machine-aware read.
        // Per ADR: SAML reauth inherits the existing 15s reauth-coordinator
        // timeout — do not wrap in additional `withTimeout`. Sync `@objc`
        // signature is preserved; reading `loadState` does not block.
        // On `.detailsFailed` this returns `false`, matching the legacy
        // nil-semantic — the migration does NOT crash on `.detailsFailed`.
        loadedAccountDetails?.auths.contains { $0.isSaml } ?? false
    }

    /// Auto-select a WebView-based authentication (SAML, then OIDC) when
    /// the library advertises multiple auth methods and none is explicitly
    /// chosen. Fixes the regression where multi-auth SAML libraries rendered
    /// the basic-auth credential fields instead of the SAML sign-in prompt.
    ///
    /// Also auto-selects the sole SAML IdP when the chosen SAML auth
    /// advertises exactly one — without this, tapping "Sign in" on a
    /// single-IdP SAML library is a silent no-op because
    /// `samlHelper.logIn()` guards on `selectedIDP?.url`.
    ///
    /// Idempotent: only sets `selectedAuthentication` / `selectedIDP` when
    /// they are currently nil.
    @objc func selectPreferredAuthIfNeeded() {
        // Bucket A migration (line 753): state-machine-aware read of `auths`.
        // Sync `@objc`, called from sync UI flows (e.g. `setupViews`).
        if selectedAuthentication == nil,
           let auths = loadedAccountDetails?.auths, auths.count > 1 {
            if let saml = auths.first(where: { $0.isSaml }) {
                selectedAuthentication = saml
            } else if let oidc = auths.first(where: { $0.isOidc }) {
                selectedAuthentication = oidc
            }
        }

        // Auto-select the sole SAML IdP so Sign In opens the WebView
        // immediately instead of silently no-op'ing. Multi-IdP libraries
        // still require the user to pick via the IdP list UI.
        if selectedIDP == nil,
           let samlAuth = selectedAuthentication,
           samlAuth.isSaml,
           let idps = samlAuth.samlIdps,
           idps.count == 1 {
            selectedIDP = idps.first
        }
    }

    @objc func shouldShowEULALink() -> Bool {
        // BUG-002 — Account screen leaked "By signing in, you agree to the End
        // User License Agreement." copy post-auth, directly under the Sign-out
        // button. The agreement-acceptance footer is contextually a sign-in
        // affordance; once the patron is signed in they have already agreed,
        // and the standalone EULA entry is reachable via Settings → User
        // Agreement and the Software Licenses sheet. Gate visibility on the
        // sign-in form being the active surface.
        // Bucket A migration (line 781): state-machine-aware read of EULA
        // URL. Sync `@objc`, called from SwiftUI rendering.
        guard loadedAccountDetails?.getLicenseURL(.eula) != nil else {
            return false
        }
        return !isSignedIn()
    }

    // MARK: - Adobe DRM Activation Skip Logic

    /// Determines whether Adobe DRM activation should be skipped during sign-in.
    ///
    /// Adobe device activation should be skipped when:
    /// 1. The account is in `.credentialsStale` state (session expired but Adobe still valid)
    /// 2. The DRM authorizer confirms the device is already authorized
    /// 3. We have existing Adobe credentials (userID and deviceID)
    ///
    /// This prevents burning through device activations when users simply need to
    /// refresh their session (e.g., SAML cookie expiration).
    ///
    /// - Returns: `true` if Adobe activation should be skipped, `false` otherwise.
    func shouldSkipAdobeActivation() -> Bool {
        // Only skip if we're in the credentialsStale state
        guard userAccount.authState == .credentialsStale else {
            return false
        }

        // Check if we have existing Adobe credentials
        guard let userID = userAccount.userID,
              let deviceID = userAccount.deviceID else {
            Log.info(#file, "No existing Adobe credentials - cannot skip activation")
            return false
        }

        // Verify the device is actually still authorized with Adobe
        #if FEATURE_DRM_CONNECTOR
        guard let drmAuthorizer = drmAuthorizer,
              drmAuthorizer.isUserAuthorized(userID, withDevice: deviceID) else {
            Log.info(#file, "Device not currently authorized with Adobe - cannot skip activation")
            return false
        }
        #endif

        Log.info(#file, "Stale credentials with valid Adobe authorization - will skip activation")
        return true
    }
}

private extension AccountDetails.Authentication {
    /// Map the persisted auth-method enum onto the reducer's narrower
    /// `AuthMethodType`. Returns nil for `.coppa`, `.anonymous`, `.none` —
    /// callers that gate on `isBasic || isOauth || isSaml || isOidc || isToken`
    /// will never see those.
    var asAuthMethodType: AuthMethodType? {
        switch authType {
        case .basic: return .basic
        case .oauthIntermediary: return .oauthIntermediary
        case .saml: return .saml
        case .oidc: return .oidc
        case .token: return .token
        case .coppa, .anonymous, .none: return nil
        }
    }
}

//
//  TokenRefreshInterceptor.swift
//  Palace
//
//  Extracted from MyBooksDownloadCenter to isolate auth token refresh
//  and 401 re-authentication logic into a focused, single-responsibility type.
//

import AuthenticationServices
import Foundation
import PalaceAuth
import PalaceLogging
import PalaceCatalog

// MARK: - TokenRefreshInterceptorDelegate

/// Callback interface for the interceptor to delegate domain actions
/// back to the download center facade.
protocol TokenRefreshInterceptorDelegate: AnyObject {
    var bookRegistry: TPPBookRegistryProvider { get }
    var userAccount: TPPUserAccount { get }
    var stateManager: DownloadStateManager { get }
    var progressReporter: DownloadProgressReporter { get }

    func startDownload(for book: TPPBook, withRequest request: URLRequest?)
    func startBorrow(for book: TPPBook, attemptDownload: Bool, borrowCompletion: (() -> Void)?)
    func failDownloadWithAlert(for book: TPPBook, withMessage message: String?)
    func alertForProblemDocument(_ problemDoc: TPPProblemDocument?, error: Error?, book: TPPBook)
}

// MARK: - TokenRefreshInterceptor

/// Handles 401 detection, token refresh, SAML re-authentication,
/// and request retry after credential refresh.
final class TokenRefreshInterceptor {

    // MARK: - Properties

    weak var delegate: TokenRefreshInterceptorDelegate?

    @MainActor private var hasAttemptedAuthentication = false
    @MainActor private var isRequestingCredentials = false

    var reauthenticator: Reauthenticator
    private let userRetryTracker: UserRetryTracker

    /// swarm_66819d80 Module C: auth-refresh coordinator. When non-nil,
    /// the SAML-reauth + generic-browser-reauth dispatch sites inside
    /// `handleDownloadFailureWithAuthCheck` and `handleProblem` route
    /// through the coordinator's single seam instead of carrying
    /// per-call-site SAML vs OIDC vs generic branching.
    ///
    /// **OIDC silent-reauth decision (Option A from the contract):** the
    /// coordinator does NOT drive `ASWebAuthenticationSession.start()`
    /// directly — that's an in-app system browser session, while the
    /// coordinator presents the standard sign-in modal. To preserve the
    /// silent-OIDC dance (which can succeed without user interaction
    /// when the IdP session is still live), the OIDC branch keeps the
    /// existing `triggerOIDCReauth` path AS-IS for the SUCCESS case.
    /// Only the OIDC FAILURE fallback inside `triggerOIDCReauth` could
    /// route through the coordinator, but the existing fallback already
    /// hops back to `triggerBrowserReauth` which then routes through
    /// the coordinator on the second pass — so no extra wiring is
    /// needed at this layer for OIDC.
    ///
    /// Per-book download state-machine transitions (`.SAMLStarted`,
    /// `.downloadNeeded`) and the `startDownload` retry stay at the call
    /// site — the coordinator only owns credentials refresh.
    private let authCoordinator: AuthCoordinator?

    // MARK: - Init

    init(reauthenticator: Reauthenticator = TPPReauthenticator(),
         userRetryTracker: UserRetryTracker = .shared,
         authCoordinator: AuthCoordinator? = nil) {
        self.reauthenticator = reauthenticator
        self.userRetryTracker = userRetryTracker
        self.authCoordinator = authCoordinator
    }

    // MARK: - Download Failure with Auth Check

    /// Handles a download failure that may require re-authentication.
    /// Called from the download completion handler when `failureRequiringAlert` is true.
    ///
    /// - Returns: `true` if re-auth was triggered (caller should not show additional alerts)
    @MainActor
    func handleDownloadFailureWithAuthCheck(
        for book: TPPBook,
        task: URLSessionTask,
        problemDoc: TPPProblemDocument?,
        failureError: Error?
    ) -> Bool {
        guard let delegate = delegate else { return false }
        let userAccount = delegate.userAccount

        let hasCredentials = userAccount.hasCredentials()
        let loginRequired = userAccount.authDefinition?.needsAuth ?? false

        let originalURL = task.originalRequest?.url
        let httpResponse = task.response as? HTTPURLResponse

        // Check if response indicates authentication needs refresh
        let reauthStrategy = userAccount.authDefinition?.reauthStrategy ?? .none

        if httpResponse?.indicatesAuthenticationNeedsRefresh(with: problemDoc, originalRequestURL: originalURL) == true {
            if hasCredentials {
                userAccount.markCredentialsStale()

                switch reauthStrategy {
                case .browser:
                    // swarm_66819d80 Module C: route SAML + generic
                    // browser through the coordinator (modal-routing for
                    // browser-mechanism). OIDC keeps its silent
                    // ASWebAuthenticationSession dance as-is per Option A
                    // — the coordinator can't drive that surface.
                    if userAccount.authDefinition?.isOidc == true {
                        Log.info(#file, "OIDC session expired - attempting silent re-auth via ASWebAuthenticationSession")
                        triggerOIDCReauth(for: book, task: task)
                        return true
                    }
                    if let coordinator = self.authCoordinator {
                        let isSaml = userAccount.authDefinition?.isSaml == true
                        Log.info(#file, "Browser session expired - dispatching through AuthCoordinator (isSaml=\(isSaml))")
                        triggerCoordinatorReauth(
                            for: book,
                            task: task,
                            coordinator: coordinator,
                            reason: isSaml ? .samlSessionExpired : .invalidCredentials,
                            stateOnSuccess: isSaml ? .SAMLStarted : .downloadNeeded
                        )
                        return true
                    }
                    if userAccount.authDefinition?.isSaml == true {
                        Log.info(#file, "SAML session expired - triggering SAML re-auth flow (legacy path)")
                        triggerSAMLReauth(for: book, task: task)
                    } else {
                        Log.info(#file, "Browser-based auth expired - triggering re-auth via sign-in modal (legacy path)")
                        triggerBrowserReauth(for: book, task: task)
                    }
                    return true
                case .tokenRefresh:
                    // Token refresh was already attempted by TPPNetworkResponder
                    Log.warn(#file, "Token refresh failed for \(book.identifier) - showing error")
                case .credentialPrompt, .none:
                    Log.warn(#file, "Auth failed for \(book.identifier) - showing error")
                }
            } else if loginRequired {
                Log.info(#file, "No credentials - showing sign-in modal")
                triggerSignIn(for: book)
                return true
            }
        } else if !hasCredentials && loginRequired {
            Log.info(#file, "No credentials - showing sign-in modal")
            triggerSignIn(for: book)
            return true
        }

        // Check for "no active loan" with browser-based auth treat as session expiry
        // Browser-based auth (SAML/OIDC) can cause the server to return "no-active-loan"
        // instead of 401 when the session expires.
        if let problemDoc = problemDoc, problemDoc.type == TPPProblemDocument.TypeNoActiveLoan {
            if reauthStrategy == .browser && hasCredentials {
                userAccount.markCredentialsStale()
                // swarm_66819d80 Module C: same coordinator routing as
                // the 401 branch above. OIDC stays on its own silent path.
                if userAccount.authDefinition?.isOidc == true {
                    Log.info(#file, "OIDC: 'no-active-loan' treating as session expiry")
                    triggerOIDCReauth(for: book, task: task)
                    return true
                }
                if let coordinator = self.authCoordinator {
                    let isSaml = userAccount.authDefinition?.isSaml == true
                    Log.info(#file, "no-active-loan as session expiry — dispatching through AuthCoordinator (isSaml=\(isSaml))")
                    triggerCoordinatorReauth(
                        for: book,
                        task: task,
                        coordinator: coordinator,
                        reason: isSaml ? .samlSessionExpired : .invalidCredentials,
                        stateOnSuccess: isSaml ? .SAMLStarted : .downloadNeeded
                    )
                    return true
                }
                if userAccount.authDefinition?.isSaml == true {
                    Log.info(#file, "SAML: 'no-active-loan' treating as session expiry (PP-3716, legacy path)")
                    triggerSAMLReauth(for: book, task: task)
                } else {
                    Log.info(#file, "Browser auth: 'no-active-loan' treating as session expiry (legacy path)")
                    triggerBrowserReauth(for: book, task: task)
                }
                return true
            }

            // Non-browser-based auth: attempt auto-borrow
            Log.info(#file, "Download failed: No active loan for \(book.identifier). Auto-borrowing...")
            delegate.bookRegistry.setState(.unregistered, for: book.identifier)
            delegate.startBorrow(for: book, attemptDownload: true) { [weak delegate] in
                guard let delegate = delegate else { return }
                let newState = delegate.bookRegistry.state(for: book.identifier)
                Log.debug(#file, "Auto-borrow after 'no active loan' completed, new state: \(newState)")
                if newState != .downloading && newState != .downloadSuccessful {
                    Log.warn(#file, "Auto-borrow failed for \(book.identifier), showing error to user")
                    delegate.alertForProblemDocument(problemDoc, error: failureError, book: book)
                } else {
                    Log.info(#file, "Auto-borrow successful for \(book.identifier), download started")
                }
            }
            return true
        }

        return false
    }

    // MARK: - Borrow Error Credential Handling

    /// Handles invalid credentials error during borrow.
    func handleBorrowInvalidCredentials(for book: TPPBook, error: [String: Any]?) {
        Task { @MainActor [weak self] in
            guard let self = self, let delegate = self.delegate else { return }

            guard !self.hasAttemptedAuthentication else {
                self.showBorrowAlert(for: book, with: error)
                return
            }

            guard !self.isRequestingCredentials else {
                NSLog("Already requesting credentials, skipping re-authentication for: \(book.title)")
                return
            }

            self.hasAttemptedAuthentication = true
            self.isRequestingCredentials = true

            self.reauthenticator.authenticateIfNeeded(delegate.userAccount, usingExistingCredentials: false) { [weak self, weak delegate] in
                guard let self = self, let delegate = delegate else { return }

                Task { @MainActor [weak self] in
                    self?.isRequestingCredentials = false

                    if delegate.userAccount.hasCredentials() == true {
                        delegate.startDownload(for: book, withRequest: nil)
                    } else {
                        NSLog("Authentication completed but no credentials present, user may have cancelled")
                    }
                }
            }
        }
    }

    // MARK: - Credential Request for Download

    /// Requests credentials and starts download after successful sign-in.
    @MainActor
    func requestCredentialsAndStartDownload(
        for book: TPPBook,
        downloadCoordinator: DownloadCoordinator
    ) {
        guard let delegate = delegate else { return }

        guard !self.isRequestingCredentials else {
            NSLog("Already requesting credentials, skipping duplicate request for: \(book.title)")
            return
        }

        self.isRequestingCredentials = true

        #if FEATURE_DRM_CONNECTOR
        if AdobeCertificate.defaultCertificate?.hasExpired ?? false {
            self.isRequestingCredentials = false
            TPPAlertUtils.presentFromViewControllerOrNil(alertController: TPPAlertUtils.expiredAdobeDRMAlert(), viewController: nil, animated: true, completion: nil)
            return
        }
        #endif

        // swarm_d8f11437 Module A wave 4 — migrated to AppContainer-
        // injected sheet presenter. Single-flight `isRequestingCredentials`
        // dedupe at line 265 still owns the concurrent-401 guard.
        AppContainer.production().signInModalSheetPresenter
            .presentSignInModalForCurrentAccount { [weak self, weak delegate] in
            guard let self = self, let delegate = delegate else { return }

            Task { @MainActor [weak self, weak delegate] in
                guard let self = self, let delegate = delegate else { return }
                self.isRequestingCredentials = false

                if delegate.userAccount.hasCredentials() == true {
                    delegate.startDownload(for: book, withRequest: nil)
                } else {
                    Log.info(#file, "Sign-in cancelled or failed for '\(book.title)' - cleaning up download state")
                    await downloadCoordinator.registerCompletion(identifier: book.identifier)
                }
            }
        }
    }

    // MARK: - Problem Document Handling

    /// Handles problem documents from SAML/cookie-based auth flows.
    func handleProblem(for book: TPPBook, problemDocument: TPPProblemDocument?) {
        guard let delegate = delegate else { return }
        let userAccount = delegate.userAccount
        let bookRegistry = delegate.bookRegistry
        let authDef = userAccount.authDefinition
        let hasCredentials = userAccount.hasCredentials()
        let currentState = bookRegistry.state(for: book.identifier)

        // CIRCUIT BREAKER: If already in .SAMLStarted, SAML web view failed
        if currentState == .SAMLStarted {
            Log.warn(#file, "SAML re-auth already attempted for '\(book.title)' - showing sign-in modal")

            Task { @MainActor [weak self] in
                guard let self = self, let delegate = self.delegate else { return }

                await delegate.stateManager.bookIdentifierToDownloadInfo.remove(book.identifier)
                await delegate.stateManager.downloadCoordinator.registerCompletion(identifier: book.identifier)

                bookRegistry.setState(.downloadFailed, for: book.identifier)

                if let problemDoc = problemDocument {
                    let alert = TPPAlertUtils.alert(
                        title: problemDoc.title ?? Strings.Error.sessionExpiredTitle,
                        message: problemDoc.detail ?? Strings.Error.sessionExpiredMessage
                    )
                    TPPPresentationUtils.safelyPresent(alert)
                }

                guard !self.isRequestingCredentials else { return }

                self.isRequestingCredentials = true

                self.reauthenticator.authenticateIfNeeded(userAccount, usingExistingCredentials: false) { [weak self, weak delegate] in
                    Task { @MainActor in
                        self?.isRequestingCredentials = false
                        if delegate?.userAccount.hasCredentials() == true {
                            Log.info(#file, "Sign-in completed, retrying download")
                            delegate?.startDownload(for: book, withRequest: nil)
                        }
                    }
                }
            }
            return
        }

        // For browser-based auth (SAML/OIDC) with expired session, trigger re-auth
        if authDef?.reauthStrategy == .browser && hasCredentials {
            // swarm_66819d80 Module C: route SAML cookie-expiry + generic
            // browser-expiry through the coordinator. OIDC stays out of
            // scope here (the handleProblem flow doesn't dispatch OIDC
            // separately like handleDownloadFailureWithAuthCheck does;
            // OIDC inherits the SAML branch behavior pre-Module-C).
            if let coordinator = self.authCoordinator {
                let isSaml = authDef?.isSaml == true
                Log.info(#file, "handleProblem: browser-based reauth dispatched through AuthCoordinator (isSaml=\(isSaml))")
                Task { [weak self, weak delegate] in
                    guard let delegate = delegate else { return }
                    await delegate.stateManager.bookIdentifierToDownloadInfo.remove(book.identifier)
                    await delegate.stateManager.downloadCoordinator.registerCompletion(identifier: book.identifier)

                    let outcome = await coordinator.refreshCredentialsIfNeeded(
                        reason: isSaml ? .samlSessionExpired : .invalidCredentials
                    )

                    await MainActor.run {
                        if isSaml {
                            bookRegistry.setState(.SAMLStarted, for: book.identifier)
                        } else {
                            bookRegistry.setState(.downloadNeeded, for: book.identifier)
                        }
                        switch outcome {
                        case .success:
                            Log.info(#file, "handleProblem coordinator success — retrying download for \(book.identifier)")
                            delegate.startDownload(for: book, withRequest: nil)
                        case .failure(let cancellation):
                            Log.info(#file, "handleProblem coordinator declined refresh for \(book.identifier) — \(cancellation)")
                        }
                        _ = self // retain to make warnings about unused capture happy
                    }
                }
                return
            }
            if authDef?.isSaml == true {
                Log.info(#file, "SAML cookies expired - triggering SAML re-auth flow (legacy path)")

                Task { [weak delegate] in
                    guard let delegate = delegate else { return }
                    await delegate.stateManager.bookIdentifierToDownloadInfo.remove(book.identifier)
                    await delegate.stateManager.downloadCoordinator.registerCompletion(identifier: book.identifier)

                    await MainActor.run {
                        bookRegistry.setState(.SAMLStarted, for: book.identifier)
                        Log.info(#file, "Cleared download state, retrying with SAML re-auth")
                        delegate.startDownload(for: book, withRequest: nil)
                    }
                }
            } else {
                Log.info(#file, "Browser-based auth expired - triggering re-auth via sign-in modal (legacy path)")
                userAccount.markCredentialsStale()
                bookRegistry.setState(.downloadNeeded, for: book.identifier)

                Task { @MainActor [weak self] in
                    guard let self = self, let delegate = self.delegate else { return }

                    guard !self.isRequestingCredentials else { return }
                    self.isRequestingCredentials = true

                    self.reauthenticator.authenticateIfNeeded(userAccount, usingExistingCredentials: false) { [weak self, weak delegate] in
                        Task { @MainActor [weak self] in
                            self?.isRequestingCredentials = false
                            if delegate?.userAccount.authState == .loggedIn {
                                Log.info(#file, "Browser re-auth completed, retrying download")
                                delegate?.startDownload(for: book, withRequest: nil)
                            }
                        }
                    }
                }
            }
            return
        }

        // For non-browser-based auth or no credentials, set to downloadNeeded
        bookRegistry.setState(.downloadNeeded, for: book.identifier)

        if !hasCredentials {
            Task { @MainActor [weak self] in
                guard let self = self, let delegate = self.delegate else { return }

                guard !self.isRequestingCredentials else {
                    NSLog("Already requesting credentials, skipping re-authentication in handleProblem for: \(book.title)")
                    return
                }

                self.isRequestingCredentials = true

                self.reauthenticator.authenticateIfNeeded(userAccount, usingExistingCredentials: false) { [weak self, weak delegate] in
                    Task { @MainActor [weak self] in
                        self?.isRequestingCredentials = false

                        if delegate?.userAccount.hasCredentials() == true {
                            delegate?.startDownload(for: book, withRequest: nil)
                        } else {
                            NSLog("Authentication completed but no credentials present, user may have cancelled")
                        }
                    }
                }
            }
        } else {
            Log.warn(#file, "Download failed for authenticated user: \(book.identifier)")
        }
    }

    // MARK: - Private Helpers

    /// swarm_66819d80 Module C: coordinator-routed reauth dispatch.
    /// Cleans up the per-book download tracking state, asks the
    /// coordinator to refresh credentials (the coordinator decides
    /// silent vs modal per IdP), then flips the per-book state and
    /// fires the retry download on success.
    private func triggerCoordinatorReauth(
        for book: TPPBook,
        task: URLSessionTask,
        coordinator: AuthCoordinator,
        reason: ReauthReason,
        stateOnSuccess: TPPBookState
    ) {
        guard let delegate = delegate else { return }
        let stateManager = delegate.stateManager

        Task { [weak self, weak delegate] in
            await stateManager.bookIdentifierToDownloadInfo.remove(book.identifier)
            await stateManager.taskIdentifierToBook.remove(task.taskIdentifier)
            await stateManager.downloadCoordinator.registerCompletion(identifier: book.identifier)

            let outcome = await coordinator.refreshCredentialsIfNeeded(reason: reason)

            await MainActor.run {
                guard let delegate = delegate else { return }
                delegate.bookRegistry.setState(stateOnSuccess, for: book.identifier)
                switch outcome {
                case .success:
                    Log.info(#file, "Coordinator refresh succeeded — retrying download for \(book.identifier)")
                    delegate.startDownload(for: book, withRequest: nil)
                case .failure(let cancellation):
                    Log.info(#file, "Coordinator declined refresh for \(book.identifier) — \(cancellation)")
                }
                _ = self // retain to silence unused-capture-of-self
            }
        }
    }

    private func triggerSAMLReauth(for book: TPPBook, task: URLSessionTask) {
        guard let delegate = delegate else { return }
        let stateManager = delegate.stateManager

        Task {
            await stateManager.bookIdentifierToDownloadInfo.remove(book.identifier)
            await stateManager.taskIdentifierToBook.remove(task.taskIdentifier)
            await stateManager.downloadCoordinator.registerCompletion(identifier: book.identifier)

            await MainActor.run {
                delegate.bookRegistry.setState(.SAMLStarted, for: book.identifier)
                Log.info(#file, "Cleared failed download, now retrying with SAML re-auth")
                delegate.startDownload(for: book, withRequest: nil)
            }
        }
    }

    private func triggerSignIn(for book: TPPBook) {
        guard let delegate = delegate else { return }

        reauthenticator.authenticateIfNeeded(
            delegate.userAccount,
            usingExistingCredentials: false,
            authenticationCompletion: { [weak delegate] in
                Task { @MainActor [weak delegate] in
                    guard let delegate = delegate else { return }
                    guard delegate.userAccount.hasCredentials() else {
                        Log.info(#file, "Authentication cancelled, not retrying download for \(book.identifier)")
                        return
                    }
                    Log.info(#file, "Authentication completed, retrying download for \(book.identifier)")
                    delegate.startDownload(for: book, withRequest: nil)
                }
            }
        )
    }

    /// Triggers browser-based re-auth (OIDC, etc.) with proper download state cleanup.
    /// Unlike SAML which uses a special `.SAMLStarted` book state, browser re-auth
    /// cleans up tracking, resets book state, and presents the sign-in modal.
    private func triggerBrowserReauth(for book: TPPBook, task: URLSessionTask) {
        guard let delegate = delegate else { return }
        let stateManager = delegate.stateManager

        Task {
            await stateManager.bookIdentifierToDownloadInfo.remove(book.identifier)
            await stateManager.taskIdentifierToBook.remove(task.taskIdentifier)
            await stateManager.downloadCoordinator.registerCompletion(identifier: book.identifier)

            await MainActor.run { [weak self, weak delegate] in
                guard let self = self, let delegate = delegate else { return }
                delegate.bookRegistry.setState(.downloadNeeded, for: book.identifier)
                Log.info(#file, "Cleared failed download state, presenting sign-in modal for \(book.identifier)")

                self.reauthenticator.authenticateIfNeeded(
                    delegate.userAccount,
                    usingExistingCredentials: false,
                    authenticationCompletion: { [weak delegate] in
                        Task { @MainActor [weak delegate] in
                            guard let delegate = delegate else { return }
                            // Check authState, not just hasCredentials — stale creds still
                            // return true for hasCredentials() but won't work for downloads
                            guard delegate.userAccount.authState == .loggedIn else {
                                Log.info(#file, "Re-auth cancelled or incomplete, not retrying download for \(book.identifier)")
                                return
                            }
                            Log.info(#file, "Re-auth completed, retrying download for \(book.identifier)")
                            delegate.startDownload(for: book, withRequest: nil)
                        }
                    }
                )
            }
        }
    }

    /// Attempts silent OIDC re-authentication using `ASWebAuthenticationSession`.
    /// Since `prefersEphemeralWebBrowserSession` is false, the session reuses the
    /// system browser's existing IdP cookies. If the user's IdP session is still
    /// alive, the re-auth completes seamlessly without user interaction (the system
    /// sheet appears briefly and auto-dismisses). Only falls back to the full
    /// sign-in modal if the silent attempt fails or is cancelled.
    @MainActor
    private func triggerOIDCReauth(for book: TPPBook, task: URLSessionTask) {
        guard let delegate = delegate else { return }
        let stateManager = delegate.stateManager
        let userAccount = delegate.userAccount

        guard let authDef = userAccount.authDefinition,
              let oidcURL = authDef.oidcAuthenticationUrl else {
            Log.warn(#file, "OIDC reauth: no authenticate URL — falling back to sign-in modal")
            triggerBrowserReauth(for: book, task: task)
            return
        }

        // Build the OIDC URL with redirect_uri
        let callbackScheme = TPPSignInBusinessLogic.oidcCallbackScheme
        let callbackHost = TPPSignInBusinessLogic.oidcCallbackHost
        let redirectURI = "\(callbackScheme)://\(callbackHost)/callback"

        guard var urlComponents = URLComponents(url: oidcURL, resolvingAgainstBaseURL: true) else {
            Log.warn(#file, "OIDC reauth: malformed authenticate URL — falling back to sign-in modal")
            triggerBrowserReauth(for: book, task: task)
            return
        }

        let redirectParam = URLQueryItem(name: "redirect_uri", value: redirectURI)
        if urlComponents.queryItems != nil {
            urlComponents.queryItems?.append(redirectParam)
        } else {
            urlComponents.queryItems = [redirectParam]
        }

        guard let finalURL = urlComponents.url else {
            triggerBrowserReauth(for: book, task: task)
            return
        }

        Log.info(#file, "OIDC reauth: starting ASWebAuthenticationSession for \(book.identifier)")

        let session = ASWebAuthenticationSession(
            url: finalURL,
            callbackURLScheme: callbackScheme
        ) { [weak self, weak delegate] callbackURL, error in
            Task { @MainActor [weak self, weak delegate] in
                guard let self = self, let delegate = delegate else { return }

                if let error = error as? ASWebAuthenticationSessionError,
                   error.code == .canceledLogin {
                    Log.info(#file, "OIDC silent reauth cancelled by user — falling back to sign-in modal")
                    self.triggerBrowserReauth(for: book, task: task)
                    return
                }

                if let error = error {
                    Log.warn(#file, "OIDC silent reauth failed: \(error.localizedDescription) — falling back to sign-in modal")
                    self.triggerBrowserReauth(for: book, task: task)
                    return
                }

                guard let callbackURL = callbackURL,
                      let payload = callbackURL.query ?? callbackURL.fragment else {
                    Log.warn(#file, "OIDC silent reauth: no callback data — falling back to sign-in modal")
                    self.triggerBrowserReauth(for: book, task: task)
                    return
                }

                // Parse access_token from callback
                var kvpairs = [String: String]()
                for param in payload.components(separatedBy: "&") {
                    let elts = param.components(separatedBy: "=")
                    guard elts.count >= 2, let key = elts.first else { continue }
                    kvpairs[key] = elts.dropFirst().joined(separator: "=")
                }

                guard let accessToken = kvpairs["access_token"] else {
                    Log.warn(#file, "OIDC silent reauth: no access_token in callback — falling back to sign-in modal")
                    self.triggerBrowserReauth(for: book, task: task)
                    return
                }

                // Update the stored auth token, preserving existing barcode/pin
                Log.info(#file, "OIDC silent reauth succeeded — updating token and retrying download for \(book.identifier)")
                let ua = delegate.userAccount
                ua.setAuthToken(accessToken, barcode: ua.barcode, pin: ua.PIN, expirationDate: nil)

                // Clean up failed download state and retry
                await stateManager.bookIdentifierToDownloadInfo.remove(book.identifier)
                await stateManager.taskIdentifierToBook.remove(task.taskIdentifier)
                await stateManager.downloadCoordinator.registerCompletion(identifier: book.identifier)
                delegate.bookRegistry.setState(.downloadNeeded, for: book.identifier)
                delegate.startDownload(for: book, withRequest: nil)
            }
        }

        // Present the session — uses existing system browser cookies for silent SSO,
        // EXCEPT when the patron just ran "Reset Account"
        // which sets a one-shot flag forcing ephemeral cookies for this single
        // session. Flag self-clears on consumption.
        session.presentationContextProvider = OIDCPresentationContextProvider.shared
        session.prefersEphemeralWebBrowserSession =
            TPPSignInBusinessLogic.consumeNextOIDCSessionEphemeralFlag()
        session.start()
    }

    private func showBorrowAlert(for book: TPPBook, with error: [String: Any]?) {
        guard let delegate = delegate else { return }
        let alertTitle = Strings.MyDownloadCenter.borrowFailed
        var alertMessage = String(format: Strings.MyDownloadCenter.borrowFailedMessage, book.title)

        if let error = error {
            let problemDoc = TPPProblemDocument.fromDictionary(error)
            if let detail = problemDoc.detail {
                alertMessage = "\(alertMessage)\n\n\(detail)"
            }
        }

        let retryAction: (() -> Void)? = {
            let operationId = "borrow-\(book.identifier)"
            guard userRetryTracker.canRetry(operationId: operationId) else { return nil }
            return { [weak delegate] in
                self.userRetryTracker.recordRetry(operationId: operationId)
                delegate?.startBorrow(for: book, attemptDownload: true, borrowCompletion: nil)
            }
        }()

        runOnMainAsync {
            delegate.progressReporter.publishAndAnnounceError(
                DownloadErrorInfo(bookId: book.identifier, title: alertTitle, message: alertMessage, retryAction: retryAction)
            )
        }
    }
}

// MARK: - OIDC Presentation Context

/// Provides a window anchor for `ASWebAuthenticationSession` when triggered
/// from the network/download layer (which has no UI context of its own).
private final class OIDCPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = OIDCPresentationContextProvider()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.mainKeyWindow ?? ASPresentationAnchor()
    }
}

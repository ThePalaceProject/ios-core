//
//  TokenRefreshInterceptor.swift
//  Palace
//
//  Extracted from MyBooksDownloadCenter to isolate auth token refresh
//  and 401 re-authentication logic into a focused, single-responsibility type.
//

import Foundation

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

    // MARK: - Init

    init(reauthenticator: Reauthenticator = TPPReauthenticator(),
         userRetryTracker: UserRetryTracker = .shared) {
        self.reauthenticator = reauthenticator
        self.userRetryTracker = userRetryTracker
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
        if httpResponse?.indicatesAuthenticationNeedsRefresh(with: problemDoc, originalRequestURL: originalURL) == true {
            let authDef = userAccount.authDefinition

            if hasCredentials {
                userAccount.markCredentialsStale()

                if authDef?.isSaml == true {
                    Log.info(#file, "SAML session expired - marking credentials stale and triggering re-auth flow")
                    triggerSAMLReauth(for: book, task: task)
                    return true
                } else {
                    Log.warn(#file, "Token refresh failed for \(book.identifier) - showing error")
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

        // Check for "no active loan" with SAML - treat as session expiry (PP-3716)
        if let problemDoc = problemDoc, problemDoc.type == TPPProblemDocument.TypeNoActiveLoan {
            let authDef = userAccount.authDefinition
            if authDef?.isSaml == true && hasCredentials {
                Log.info(#file, "SAML: 'no-active-loan' with active SAML credentials - treating as session expiry (PP-3716)")
                userAccount.markCredentialsStale()
                triggerSAMLReauth(for: book, task: task)
                return true
            }

            // Non-SAML: attempt auto-borrow
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

            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.isRequestingCredentials = false
            }

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

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.isRequestingCredentials = false
        }

        #if FEATURE_DRM_CONNECTOR
        if AdobeCertificate.defaultCertificate?.hasExpired ?? false {
            self.isRequestingCredentials = false
            TPPAlertUtils.presentFromViewControllerOrNil(alertController: TPPAlertUtils.expiredAdobeDRMAlert(), viewController: nil, animated: true, completion: nil)
            return
        }
        #endif

        SignInModalPresenter.presentSignInModalForCurrentAccount { [weak self, weak delegate] in
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
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    self?.isRequestingCredentials = false
                }

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

        // For SAML with expired cookies, try SAML flow once
        if authDef?.isSaml == true && hasCredentials {
            Log.info(#file, "SAML cookies expired - triggering SAML re-auth flow")

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
            return
        }

        // For non-SAML or no credentials, set to downloadNeeded
        bookRegistry.setState(.downloadNeeded, for: book.identifier)

        if !hasCredentials {
            Task { @MainActor [weak self] in
                guard let self = self, let delegate = self.delegate else { return }

                guard !self.isRequestingCredentials else {
                    NSLog("Already requesting credentials, skipping re-authentication in handleProblem for: \(book.title)")
                    return
                }

                self.isRequestingCredentials = true

                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    self?.isRequestingCredentials = false
                }

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

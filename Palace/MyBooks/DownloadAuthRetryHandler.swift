//
//  DownloadAuthRetryHandler.swift
//  Palace
//
//  Owns the failure-path auth/retry orchestration that lived inside
//  MyBooksDownloadCenter.handleDownloadCompletion (~200 LOC of nested
//  if/else handling 401-style session expiries, no-active-loan re-borrow,
//  and SAML / OIDC / token-refresh re-auth flows).
//
//  Extracted so the retry policy can be reasoned about in one place
//  instead of being tangled inside the URLSession completion callback.
//  Returns `true` from `handleAuthFailureIfApplicable` when the failure
//  has been claimed (state cleanup queued + appropriate sign-in/borrow
//  retry kicked off); the caller then skips the default error alert.
//  Returns `false` for non-auth/non-loan failures so the caller can fall
//  through to the regular alert path.
//
//  All public entry points are @MainActor because the prior MBDC code
//  ran the whole block inside `runOnMainAsync` — preserves the
//  sequencing.
//

import Foundation
import PalaceCatalog
import PalaceLogging

// MARK: - DownloadAuthRetryHandlerDelegate

/// Surface MBDC needs to expose so the handler can re-attempt the
/// download after a successful re-auth, or trigger an auto-borrow
/// after a stale `no-active-loan` failure.
protocol DownloadAuthRetryHandlerDelegate: AnyObject {
    func startDownload(for book: TPPBook, withRequest request: URLRequest?)
    func startBorrow(for book: TPPBook, attemptDownload: Bool, borrowCompletion: (() -> Void)?)
}

// MARK: - DownloadAuthRetryHandler

/// Decides whether a download-completion failure should trigger
/// re-authentication, an auto-borrow, or be passed back to the caller
/// as a regular alert. Holds no state of its own — every decision is a
/// fresh read of the current TPPUserAccount.
final class DownloadAuthRetryHandler {

    weak var delegate: DownloadAuthRetryHandlerDelegate?

    private let stateManager: DownloadStateManager
    private let bookRegistry: TPPBookRegistryProvider
    private let reauthenticator: Reauthenticator
    private let alertPresenter: DownloadAlertPresenter

    /// Closure resolves the current user account each call. MBDC's
    /// `userAccount` property is a computed property over `accountsManager.
    /// currentUserAccount`, so the closure preserves the same just-in-time
    /// resolution semantics — survives library switches mid-flow.
    private let userAccountProvider: () -> TPPUserAccount

    init(
        stateManager: DownloadStateManager,
        bookRegistry: TPPBookRegistryProvider,
        reauthenticator: Reauthenticator,
        alertPresenter: DownloadAlertPresenter,
        userAccountProvider: @escaping () -> TPPUserAccount
    ) {
        self.stateManager = stateManager
        self.bookRegistry = bookRegistry
        self.reauthenticator = reauthenticator
        self.alertPresenter = alertPresenter
        self.userAccountProvider = userAccountProvider
    }

    // MARK: - Entry point

    /// Inspects the failed task + problem document and runs the
    /// appropriate retry workflow if applicable. Returns `true` if the
    /// failure was claimed (caller should NOT show its default alert);
    /// `false` if the caller should fall through to its alert path.
    @MainActor
    func handleAuthFailureIfApplicable(
        book: TPPBook,
        task: URLSessionTask,
        problemDoc: TPPProblemDocument?,
        failureError: Error?
    ) -> Bool {
        let userAccount = userAccountProvider()
        let hasCredentials = userAccount.hasCredentials()
        let loginRequired = userAccount.authDefinition?.needsAuth ?? false

        // A 401 from a third-party domain (e.g., biblioboard.com) should NOT
        // trigger re-authentication since our Palace credentials are not the issue
        let originalURL = task.originalRequest?.url
        let httpResponse = task.response as? HTTPURLResponse
        let reauthStrategy = userAccount.authDefinition?.reauthStrategy ?? .none

        if httpResponse?.indicatesAuthenticationNeedsRefresh(with: problemDoc, originalRequestURL: originalURL) == true {
            // If user has credentials but got 401, this is a session/token expiry issue
            if hasCredentials {
                // Mark credentials as stale - preserves Adobe DRM activation
                userAccount.markCredentialsStale()

                switch reauthStrategy {
                case .browser:
                    handleBrowserSessionExpired(book: book, task: task, isSaml: userAccount.authDefinition?.isSaml == true)
                    return true
                case .tokenRefresh:
                    // Token refresh was already attempted by TPPNetworkResponder
                    Log.warn(#file, "Token refresh failed for \(book.identifier) - showing error")
                    // fall through to no-active-loan / alert
                case .credentialPrompt, .none:
                    Log.warn(#file, "Auth failed for \(book.identifier) - showing error")
                    // fall through to no-active-loan / alert
                }
            } else if loginRequired {
                // No credentials - show sign-in
                Log.info(#file, "No credentials - showing sign-in modal")
                presentSignInModal(forRetryAfterSignIn: book)
                return true
            }
        } else if !hasCredentials && loginRequired {
            // No auth error, but no credentials - show sign-in
            Log.info(#file, "No credentials - showing sign-in modal")
            presentSignInModal(forRetryAfterSignIn: book)
            return true
        }

        // Check if the error is "No active loan" - attempt to re-borrow
        if let problemDoc = problemDoc, problemDoc.type == TPPProblemDocument.TypeNoActiveLoan {
            // When browser-based auth expires, the server may return
            // "no-active-loan" (400) instead of 401. Treat as session expiry.
            if reauthStrategy == .browser && hasCredentials {
                userAccount.markCredentialsStale()
                handleNoActiveLoanAsSessionExpiry(book: book, task: task, isSaml: userAccount.authDefinition?.isSaml == true)
                return true
            }

            triggerAutoBorrow(book: book, problemDoc: problemDoc, failureError: failureError)
            return true
        }

        return false
    }

    // MARK: - 401 / browser session expired

    /// SAML or OIDC browser-based session expired. Clean up tracking
    /// state, then either retry the download via SAML re-auth (which the
    /// app's existing SAML state machine drives) or present the sign-in
    /// modal (OIDC + retry on completion).
    @MainActor
    private func handleBrowserSessionExpired(book: TPPBook, task: URLSessionTask, isSaml: Bool) {
        if isSaml {
            // SAML cookies expired - need to re-auth via IDP
            Log.info(#file, "SAML session expired - triggering SAML re-auth flow")

            Task { [weak self] in
                guard let self else { return }
                await self.cleanupTrackingState(book: book, task: task)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.bookRegistry.setState(.SAMLStarted, for: book.identifier)
                    Log.info(#file, "Cleared failed download, now retrying with SAML re-auth")
                    self.delegate?.startDownload(for: book, withRequest: nil)
                }
            }
        } else {
            // OIDC or other browser-based auth - present sign-in modal
            Log.info(#file, "Browser-based auth expired - triggering re-auth via sign-in modal")

            Task { [weak self] in
                guard let self else { return }
                await self.cleanupTrackingState(book: book, task: task)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.bookRegistry.setState(.downloadNeeded, for: book.identifier)
                    self.reauthenticate(retryWithFreshAuthState: book)
                }
            }
        }
    }

    // MARK: - No-active-loan as session expiry

    /// same treatment as the browser-session-expired path but
    /// triggered by a `no-active-loan` problem document (which the
    /// server sometimes returns as 400 instead of 401 when the browser
    /// session has timed out).
    @MainActor
    private func handleNoActiveLoanAsSessionExpiry(book: TPPBook, task: URLSessionTask, isSaml: Bool) {
        if isSaml {
            Log.info(#file, "SAML: 'no-active-loan' treating as session expiry (PP-3716)")
            Task { [weak self] in
                guard let self else { return }
                await self.cleanupTrackingState(book: book, task: task)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.bookRegistry.setState(.SAMLStarted, for: book.identifier)
                    Log.info(#file, "SAML: Cleared failed download, retrying with SAML re-auth for \(book.identifier)")
                    self.delegate?.startDownload(for: book, withRequest: nil)
                }
            }
        } else {
            Log.info(#file, "Browser auth: 'no-active-loan' treating as session expiry")
            Task { [weak self] in
                guard let self else { return }
                await self.cleanupTrackingState(book: book, task: task)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.bookRegistry.setState(.downloadNeeded, for: book.identifier)
                    self.reauthenticate(retryWithFreshAuthState: book)
                }
            }
        }
    }

    // MARK: - No-active-loan auto-borrow

    /// Real `no-active-loan` (not session-expiry) — the user's loan
    /// genuinely lapsed. Try to re-borrow; if the borrow succeeds and a
    /// download starts, swallow the failure. If the borrow fails,
    /// surface the original alert via the shared alertPresenter.
    @MainActor
    private func triggerAutoBorrow(book: TPPBook, problemDoc: TPPProblemDocument, failureError: Error?) {
        Log.info(#file, "Download failed: No active loan for \(book.identifier). Auto-borrowing...")

        // Update state to unregistered so borrow logic will work
        bookRegistry.setState(.unregistered, for: book.identifier)

        // Try to borrow the book (which will auto-download if successful)
        delegate?.startBorrow(for: book, attemptDownload: true, borrowCompletion: { [weak self] in
            guard let self else { return }
            // If borrow completed, check if download started
            let newState = self.bookRegistry.state(for: book.identifier)
            Log.debug(#file, "Auto-borrow after 'no active loan' completed, new state: \(newState)")

            if newState != .downloading && newState != .downloadSuccessful {
                // Borrow failed or didn't result in download
                Log.warn(#file, "Auto-borrow failed for \(book.identifier), showing error to user")
                self.alertPresenter.alertForProblemDocument(problemDoc, error: failureError, book: book)
            } else {
                Log.info(#file, "Auto-borrow successful for \(book.identifier), download started")
            }
        })
    }

    // MARK: - Sign-in modal (no credentials)

    /// Present the sign-in modal and retry the download once the user
    /// successfully signs in. Bails silently if the user cancels.
    @MainActor
    private func presentSignInModal(forRetryAfterSignIn book: TPPBook) {
        let userAccount = userAccountProvider()
        reauthenticator.authenticateIfNeeded(
            userAccount,
            usingExistingCredentials: false,
            authenticationCompletion: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let userAccount = self.userAccountProvider()
                    // Only retry if user successfully authenticated; if they cancelled, bail out
                    guard userAccount.hasCredentials() else {
                        Log.info(#file, "Authentication cancelled, not retrying download for \(book.identifier)")
                        return
                    }
                    Log.info(#file, "Authentication completed, retrying download for \(book.identifier)")
                    self.delegate?.startDownload(for: book, withRequest: nil)
                }
            }
        )
    }

    /// Helper for the OIDC re-auth path inside the browser-session-
    /// expired flow. Same shape as `presentSignInModal` but checks
    /// `authState == .loggedIn` instead of `hasCredentials()` because
    /// the re-auth flow keeps stale credentials around until a fresh
    /// login lands.
    @MainActor
    private func reauthenticate(retryWithFreshAuthState book: TPPBook) {
        let userAccount = userAccountProvider()
        reauthenticator.authenticateIfNeeded(
            userAccount,
            usingExistingCredentials: false,
            authenticationCompletion: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let userAccount = self.userAccountProvider()
                    guard userAccount.authState == .loggedIn else {
                        Log.info(#file, "Re-auth cancelled or incomplete, not retrying download for \(book.identifier)")
                        return
                    }
                    Log.info(#file, "Re-auth completed, retrying download for \(book.identifier)")
                    self.delegate?.startDownload(for: book, withRequest: nil)
                }
            }
        )
    }

    // MARK: - State cleanup

    /// Clears the per-book download tracking state inside the state
    /// manager so the next retry doesn't see ghost state from the
    /// failed attempt. Called on every browser/SAML re-auth path.
    private func cleanupTrackingState(book: TPPBook, task: URLSessionTask) async {
        await stateManager.bookIdentifierToDownloadInfo.remove(book.identifier)
        await stateManager.taskIdentifierToBook.remove(task.taskIdentifier)
        await stateManager.downloadCoordinator.registerCompletion(identifier: book.identifier)
    }
}

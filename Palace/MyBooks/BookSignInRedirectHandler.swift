//
//  BookSignInRedirectHandler.swift
//  Palace
//
//  Owns the SAML web-view + cookie-sync + post-auth retry path that
//  lived inside MyBooksDownloadCenter as `handleSAMLStartedState` /
//  `handleLoginCancellation` / `handleBookFound` / `handleProblem` /
//  `clearAndSetCookies`. This is the slice of the borrow flow that
//  fires when the server redirects us to the IDP for fresh credentials
//  mid-download.
//
//  Extracted so the SAML state machine (cookie web view → loginCompletion
//  → bookFound → handleProblem branches) can be reasoned about in one
//  place. MyBooksDownloadCenter retains 1-line delegators for the two
//  call sites still inside its borrow flow (`handleSAMLStartedState`
//  from `handleSAMLStartedState`'s inner branch and `clearAndSetCookies`
//  from cookie-prep before a download starts).
//

import Foundation
import UIKit
import PalaceCatalog
import PalaceLogging
import PalaceBookModel
import PalaceBookRegistry

// MARK: - BookSignInRedirectHandlerDelegate

/// Surface MBDC needs to expose so the handler can re-attempt the
/// download after a successful re-auth, or roll back its tracking when
/// the user cancels.
protocol BookSignInRedirectHandlerDelegate: AnyObject {
    /// Cookie storage of the active URLSession. The handler reads this
    /// via the delegate so MBDC's late-initialized `session` property
    /// can resolve at call time, not at handler-init time.
    var cookieStorage: HTTPCookieStorage? { get }
    func cancelDownload(for identifier: String)
    func startDownload(for book: TPPBook, withRequest request: URLRequest?)
}

// MARK: - BookSignInRedirectHandler

/// Drives the cookie-web-view auth redirect flow (SAML + non-SAML
/// fallback). Bridges back to MBDC for the retry+cancel hooks.
///
/// - Sendable invariant: every stored dependency is a `let` bound at init
///   (`bookRegistry`, `stateManager`, `reauthenticator`, `userAccountProvider`,
///   `credentialRequestState` — the last is itself `@unchecked Sendable`).
///   The only mutable instance member is `weak var delegate`, assigned exactly
///   once during owner (`MyBooksDownloadCenter`) construction and never
///   reassigned; weak-reference reads and ARC zeroing are atomic in the Swift
///   runtime, so no explicit lock is required. `@unchecked` (rather than a
///   synthesized conformance) because `delegate`'s protocol existential and the
///   shared service types are not themselves `Sendable`; this conformance only
///   formalizes how the SAML redirect flow already executes today under Swift-5
///   mode (it hops between `Task` and `MainActor.run` closures unchanged).
final class BookSignInRedirectHandler: @unchecked Sendable {

    weak var delegate: BookSignInRedirectHandlerDelegate?

    private let bookRegistry: TPPBookRegistryProvider
    private let stateManager: DownloadStateManager
    private let reauthenticator: Reauthenticator
    private let userAccountProvider: () -> TPPUserAccount
    private let credentialRequestState: CredentialRequestState

    init(
        bookRegistry: TPPBookRegistryProvider,
        stateManager: DownloadStateManager,
        reauthenticator: Reauthenticator,
        userAccountProvider: @escaping () -> TPPUserAccount,
        credentialRequestState: CredentialRequestState
    ) {
        self.bookRegistry = bookRegistry
        self.stateManager = stateManager
        self.reauthenticator = reauthenticator
        self.userAccountProvider = userAccountProvider
        self.credentialRequestState = credentialRequestState
    }

    // MARK: - SAML web-view presentation

    /// Sets the registry to `.SAMLStarted` and opens a TPPCookiesWebView
    /// pointed at the fulfillment URL. The web view's auto-presentation
    /// path does the IDP dance; the four callbacks (login complete /
    /// cancel / book-found / problem) loop back into this handler.
    func handleSAMLStartedState(for book: TPPBook, withRequest request: URLRequest, cookies: [HTTPCookie]) {
        bookRegistry.setState(.SAMLStarted, for: book.identifier)

        runOnMainAsync { [weak self] in
            guard let self = self else { return }
            var mutableRequest = request
            mutableRequest.cachePolicy = .reloadIgnoringCacheData

            let loginCompletionHandler: (URL, [HTTPCookie]) -> Void = { [weak self] _, newCookies in
                guard let self = self else { return }

                self.userAccountProvider().setCookies(newCookies)
                Log.info(#file, "SAML login completed successfully, got \(newCookies.count) cookies")

                self.bookRegistry.setState(.downloadNeeded, for: book.identifier)

                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    // The sign-in sheet is presented via SignInWebSheetPresenter,
                    // which keeps a strong reference to the hosting VC. Dismiss
                    // through it so the keep-alive map gets cleared and the
                    // SwiftUI view tree deallocates cleanly.
                    if SignInWebSheetPresenter.isPresenting {
                        SignInWebSheetPresenter.dismissTop(animated: true) {
                            self.delegate?.startDownload(for: book, withRequest: nil)
                        }
                    } else {
                        self.delegate?.startDownload(for: book, withRequest: nil)
                    }
                }
            }

            let model = SignInWebSheetViewModel(
                cookies: cookies,
                request: mutableRequest,
                universalLinksURL: AppContainer.production().settings.universalLinksURL,
                autoPresentIfNeeded: true,
                loginCompletionHandler: loginCompletionHandler,
                loginCancelHandler: { [weak self] in
                    self?.handleLoginCancellation(for: book)
                },
                bookFoundHandler: { [weak self] request, newCookies in
                    guard let self = self else { return }
                    Log.info(#file, "SAML book found with \(newCookies.count) fresh cookies")
                    self.handleBookFound(for: book, withRequest: request, cookies: newCookies)
                },
                problemFoundHandler: { [weak self] problemDocument in
                    Log.warn(#file, "SAML web view encountered problem: \(problemDocument?.type ?? "unknown")")
                    self?.handleProblem(for: book, problemDocument: problemDocument)
                }
            )

            SignInWebSheetPresenter.presentOnTop(model: model)
            Log.info(#file, "SAML web view initialized for '\(book.title)'")
        }
    }

    // MARK: - Cancellation / book-found / problem

    func handleLoginCancellation(for book: TPPBook) {
        bookRegistry.setState(.downloadNeeded, for: book.identifier)
        delegate?.cancelDownload(for: book.identifier)
    }

    func handleBookFound(for book: TPPBook, withRequest request: URLRequest?, cookies: [HTTPCookie]) {
        userAccountProvider().setCookies(cookies)
        if let request = request {
            delegate?.startDownload(for: book, withRequest: request)
        }
    }

    func handleProblem(for book: TPPBook, problemDocument: TPPProblemDocument?) {
        let userAccount = userAccountProvider()
        let authDef = userAccount.authDefinition
        let hasCredentials = userAccount.hasCredentials()
        let currentState = bookRegistry.state(for: book.identifier)

        // CIRCUIT BREAKER: If already in .SAMLStarted, SAML web view failed - show sign-in without signing out
        if currentState == .SAMLStarted {
            Log.warn(#file, "SAML re-auth already attempted for '\(book.title)' - showing sign-in modal")

            Task { @MainActor [weak self] in
                guard let self = self else { return }
                await self.stateManager.bookIdentifierToDownloadInfo.remove(book.identifier)
                await self.stateManager.downloadCoordinator.registerCompletion(identifier: book.identifier)

                self.bookRegistry.setState(.downloadFailed, for: book.identifier)

                // Show the problem document message if available (session expired, etc.)
                if let problemDoc = problemDocument {
                    let alert = TPPAlertUtils.alert(
                        title: problemDoc.title ?? Strings.Error.sessionExpiredTitle,
                        message: problemDoc.detail ?? Strings.Error.sessionExpiredMessage
                    )
                    TPPPresentationUtils.safelyPresent(alert)
                }

                guard !self.credentialRequestState.isRequestingCredentials else { return }

                self.credentialRequestState.isRequestingCredentials = true
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    self?.credentialRequestState.isRequestingCredentials = false
                }

                // Show sign-in modal WITHOUT signing out - let user re-authenticate gracefully
                Log.info(#file, "Showing sign-in modal for session refresh")
                self.reauthenticator.authenticateIfNeeded(self.userAccountProvider(), usingExistingCredentials: false) { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.credentialRequestState.isRequestingCredentials = false
                        if self?.userAccountProvider().hasCredentials() == true {
                            Log.info(#file, "Sign-in completed, retrying download")
                            self?.delegate?.startDownload(for: book, withRequest: nil)
                        }
                    }
                }
            }
            return
        }

        // For SAML with expired cookies, try SAML flow once
        if authDef?.isSaml == true && hasCredentials {
            Log.info(#file, "SAML cookies expired - triggering SAML re-auth flow")

            Task { [weak self] in
                guard let self = self else { return }
                await self.stateManager.bookIdentifierToDownloadInfo.remove(book.identifier)
                await self.stateManager.downloadCoordinator.registerCompletion(identifier: book.identifier)

                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.bookRegistry.setState(.SAMLStarted, for: book.identifier)
                    Log.info(#file, "Cleared download state, retrying with SAML re-auth")
                    self.delegate?.startDownload(for: book, withRequest: nil)
                }
            }
            return
        }

        // For non-SAML or no credentials, set to downloadNeeded and show sign-in if needed
        bookRegistry.setState(.downloadNeeded, for: book.identifier)

        // Only show sign-in if truly no credentials
        if !hasCredentials {
            Task { @MainActor [weak self] in
                guard let self = self else { return }

                guard !self.credentialRequestState.isRequestingCredentials else {
                    NSLog("Already requesting credentials, skipping re-authentication in handleProblem for: \(book.title)")
                    return
                }

                self.credentialRequestState.isRequestingCredentials = true

                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    self?.credentialRequestState.isRequestingCredentials = false
                }

                self.reauthenticator.authenticateIfNeeded(self.userAccountProvider(), usingExistingCredentials: false) { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.credentialRequestState.isRequestingCredentials = false

                        if self?.userAccountProvider().hasCredentials() == true {
                            self?.delegate?.startDownload(for: book, withRequest: nil)
                        } else {
                            NSLog("Authentication completed but no credentials present, user may have cancelled")
                        }
                    }
                }
            }
        } else {
            // Has credentials but download failed - log for debugging
            Log.warn(#file, "Download failed for authenticated user: \(book.identifier)")
        }
    }

    // MARK: - Cookie sync

    /// Wipes the URLSession's cookie storage and replaces it with the
    /// user account's persisted cookies. Run before a download attempt
    /// so the session uses the most-recent IDP-issued cookie set rather
    /// than whatever was left over from a prior session.
    func clearAndSetCookies() {
        let cookieStorage = delegate?.cookieStorage
        cookieStorage?.cookies?.forEach { cookie in
            cookieStorage?.deleteCookie(cookie)
        }
        userAccountProvider().cookies?.forEach { cookie in
            cookieStorage?.setCookie(cookie)
        }
    }
}

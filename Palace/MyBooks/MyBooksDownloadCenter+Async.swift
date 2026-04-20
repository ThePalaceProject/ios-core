//
//  MyBooksDownloadCenter+Async.swift
//  Palace
//
//  Copyright © 2025 The Palace Project. All rights reserved.
//

import AuthenticationServices
import Foundation

/// Modern async/await extensions for MyBooksDownloadCenter
extension MyBooksDownloadCenter {

    // MARK: - Borrow Re-auth State

    /// Tracks whether we've already attempted re-authentication for a borrow operation
    /// Prevents infinite re-auth loops for persistent auth failures
    private static var borrowReauthAttempted: Set<String> = []
    private static let borrowReauthLock = NSLock()

    private static func hasBorrowReauthBeenAttempted(for bookId: String) -> Bool {
        borrowReauthLock.lock()
        defer { borrowReauthLock.unlock() }
        return borrowReauthAttempted.contains(bookId)
    }

    private static func markBorrowReauthAttempted(for bookId: String) {
        borrowReauthLock.lock()
        defer { borrowReauthLock.unlock() }
        borrowReauthAttempted.insert(bookId)
    }

    private static func clearBorrowReauthAttempted(for bookId: String) {
        borrowReauthLock.lock()
        defer { borrowReauthLock.unlock() }
        borrowReauthAttempted.remove(bookId)
    }

    /// Clears all borrow re-auth tracking state. Called on account switch
    /// to prevent stale circuit breaker state from the previous account.
    static func clearAllBorrowReauthState() {
        borrowReauthLock.lock()
        defer { borrowReauthLock.unlock() }
        borrowReauthAttempted.removeAll()
    }

    // MARK: - Async Borrow Operations

    /// Borrows a book asynchronously using modern async/await pattern
    /// - Parameters:
    ///   - book: The book to borrow
    ///   - attemptDownload: Whether to immediately attempt download after borrowing
    /// - Returns: The borrowed book with updated acquisition links
    /// - Throws: PalaceError if borrow fails
    func borrowAsync(
        _ book: TPPBook,
        attemptDownload: Bool = false
    ) async throws -> TPPBook {
        let bookIdentifier = book.identifier

        announceBorrowStarted(for: book)

        Task { await ErrorActivityTracker.shared.log("Initiating borrow for '\(book.title)'", category: .borrow) }

        if Bundle.main.applicationEnvironment != .production,
           let simulated = DebugSettings.shared.createSimulatedBorrowError() {
            await ErrorActivityTracker.shared.log(
                "Simulated borrow error triggered: \(DebugSettings.shared.simulatedBorrowError.displayName)",
                category: .borrow
            )
            await MainActor.run {
                showBorrowError(.network(.forbidden), originalError: simulated.error, for: book, problemDocument: simulated.problemDocument)
            }
            throw simulated.error
        }

        // PP-3649: If this book requires Adobe DRM, ensure the device is activated
        // before proceeding with the borrow. This is the on-demand activation that
        // replaces the previous login-time activation.
        #if FEATURE_DRM_CONNECTOR
        if book.requiresAdobeDRM {
            Task { await ErrorActivityTracker.shared.log("Book requires Adobe DRM — checking device activation", category: .borrow) }
            try await AdobeDRMService.shared.ensureDeviceActivated()
        }
        #endif

        // Use modern OPDSFeedService instead of legacy callback-based TPPOPDSFeed
        guard let acquisitionURL = book.defaultAcquisition?.hrefURL else {
            Task { await ErrorActivityTracker.shared.log("No acquisition URL found for '\(book.title)'", category: .borrow) }
            throw PalaceError.bookRegistry(.invalidState)
        }

        Task { await ErrorActivityTracker.shared.log("Requesting loan from \(acquisitionURL.host ?? acquisitionURL.absoluteString)", category: .network) }

        // Set processing state - this shows a spinner in the UI
        await MainActor.run {
            self.bookRegistry.setProcessing(true, for: bookIdentifier)
        }

        // Helper to clear processing state on all exit paths
        // Using @MainActor func instead of detached Task to ensure immediate execution
        @MainActor func clearProcessingState() {
            self.bookRegistry.setProcessing(false, for: bookIdentifier)
        }

        do {
            // Fetch the borrowed book using modern async API with automatic retries
            // Use borrowOperation policy for fast fail - shows error quickly instead of freezing
            let recovery = DownloadErrorRecovery()
            let borrowedBook = try await recovery.executeWithRetry(
                policy: DownloadErrorRecovery.RetryPolicy.borrowOperation
            ) {
                try await OPDSFeedService.shared.fetchBook(
                    from: acquisitionURL,
                    resetCache: true,
                    useToken: true
                )
            }

            // Clear processing state before updating registry
            await clearProcessingState()

            // Preserve existing location
            let location = self.bookRegistry.location(forIdentifier: borrowedBook.identifier)

            // Determine correct registry state based on availability
            var newState: TPPBookState = .downloadNeeded
            borrowedBook.defaultAcquisition?.availability.match(unavailable: 
                { _ in newState = .holding },
                limited: { _ in newState = .downloadNeeded },
                unlimited: { _ in newState = .downloadNeeded },
                reserved: { _ in newState = .holding },
                ready: { _ in newState = .downloadNeeded }
            )

            // Add to registry
            self.bookRegistry.addBook(
                borrowedBook,
                location: location,
                state: newState,
                fulfillmentId: nil as String?,
                readiumBookmarks: nil as [TPPReadiumBookmark]?,
                genericBookmarks: nil as [TPPBookLocation]?
            )

            // Emit explicit state update so SwiftUI lists refresh immediately
            self.bookRegistry.setState(newState, for: borrowedBook.identifier)

            Task { await ErrorActivityTracker.shared.log("Borrow succeeded for '\(borrowedBook.title)', state: \(newState)", category: .borrow) }

            announceBorrowSucceeded(for: borrowedBook)

            // Optionally start download
            if attemptDownload && newState == .downloadNeeded {
                await MainActor.run {
                    startDownload(for: borrowedBook)
                }
            }

            // PP-3811: The server's immediate borrow response often returns
            // holdPosition=0 for holds. The real position is only available from
            // the shelf/loans feed. Trigger a sync after a short delay so the UI
            // can update with the correct hold position.
            if newState == .holding {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    (self.bookRegistry as? TPPBookRegistry)?.sync()
                }
            }

            // Clear re-auth tracking on success
            Self.clearBorrowReauthAttempted(for: bookIdentifier)

            return borrowedBook

        } catch let error as PalaceError {
            // Clear processing state immediately on error
            await clearProcessingState()

            // Check if this is an authentication error that needs re-auth
            if await handleBorrowAuthErrorIfNeeded(error, originalError: nil, for: book, attemptDownload: attemptDownload) {
                // Re-auth was triggered, don't show error alert
                throw error
            }

            // Handle structured errors - but PalaceError doesn't carry problem document
            await MainActor.run {
                showBorrowError(error, originalError: nil, for: book)
            }
            throw error
        } catch {
            // Clear processing state immediately on error
            await clearProcessingState()

            // Extract problem document from original NSError before converting
            // The server's problem document contains the user-friendly error message
            let nsError = error as NSError
            let problemDoc = nsError.problemDocument

            let palaceError = PalaceError.from(error)

            // Check if this is an authentication error that needs re-auth
            if await handleBorrowAuthErrorIfNeeded(palaceError, originalError: error, for: book, attemptDownload: attemptDownload, problemDocument: problemDoc) {
                // Re-auth was triggered, don't show error alert
                throw palaceError
            }

            await MainActor.run {
                showBorrowError(palaceError, originalError: error, for: book, problemDocument: problemDoc)
            }
            throw palaceError
        }
    }

    /// Checks if the error indicates an authentication failure and handles re-auth if needed
    /// - Returns: `true` if re-auth was triggered (caller should not show error), `false` otherwise
    private func handleBorrowAuthErrorIfNeeded(
        _ error: PalaceError,
        originalError: Error?,
        for book: TPPBook,
        attemptDownload: Bool,
        problemDocument: TPPProblemDocument? = nil
    ) async -> Bool {
        let userAccount = self.userAccount
        let authDef = userAccount.authDefinition
        let hasCredentials = userAccount.hasCredentials()

        // Check if this is an auth-related error
        let isAuthError: Bool = {
            // Check PalaceError type
            if case .authentication = error {
                return true
            }

            // Check problem document for explicit auth error types
            if let problemDoc = problemDocument {
                // Exact match: legacy "credentials-invalid" type
                if problemDoc.type == TPPProblemDocument.TypeInvalidCredentials {
                    return true
                }

                // PP-3716: Recoverable auth errors (e.g. "auth/recoverable/saml/session-expired")
                // The server categorizes these with /auth/recoverable/ in the type URL
                if problemDoc.isRecoverableAuthError {
                    Log.info(#file, "Recoverable auth error detected: \(problemDoc.type ?? "unknown") — triggering re-auth (PP-3716)")
                    return true
                }

                // PP-3716: "no-active-loan" with SAML/OIDC credentials is likely a session
                // expiry — the server returns 400 instead of 401 in some cases
                if problemDoc.type == TPPProblemDocument.TypeNoActiveLoan,
                   (authDef?.isSaml == true || authDef?.isOidc == true),
                   hasCredentials {
                    Log.info(#file, "SAML/OIDC: 'no-active-loan' with active credentials — treating as auth error (PP-3716)")
                    return true
                }
            }

            // Check original error for 401 status
            if let nsError = originalError as NSError?, nsError.code == TPPErrorCode.invalidCredentials.rawValue {
                return true
            }

            return false
        }()

        guard isAuthError else {
            return false
        }

        // SQ-007: A borrow failure cannot be a credentials problem if the user
        // already has an active loan for this book. The download flow's
        // auto-re-borrow path (`processRegularDownload` line 559) re-fetches
        // the borrow URL whenever the registry's copy still has a `.borrow`
        // primary acquisition — even for already-borrowed books. The server
        // responds with 401 (loan-already-exists / cannot-issue-loan) which
        // the network responder codes as `invalidCredentials`. Without this
        // gate the user gets a "Sign in" modal showing their *signed-in*
        // account view (Sign out button visible, no input fields), trapping
        // them. The reauth modal makes no sense here — credentials are valid;
        // the borrow simply isn't needed.
        let registeredState = self.bookRegistry.state(for: book.identifier)
        let alreadyHasLoan: Bool = {
            switch registeredState {
            case .downloadNeeded, .downloading, .downloadSuccessful,
                 .downloadFailed, .holding, .SAMLStarted, .used, .returning:
                return true
            case .unregistered, .unsupported:
                return false
            @unknown default:
                return false
            }
        }()
        if alreadyHasLoan && hasCredentials {
            Log.warn(#file, "[SQ-007] Borrow auth-error suppressed for '\(book.title)' — book is already in registry with state \(registeredState) and credentials are present. Treating as benign auto-re-borrow failure, not a credentials problem.")
            return false
        }

        // Circuit breaker: Don't re-auth if we already tried for this book
        guard !Self.hasBorrowReauthBeenAttempted(for: book.identifier) else {
            Log.warn(#file, "Borrow re-auth already attempted for '\(book.title)' - showing error instead")
            return false
        }

        Log.info(#file, "Borrow failed with auth error for '\(book.title)' - attempting re-authentication")
        Self.markBorrowReauthAttempted(for: book.identifier)

        // Mark credentials as stale - preserves Adobe DRM activation
        if hasCredentials {
            userAccount.markCredentialsStale()
        }

        // Handle based on auth type
        let needsBrowserReauth = (authDef?.isSaml == true || authDef?.isOidc == true) && hasCredentials
        if needsBrowserReauth {
            if authDef?.isOidc == true {
                Log.info(#file, "OIDC session expired during borrow - attempting silent re-auth via ASWebAuthenticationSession")
                let oidcSuccess = await attemptOIDCSilentReauth()
                if oidcSuccess {
                    Log.info(#file, "OIDC silent re-auth succeeded, retrying borrow for '\(book.title)'")
                    Self.clearBorrowReauthAttempted(for: book.identifier)
                    Task {
                        do {
                            _ = try await self.borrowAsync(book, attemptDownload: attemptDownload)
                        } catch {
                            Log.error(#file, "Retry borrow failed after OIDC re-auth: \(error.localizedDescription)")
                        }
                    }
                } else {
                    Log.info(#file, "OIDC silent re-auth failed/cancelled - falling back to sign-in modal")
                    await presentSignInModalAndRetryBorrow(book: book, attemptDownload: attemptDownload, authLabel: "OIDC")
                }
            } else {
                Log.info(#file, "SAML session expired during borrow - credentials marked stale, triggering re-auth flow")
                await presentSignInModalAndRetryBorrow(book: book, attemptDownload: attemptDownload, authLabel: "SAML")
            }
            return true

        } else if !hasCredentials && (authDef?.needsAuth ?? false) {
            // No credentials - show sign-in modal
            Log.info(#file, "No credentials for borrow - showing sign-in modal")

            await MainActor.run { [weak self] in
                SignInModalPresenter.presentSignInModalForCurrentAccount {
                    guard let self else { return }

                    guard self.userAccount.hasCredentials() else {
                        Log.info(#file, "Sign-in cancelled or failed, not retrying borrow for '\(book.title)'")
                        Self.clearBorrowReauthAttempted(for: book.identifier)
                        return
                    }

                    Log.info(#file, "Sign-in completed, retrying borrow for '\(book.title)'")

                    Self.clearBorrowReauthAttempted(for: book.identifier)

                    Task {
                        do {
                            _ = try await self.borrowAsync(book, attemptDownload: attemptDownload)
                        } catch {
                            Log.error(#file, "Retry borrow failed after sign-in: \(error.localizedDescription)")
                        }
                    }
                }
            }
            return true
        }

        // For OAuth/Token auth, the network layer should have already tried token refresh.
        // For other types, there's no automatic recovery path.
        Log.warn(#file, "Auth error for \(authDef?.authType.rawValue ?? "unknown") auth type - no automatic recovery")
        return false
    }

    /// Displays borrow error to user with optional problem document from server.
    /// For retryable errors, includes a "Retry" button (up to 5 attempts).
    /// - Parameters:
    ///   - error: The structured PalaceError
    ///   - originalError: The original error that may contain problem document
    ///   - book: The book that failed to borrow
    ///   - problemDocument: Optional pre-extracted problem document
    @MainActor
    private func showBorrowError(
        _ error: PalaceError,
        originalError: Error?,
        for book: TPPBook,
        problemDocument: TPPProblemDocument? = nil
    ) {
        let title = Strings.MyDownloadCenter.borrowFailed

        announceBorrowFailed(for: book)

        // Try to extract problem document from the original error
        let problemDoc: TPPProblemDocument? = {
            if let doc = problemDocument { return doc }
            if let nsError = originalError as NSError? {
                return nsError.problemDocument
            }
            return nil
        }()

        // Log the problem document details for debugging
        if let doc = problemDoc {
            Log.info(#file, "Borrow error with problem document - type: \(doc.type ?? "unknown"), title: \(doc.title ?? "none"), detail: \(doc.detail ?? "none")")
        }

        // Track the error in the activity trail
        Task {
            await ErrorActivityTracker.shared.log(
                "Borrow failed for '\(book.title)': \(error.localizedDescription)",
                category: .borrow
            )
        }

        var message = Self.buildBorrowErrorMessage(
            for: book.title,
            error: error,
            problemDocument: problemDoc
        )

        // Check if this error is retryable and within retry limits (PP-3707)
        let operationId = "borrow-\(book.identifier)"
        let isRetryable = DownloadErrorRecovery.isRetryableForUser(error)
        let canRetry = isRetryable && UserRetryTracker.shared.canRetry(operationId: operationId)

        // If retryable but max retries exceeded, show "try again later" message
        if isRetryable && !canRetry {
            message = Strings.MyDownloadCenter.tryAgainLater
        }

        // Build retry closure if applicable
        let retryAction: (() -> Void)? = canRetry ? { [weak self] in
            UserRetryTracker.shared.recordRetry(operationId: operationId)
            self?.startBorrow(for: book, attemptDownload: true)
        } : nil

        // Use alertWithDetails to include the "View Error Details" button
        // and optionally "Retry" + "Cancel" instead of "OK"
        let alert = TPPAlertUtils.alertWithDetails(
            title: title,
            message: message,
            error: originalError as NSError?,
            problemDocument: problemDoc,
            bookIdentifier: book.identifier,
            bookTitle: book.title,
            retryAction: retryAction
        )

        TPPAlertUtils.presentFromViewControllerOrNil(
            alertController: alert,
            viewController: nil,
            animated: true,
            completion: nil
        )
    }

    // MARK: - Borrow Error Message Builder

    /// Builds a user-friendly borrow error message.
    ///
    /// Always uses the localized "Borrowing [title] could not be completed." base message
    /// instead of raw `PalaceError.localizedDescription` (which can contain technical strings
    /// like "Invalid OPDS feed" that confuse users and generate support tickets).
    ///
    /// Technical details remain available via the "View Error Details" button.
    ///
    /// - Parameters:
    ///   - bookTitle: The title of the book that failed to borrow
    ///   - error: The structured PalaceError
    ///   - problemDocument: Optional problem document from the server
    /// - Returns: A user-friendly error message string
    static func buildBorrowErrorMessage(
        for bookTitle: String,
        error: PalaceError,
        problemDocument: TPPProblemDocument?
    ) -> String {
        let baseMessage = String(format: Strings.MyDownloadCenter.borrowFailedMessage, bookTitle)

        if let doc = problemDocument, let detail = doc.detail, !detail.isEmpty {
            return baseMessage + "\n\n" + detail
        }

        if let recovery = error.recoverySuggestion {
            return baseMessage + "\n\n" + recovery
        }

        return baseMessage
    }

    // MARK: - OIDC Silent Re-auth

    /// Attempts OIDC re-authentication using `ASWebAuthenticationSession`.
    /// Returns `true` if a new token was obtained, `false` on failure/cancel.
    private func attemptOIDCSilentReauth() async -> Bool {
        guard let authDef = userAccount.authDefinition,
              let oidcURL = authDef.oidcAuthenticationUrl else {
            return false
        }

        let callbackScheme = TPPSignInBusinessLogic.oidcCallbackScheme
        let callbackHost = TPPSignInBusinessLogic.oidcCallbackHost
        let redirectURI = "\(callbackScheme)://\(callbackHost)/callback"

        guard var urlComponents = URLComponents(url: oidcURL, resolvingAgainstBaseURL: true) else {
            return false
        }

        let redirectParam = URLQueryItem(name: "redirect_uri", value: redirectURI)
        if urlComponents.queryItems != nil {
            urlComponents.queryItems?.append(redirectParam)
        } else {
            urlComponents.queryItems = [redirectParam]
        }

        guard let finalURL = urlComponents.url else { return false }

        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                let session = ASWebAuthenticationSession(
                    url: finalURL,
                    callbackURLScheme: callbackScheme
                ) { [weak self] callbackURL, error in
                    guard let self else {
                        continuation.resume(returning: false)
                        return
                    }

                    if error != nil {
                        continuation.resume(returning: false)
                        return
                    }

                    guard let callbackURL,
                          let payload = callbackURL.query ?? callbackURL.fragment else {
                        continuation.resume(returning: false)
                        return
                    }

                    var kvpairs = [String: String]()
                    for param in payload.components(separatedBy: "&") {
                        let elts = param.components(separatedBy: "=")
                        guard elts.count >= 2, let key = elts.first else { continue }
                        kvpairs[key] = elts.dropFirst().joined(separator: "=")
                    }

                    guard let accessToken = kvpairs["access_token"] else {
                        continuation.resume(returning: false)
                        return
                    }

                    let ua = self.userAccount
                    ua.setAuthToken(accessToken, barcode: ua.barcode, pin: ua.PIN, expirationDate: nil)
                    Log.info(#file, "OIDC silent re-auth: token updated successfully")
                    continuation.resume(returning: true)
                }

                session.presentationContextProvider = OIDCBorrowPresentationContext.shared
                session.prefersEphemeralWebBrowserSession = false
                session.start()
            }
        }
    }

    /// Presents the sign-in modal and retries the borrow on success.
    private func presentSignInModalAndRetryBorrow(book: TPPBook, attemptDownload: Bool, authLabel: String) async {
        await MainActor.run { [weak self] in
            SignInModalPresenter.presentSignInModalForCurrentAccount {
                guard let self else { return }

                guard self.userAccount.hasCredentials() else {
                    Log.info(#file, "\(authLabel) re-auth cancelled or failed, not retrying borrow for '\(book.title)'")
                    Self.clearBorrowReauthAttempted(for: book.identifier)
                    return
                }

                Log.info(#file, "\(authLabel) re-auth completed, retrying borrow for '\(book.title)'")
                Self.clearBorrowReauthAttempted(for: book.identifier)

                Task {
                    do {
                        _ = try await self.borrowAsync(book, attemptDownload: attemptDownload)
                    } catch {
                        Log.error(#file, "Retry borrow failed after \(authLabel) re-auth: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
}

/// Provides a window anchor for `ASWebAuthenticationSession` in the borrow flow.
private final class OIDCBorrowPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = OIDCBorrowPresentationContext()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.mainKeyWindow ?? ASPresentationAnchor()
    }
}

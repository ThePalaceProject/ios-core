//
//  BorrowOperation.swift
//  Palace
//
//  Owns the complete borrow lifecycle that lived in
//  MyBooksDownloadCenter+Async.swift as ~487 LOC of extension methods:
//
//    - `borrowAsync(_:attemptDownload:)` — main entry: announces start,
//      gates on simulated debug errors, ensures Adobe DRM activation
//      (#if FEATURE_DRM_CONNECTOR), fetches the borrow URL through the
//      injected fetchBook closure, evaluates the response (PP-4178
//      Loan→Hold race), updates the registry, and routes auth-related
//      failures into re-auth.
//    - `handleBorrowAuthErrorIfNeeded(...)` — auth-error detection +
//      circuit-break + dispatch into OIDC silent reauth or a sign-in
//      modal retry. Includes the SQ-007 already-has-loan suppression.
//    - `showBorrowError(...)` — alert presentation with retry button
//      gated by UserRetryTracker (PP-3707).
//    - `attemptOIDCSilentReauth()` — ASWebAuthenticationSession dance.
//    - `presentSignInModalAndRetryBorrow(...)` — modal + post-success
//      retry hop.
//
//  Closure injection over the four side-effecting seams (fetchBook,
//  presentBorrowErrorAlert, presentSignInModal, attemptOIDCReauth)
//  keeps tests from having to stand up the OPDS network stack or the
//  UIKit alert presenter. Production wiring in MBDC supplies real
//  closures over OPDSFeedService.fetchBook, TPPAlertUtils, and
//  SignInModalPresenter; tests stub them.
//
//  The static `borrowReauthAttempted` set + lock that lived on MBDC
//  moves here too; MBDC keeps a forwarder so AccountsManager's
//  account-switch reset call site doesn't change.
//

import AuthenticationServices
import Foundation
import PalaceLogging
import PalaceCatalog

// MARK: - Delegate

/// Callbacks the borrow operation hands back into MBDC's public
/// surface: `startDownload` for the auto-attempt-download success
/// path and `startBorrow` for the retry button in the error alert.
protocol BorrowOperationDelegate: AnyObject {
    @MainActor func startDownload(for book: TPPBook, withRequest initedRequest: URLRequest?)
    func startBorrow(for book: TPPBook, attemptDownload: Bool, borrowCompletion: (() -> Void)?)
}

// MARK: - BorrowOperation

final class BorrowOperation {

    weak var delegate: BorrowOperationDelegate?

    // MARK: - Borrow Re-auth Circuit Breaker

    /// Tracks whether we've already attempted re-authentication for a
    /// borrow operation. Prevents infinite re-auth loops for persistent
    /// auth failures. Shared across BorrowOperation instances so
    /// account-switch state can be cleared centrally.
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

    /// Clears all re-auth tracking. Called on account switch via the
    /// MBDC forwarder so stale circuit-breaker state from the previous
    /// account can't suppress legitimate re-auth attempts.
    static func clearAllBorrowReauthState() {
        borrowReauthLock.lock()
        defer { borrowReauthLock.unlock() }
        borrowReauthAttempted.removeAll()
    }

    // MARK: - Pure Helpers

    /// Maps a book returned from a Borrow request to the resulting
    /// registry state and any error that should be surfaced.
    /// PP-4178: when CM loses the Loan→Hold race (another patron
    /// consumes the copy between HoldAvailable push and this borrow
    /// tap), CM returns 201 with a `reserved`/`unavailable` OPDS entry
    /// instead of a loan; flag that case so the caller throws an
    /// explicit error instead of silently reverting.
    static func borrowResponseState(for book: TPPBook) -> (state: TPPBookState, error: PalaceError?) {
        guard let availability = book.defaultAcquisition?.availability else {
            return (.downloadNeeded, nil)
        }

        var state: TPPBookState = .downloadNeeded
        var error: PalaceError?

        availability.match(
            unavailable: { _ in
                state = .holding
                error = .bookRegistry(.holdCopyUnavailable)
            },
            limited: { _ in state = .downloadNeeded },
            unlimited: { _ in state = .downloadNeeded },
            reserved: { _ in
                state = .holding
                error = .bookRegistry(.holdCopyUnavailable)
            },
            ready: { _ in state = .downloadNeeded }
        )

        return (state, error)
    }

    /// Builds a user-friendly borrow error message that always uses
    /// the localized "Borrowing [title] could not be completed." base
    /// instead of raw `PalaceError.localizedDescription` (which can
    /// contain technical strings that confuse users).
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

    // MARK: - Dependencies

    private let bookRegistry: TPPBookRegistryProvider
    private let downloadAnnouncementService: DownloadAnnouncementService
    private let errorActivityTracker: ErrorActivityTracker
    private let debugSettings: DebugSettings
    private let userRetryTracker: UserRetryTracker
    private let userAccountProvider: () -> TPPUserAccount
    #if FEATURE_DRM_CONNECTOR
    private let adobeDRMService: AdobeDRMService
    #endif

    // MARK: - Closure-Injected Seams

    /// Fetches a book from the borrow URL. Production wraps
    /// `OPDSFeedService.fetchBook(from:resetCache:useToken:)` with
    /// `DownloadErrorRecovery.executeWithRetry(...)`. Tests stub it.
    private let fetchBook: (URL, Bool, Bool) async throws -> TPPBook

    /// Presents a borrow error alert. Production wraps
    /// `TPPAlertUtils.alertWithDetails(...)` + `presentFromViewControllerOrNil`.
    /// Tests stub to assert the path was hit without UIKit.
    private let presentBorrowErrorAlert: @MainActor (
        _ title: String,
        _ message: String,
        _ originalError: NSError?,
        _ problemDocument: TPPProblemDocument?,
        _ book: TPPBook,
        _ retryAction: (() -> Void)?
    ) -> Void

    /// Presents the sign-in modal. Production wraps
    /// `SignInModalPresenter.presentSignInModalForCurrentAccount(completion:)`.
    private let presentSignInModal: @MainActor (@escaping () -> Void) -> Void

    /// Attempts OIDC silent reauth via ASWebAuthenticationSession.
    /// Production handles the whole web-session dance; tests return
    /// a deterministic Bool.
    private let attemptOIDCReauth: () async -> Bool

    // MARK: - Init

    #if FEATURE_DRM_CONNECTOR
    init(
        bookRegistry: TPPBookRegistryProvider,
        downloadAnnouncementService: DownloadAnnouncementService,
        errorActivityTracker: ErrorActivityTracker,
        debugSettings: DebugSettings,
        userRetryTracker: UserRetryTracker,
        userAccountProvider: @escaping () -> TPPUserAccount,
        adobeDRMService: AdobeDRMService,
        fetchBook: @escaping (URL, Bool, Bool) async throws -> TPPBook,
        presentBorrowErrorAlert: @escaping @MainActor (String, String, NSError?, TPPProblemDocument?, TPPBook, (() -> Void)?) -> Void,
        presentSignInModal: @escaping @MainActor (@escaping () -> Void) -> Void,
        attemptOIDCReauth: @escaping () async -> Bool
    ) {
        self.bookRegistry = bookRegistry
        self.downloadAnnouncementService = downloadAnnouncementService
        self.errorActivityTracker = errorActivityTracker
        self.debugSettings = debugSettings
        self.userRetryTracker = userRetryTracker
        self.userAccountProvider = userAccountProvider
        self.adobeDRMService = adobeDRMService
        self.fetchBook = fetchBook
        self.presentBorrowErrorAlert = presentBorrowErrorAlert
        self.presentSignInModal = presentSignInModal
        self.attemptOIDCReauth = attemptOIDCReauth
    }
    #else
    init(
        bookRegistry: TPPBookRegistryProvider,
        downloadAnnouncementService: DownloadAnnouncementService,
        errorActivityTracker: ErrorActivityTracker,
        debugSettings: DebugSettings,
        userRetryTracker: UserRetryTracker,
        userAccountProvider: @escaping () -> TPPUserAccount,
        fetchBook: @escaping (URL, Bool, Bool) async throws -> TPPBook,
        presentBorrowErrorAlert: @escaping @MainActor (String, String, NSError?, TPPProblemDocument?, TPPBook, (() -> Void)?) -> Void,
        presentSignInModal: @escaping @MainActor (@escaping () -> Void) -> Void,
        attemptOIDCReauth: @escaping () async -> Bool
    ) {
        self.bookRegistry = bookRegistry
        self.downloadAnnouncementService = downloadAnnouncementService
        self.errorActivityTracker = errorActivityTracker
        self.debugSettings = debugSettings
        self.userRetryTracker = userRetryTracker
        self.userAccountProvider = userAccountProvider
        self.fetchBook = fetchBook
        self.presentBorrowErrorAlert = presentBorrowErrorAlert
        self.presentSignInModal = presentSignInModal
        self.attemptOIDCReauth = attemptOIDCReauth
    }
    #endif

    // MARK: - Borrow

    /// Borrows a book using modern async/await.
    /// Returns the borrowed book with updated acquisition links.
    /// Throws PalaceError if borrow fails (or the Loan→Hold race fires).
    func borrowAsync(
        _ book: TPPBook,
        attemptDownload: Bool = false
    ) async throws -> TPPBook {
        let bookIdentifier = book.identifier

        downloadAnnouncementService.announceBorrowStarted(for: book)

        Task { [errorActivityTracker] in await errorActivityTracker.log("Initiating borrow for '\(book.title)'", category: .borrow) }

        if Bundle.main.applicationEnvironment != .production,
           let simulated = self.debugSettings.createSimulatedBorrowError() {
            await self.errorActivityTracker.log(
                "Simulated borrow error triggered: \(self.debugSettings.simulatedBorrowError.displayName)",
                category: .borrow
            )
            await MainActor.run {
                self.showBorrowError(.network(.forbidden), originalError: simulated.error, for: book, problemDocument: simulated.problemDocument)
            }
            throw simulated.error
        }

        // PP-3649: ensure Adobe DRM device activation before proceeding.
        #if FEATURE_DRM_CONNECTOR
        if book.requiresAdobeDRM {
            Task { [errorActivityTracker] in await errorActivityTracker.log("Book requires Adobe DRM — checking device activation", category: .borrow) }
            try await self.adobeDRMService.ensureDeviceActivated()
        }
        #endif

        guard let acquisitionURL = book.defaultAcquisition?.hrefURL else {
            Task { [errorActivityTracker] in await errorActivityTracker.log("No acquisition URL found for '\(book.title)'", category: .borrow) }
            throw PalaceError.bookRegistry(.invalidState)
        }

        Task { [errorActivityTracker] in await errorActivityTracker.log("Requesting loan from \(acquisitionURL.host ?? acquisitionURL.absoluteString)", category: .network) }

        // Set processing state - shows a spinner in the UI.
        await MainActor.run {
            self.bookRegistry.setProcessing(true, for: bookIdentifier)
        }

        @MainActor func clearProcessingState() {
            self.bookRegistry.setProcessing(false, for: bookIdentifier)
        }

        do {
            let borrowedBook = try await self.fetchBook(acquisitionURL, true, true)

            await clearProcessingState()

            let location = self.bookRegistry.location(forIdentifier: borrowedBook.identifier)
            let mapping = Self.borrowResponseState(for: borrowedBook)

            self.bookRegistry.addBook(
                borrowedBook,
                location: location,
                state: mapping.state,
                fulfillmentId: nil as String?,
                readiumBookmarks: nil as [TPPReadiumBookmark]?,
                genericBookmarks: nil as [TPPBookLocation]?
            )
            self.bookRegistry.setState(mapping.state, for: borrowedBook.identifier)

            if let raceError = mapping.error {
                Task { [errorActivityTracker] in await errorActivityTracker.log(
                    "Borrow for '\(borrowedBook.title)' returned \(mapping.state) — CM Loan→Hold race (PP-4178)",
                    category: .borrow
                ) }
                TPPErrorLogger.logError(raceError, summary: "Borrow race: CM returned hold for '\(borrowedBook.title)'")
                throw raceError
            }

            Task { [errorActivityTracker] in await errorActivityTracker.log("Borrow succeeded for '\(borrowedBook.title)', state: \(mapping.state)", category: .borrow) }

            downloadAnnouncementService.announceBorrowSucceeded(for: borrowedBook)

            if attemptDownload && mapping.state == .downloadNeeded {
                await MainActor.run { [weak self] in
                    self?.delegate?.startDownload(for: borrowedBook, withRequest: nil)
                }
            }

            // PP-3811: trigger a sync after a short delay so hold position
            // updates from the loans feed (immediate borrow response often
            // returns holdPosition=0).
            if mapping.state == .holding {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    (self.bookRegistry as? TPPBookRegistry)?.sync()
                }
            }

            Self.clearBorrowReauthAttempted(for: bookIdentifier)

            return borrowedBook

        } catch let error as PalaceError {
            await clearProcessingState()

            if await handleBorrowAuthErrorIfNeeded(error, originalError: nil, for: book, attemptDownload: attemptDownload) {
                throw error
            }

            await MainActor.run {
                self.showBorrowError(error, originalError: nil, for: book)
            }
            throw error
        } catch {
            await clearProcessingState()

            let nsError = error as NSError
            let problemDoc = nsError.problemDocument

            let palaceError = PalaceError.from(error)

            if await handleBorrowAuthErrorIfNeeded(palaceError, originalError: error, for: book, attemptDownload: attemptDownload, problemDocument: problemDoc) {
                throw palaceError
            }

            await MainActor.run {
                self.showBorrowError(palaceError, originalError: error, for: book, problemDocument: problemDoc)
            }
            throw palaceError
        }
    }

    // MARK: - Auth-Error Handling

    /// Returns `true` if re-auth was triggered (caller should not show error), `false` otherwise.
    private func handleBorrowAuthErrorIfNeeded(
        _ error: PalaceError,
        originalError: Error?,
        for book: TPPBook,
        attemptDownload: Bool,
        problemDocument: TPPProblemDocument? = nil
    ) async -> Bool {
        let userAccount = userAccountProvider()
        let authDef = userAccount.authDefinition
        let hasCredentials = userAccount.hasCredentials()

        let isAuthError: Bool = {
            if case .authentication = error { return true }

            if let problemDoc = problemDocument {
                if problemDoc.type == TPPProblemDocument.TypeInvalidCredentials { return true }

                if problemDoc.isRecoverableAuthError {
                    Log.info(#file, "Recoverable auth error detected: \(problemDoc.type ?? "unknown") — triggering re-auth (PP-3716)")
                    return true
                }

                if problemDoc.type == TPPProblemDocument.TypeNoActiveLoan,
                   (authDef?.isSaml == true || authDef?.isOidc == true),
                   hasCredentials {
                    Log.info(#file, "SAML/OIDC: 'no-active-loan' with active credentials — treating as auth error (PP-3716)")
                    return true
                }
            }

            if let nsError = originalError as NSError?, nsError.code == TPPErrorCode.invalidCredentials.rawValue {
                return true
            }

            return false
        }()

        guard isAuthError else { return false }

        // SQ-007: suppress auth-error if the user already has an active
        // loan for this book. The auto-re-borrow path can fire 401
        // (loan-already-exists) which the network responder codes as
        // invalidCredentials — but credentials are valid, the borrow
        // simply isn't needed.
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

        // Circuit breaker: don't re-auth if we already tried for this book.
        guard !Self.hasBorrowReauthBeenAttempted(for: book.identifier) else {
            Log.warn(#file, "Borrow re-auth already attempted for '\(book.title)' - showing error instead")
            return false
        }

        Log.info(#file, "Borrow failed with auth error for '\(book.title)' - attempting re-authentication")
        Self.markBorrowReauthAttempted(for: book.identifier)

        if hasCredentials {
            userAccount.markCredentialsStale()
        }

        let needsBrowserReauth = (authDef?.isSaml == true || authDef?.isOidc == true) && hasCredentials
        if needsBrowserReauth {
            if authDef?.isOidc == true {
                Log.info(#file, "OIDC session expired during borrow - attempting silent re-auth via ASWebAuthenticationSession")
                let oidcSuccess = await attemptOIDCReauth()
                if oidcSuccess {
                    Log.info(#file, "OIDC silent re-auth succeeded, retrying borrow for '\(book.title)'")
                    Self.clearBorrowReauthAttempted(for: book.identifier)
                    Task { [weak self] in
                        do {
                            _ = try await self?.borrowAsync(book, attemptDownload: attemptDownload)
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
            Log.info(#file, "No credentials for borrow - showing sign-in modal")

            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.presentSignInModal { [weak self] in
                    guard let self else { return }

                    guard self.userAccountProvider().hasCredentials() else {
                        Log.info(#file, "Sign-in cancelled or failed, not retrying borrow for '\(book.title)'")
                        Self.clearBorrowReauthAttempted(for: book.identifier)
                        return
                    }

                    Log.info(#file, "Sign-in completed, retrying borrow for '\(book.title)'")
                    Self.clearBorrowReauthAttempted(for: book.identifier)

                    Task { [weak self] in
                        do {
                            _ = try await self?.borrowAsync(book, attemptDownload: attemptDownload)
                        } catch {
                            Log.error(#file, "Retry borrow failed after sign-in: \(error.localizedDescription)")
                        }
                    }
                }
            }
            return true
        }

        Log.warn(#file, "Auth error for \(authDef?.authType.rawValue ?? "unknown") auth type - no automatic recovery")
        return false
    }

    // MARK: - Error Presentation

    @MainActor
    private func showBorrowError(
        _ error: PalaceError,
        originalError: Error?,
        for book: TPPBook,
        problemDocument: TPPProblemDocument? = nil
    ) {
        let title = Strings.MyDownloadCenter.borrowFailed

        downloadAnnouncementService.announceBorrowFailed(for: book)

        let problemDoc: TPPProblemDocument? = {
            if let doc = problemDocument { return doc }
            if let nsError = originalError as NSError? {
                return nsError.problemDocument
            }
            return nil
        }()

        if let doc = problemDoc {
            Log.info(#file, "Borrow error with problem document - type: \(doc.type ?? "unknown"), title: \(doc.title ?? "none"), detail: \(doc.detail ?? "none")")
        }

        Task { [errorActivityTracker] in
            await errorActivityTracker.log(
                "Borrow failed for '\(book.title)': \(error.localizedDescription)",
                category: .borrow
            )
        }

        var message = Self.buildBorrowErrorMessage(
            for: book.title,
            error: error,
            problemDocument: problemDoc
        )

        // PP-3707: gate retry button on per-operation retry budget.
        let operationId = "borrow-\(book.identifier)"
        let isRetryable = DownloadErrorRecovery.isRetryableForUser(error)
        let canRetry = isRetryable && self.userRetryTracker.canRetry(operationId: operationId)

        if isRetryable && !canRetry {
            message = Strings.MyDownloadCenter.tryAgainLater
        }

        let retryAction: (() -> Void)? = canRetry ? { [weak self] in
            guard let self else { return }
            self.userRetryTracker.recordRetry(operationId: operationId)
            self.delegate?.startBorrow(for: book, attemptDownload: true, borrowCompletion: nil)
        } : nil

        presentBorrowErrorAlert(title, message, originalError as NSError?, problemDoc, book, retryAction)
    }

    // MARK: - OIDC Silent Re-auth (Production Helper)

    /// Static helper that production wiring uses for the
    /// `attemptOIDCReauth` closure. Tests bypass this entirely by
    /// passing a stub closure. Returns `true` if a new token was
    /// obtained, `false` on failure/cancel/no-OIDC-config.
    static func attemptOIDCSilentReauth(userAccount: TPPUserAccount) async -> Bool {
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
                ) { callbackURL, error in
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

                    userAccount.setAuthToken(accessToken, barcode: userAccount.barcode, pin: userAccount.PIN, expirationDate: nil)
                    Log.info(#file, "OIDC silent re-auth: token updated successfully")
                    continuation.resume(returning: true)
                }

                session.presentationContextProvider = OIDCBorrowPresentationContext.shared
                session.prefersEphemeralWebBrowserSession = false
                session.start()
            }
        }
    }

    // MARK: - Sign-In Modal Retry

    /// Presents the sign-in modal and retries the borrow on success.
    /// Used by both SAML and OIDC fallback paths.
    private func presentSignInModalAndRetryBorrow(book: TPPBook, attemptDownload: Bool, authLabel: String) async {
        await MainActor.run { [weak self] in
            guard let self = self else { return }
            self.presentSignInModal { [weak self] in
                guard let self else { return }

                guard self.userAccountProvider().hasCredentials() else {
                    Log.info(#file, "\(authLabel) re-auth cancelled or failed, not retrying borrow for '\(book.title)'")
                    Self.clearBorrowReauthAttempted(for: book.identifier)
                    return
                }

                Log.info(#file, "\(authLabel) re-auth completed, retrying borrow for '\(book.title)'")
                Self.clearBorrowReauthAttempted(for: book.identifier)

                Task { [weak self] in
                    do {
                        _ = try await self?.borrowAsync(book, attemptDownload: attemptDownload)
                    } catch {
                        Log.error(#file, "Retry borrow failed after \(authLabel) re-auth: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
}

/// Provides a window anchor for `ASWebAuthenticationSession` in the
/// borrow flow's OIDC silent reauth path.
private final class OIDCBorrowPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = OIDCBorrowPresentationContext()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.mainKeyWindow ?? ASPresentationAnchor()
    }
}

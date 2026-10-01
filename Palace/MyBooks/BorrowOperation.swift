//
//  BorrowOperation.swift
//  Palace
//
//  The borrow lifecycle: Adobe activation, the borrow fetch, response
//  evaluation (PP-4178 Loan→Hold race), registry update, and auth-error
//  handling (circuit break, OIDC silent reauth, sign-in modal retry, the
//  SQ-007 already-has-loan suppression, PP-3707 retry gating).
//
//  The side-effecting seams (fetchBook, presentBorrowErrorAlert,
//  presentSignInModal, attemptOIDCReauth) are injected closures so tests
//  need neither the OPDS network stack nor UIKit.
//

import AuthenticationServices
import Foundation
import PalaceAuth
import PalaceLogging
import PalaceCatalog
import PalaceBookModel
import PalaceBookRegistry

// MARK: - Delegate

/// Callbacks the borrow operation hands back into MBDC's public
/// surface: `startDownload` for the auto-attempt-download success
/// path and `startBorrow` for the retry button in the error alert.
protocol BorrowOperationDelegate: AnyObject {
    @MainActor func startDownload(for book: TPPBook, withRequest initedRequest: URLRequest?)
    func startBorrow(for book: TPPBook, attemptDownload: Bool, borrowCompletion: (() -> Void)?)
}

// MARK: - BorrowAuthErrorDecision

/// Decision returned by `handleBorrowAuthErrorIfNeeded` so the caller in
/// `borrowAsync` can correctly route the post-decision UI side effects.
///
/// - `routeToReauth`: an auth-recovery path (OIDC silent reauth or sign-in
///   modal) was kicked off. Caller MUST NOT also surface a borrow-error
///   alert — that would race the re-auth UI and confuse the patron.
/// - `suppressAndClearSpinner`: SQ-007 case — the book is already in the
///   patron's loans with active credentials, so the auth-flavored borrow
///   error is benign (the auto-re-borrow ran but wasn't needed). Caller
///   must not show the alert and must clear the cell spinner.
/// - `showGenericError`: not an auth error, or auth recovery isn't
///   available — caller shows the standard `showBorrowError` alert.
private enum BorrowAuthErrorDecision {
    case routeToReauth
    case suppressAndClearSpinner
    case showGenericError
}

// MARK: - BorrowOperation

/// - Sendable invariant: every stored dependency is a `let` bound at init. The
///   only mutable member is `weak var delegate`, assigned once during
///   `MyBooksDownloadCenter` construction (weak reads are atomic).
///   Circuit-breaker state lives in the lock-backed `static let reauthTracker`.
///   `@unchecked` because the delegate existential and the shared service
///   types are not themselves `Sendable`.
final class BorrowOperation: @unchecked Sendable {

    weak var delegate: BorrowOperationDelegate?

    // MARK: - Borrow Re-auth Circuit Breaker

    /// Tracks whether we've already attempted re-authentication for a
    /// borrow operation. Prevents infinite re-auth loops for persistent
    /// auth failures. Shared across BorrowOperation instances so
    /// account-switch state can be cleared centrally.
    ///
    /// Set and lock live in one `@unchecked Sendable` holder: a mutable static
    /// guarded by a sibling lock still warns under Swift 6 complete checking.
    private final class ReauthTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var attempted: Set<String> = []

        func hasAttempted(_ bookId: String) -> Bool { lock.withLock { attempted.contains(bookId) } }
        func mark(_ bookId: String) { lock.withLock { _ = attempted.insert(bookId) } }
        func clear(_ bookId: String) { lock.withLock { attempted.remove(bookId) } }
        func clearAll() { lock.withLock { attempted.removeAll() } }
    }

    private static let reauthTracker = ReauthTracker()

    private static func hasBorrowReauthBeenAttempted(for bookId: String) -> Bool {
        reauthTracker.hasAttempted(bookId)
    }

    private static func markBorrowReauthAttempted(for bookId: String) {
        reauthTracker.mark(bookId)
    }

    private static func clearBorrowReauthAttempted(for bookId: String) {
        reauthTracker.clear(bookId)
    }

    /// Clears all re-auth tracking. Called on account switch via the
    /// MBDC forwarder so stale circuit-breaker state from the previous
    /// account can't suppress legitimate re-auth attempts.
    static func clearAllBorrowReauthState() {
        reauthTracker.clearAll()
    }

    // MARK: - Pure Helpers

    /// Races an async operation against a deadline; the loser is cancelled.
    /// Expiry throws `PalaceError.network(.timeout)` so the borrow-error alert
    /// with Retry appears instead of the half-sheet spinning forever.
    static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw PalaceError.network(.timeout)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw PalaceError.network(.timeout)
            }
            return first
        }
    }

    /// Maps a borrow/place-hold response to a registry state and optional error.
    /// Delegates to `BorrowReducerCore.responseState`.
    static func borrowResponseState(
        for postBorrowBook: TPPBook,
        preBorrowBook: TPPBook? = nil
    ) -> (state: TPPBookState, error: PalaceError?) {
        BorrowReducerCore.responseState(for: postBorrowBook, preBorrowBook: preBorrowBook)
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

    /// Auth-refresh coordinator. When non-nil, the SAML / generic browser
    /// sign-in in `handleBorrowAuthErrorIfNeeded` routes through it instead of
    /// `presentSignInModal`. The per-book circuit breaker still applies: the
    /// coordinator is single-flight process-wide, not per book.
    private let authCoordinator: AuthCoordinator?

    /// Run once a borrow succeeds: the app-rating secondary trigger (PP-4088).
    /// Injected rather than reaching `AppContainer.production()`, which builds
    /// the full DI graph on the main actor and deadlocked @MainActor tests.
    private let onBorrowSucceeded: @MainActor () -> Void

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
        attemptOIDCReauth: @escaping () async -> Bool,
        authCoordinator: AuthCoordinator? = nil,
        onBorrowSucceeded: @escaping @MainActor () -> Void = {}
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
        self.authCoordinator = authCoordinator
        self.onBorrowSucceeded = onBorrowSucceeded
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
        attemptOIDCReauth: @escaping () async -> Bool,
        authCoordinator: AuthCoordinator? = nil,
        onBorrowSucceeded: @escaping @MainActor () -> Void = {}
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
        self.authCoordinator = authCoordinator
        self.onBorrowSucceeded = onBorrowSucceeded
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

        // Must precede activation: activation raises the processing spinner and
        // only clears it if activation itself throws, so a throw from this guard
        // after it would strand the spinner. It also avoids spending an Adobe
        // activation on a book that cannot be borrowed.
        guard let acquisitionURL = book.defaultAcquisition?.hrefURL else {
            Task { [errorActivityTracker] in await errorActivityTracker.log("No acquisition URL found for '\(book.title)'", category: .borrow) }
            throw PalaceError.bookRegistry(.invalidState)
        }

        // ensure Adobe DRM device activation before proceeding.
        #if FEATURE_DRM_CONNECTOR
        if book.requiresAdobeDRM {
            Task { [errorActivityTracker] in await errorActivityTracker.log("Book requires Adobe DRM — checking device activation", category: .borrow) }

            try await BorrowAdobeActivationStep.run(
                setProcessing: { [bookRegistry] in bookRegistry.setProcessing($0, for: bookIdentifier) },
                activate: { [adobeDRMService] in try await adobeDRMService.ensureDeviceActivated(licensorGracePeriod: $0) },
                // PP-3649: activation failure must show a clear error; without
                // this the spinner just clears and the patron sees nothing.
                onFailure: { [weak self] error in
                    // The activation path already mapped Adobe's code to a
                    // PalaceError. Re-deriving from `error as NSError` would read
                    // the PalaceError domain and fall back to "sign in again",
                    // even when the real cause is exhausted activations. The
                    // `.adobeError` fallback is currently unreachable.
                    let palaceError = (error as? PalaceError) ?? .drm(.adobeError)
                    self?.showBorrowError(palaceError, originalError: error, for: book)
                }
            )
        }
        #endif

        Task { [errorActivityTracker] in await errorActivityTracker.log("Requesting loan from \(acquisitionURL.host ?? acquisitionURL.absoluteString)", category: .network) }

        // Set processing state - shows a spinner in the UI.
        await MainActor.run {
            self.bookRegistry.setProcessing(true, for: bookIdentifier)
        }

        @MainActor func clearProcessingState() {
            self.bookRegistry.setProcessing(false, for: bookIdentifier)
        }

        do {
            // F-014: explicit 30s ceiling. CM/distributor connections have been
            // seen hanging 120s+ mid-flight despite URLSession's 60s default,
            // leaving the half-sheet stuck on Cancel only. 30s is well above a
            // healthy borrow (~1.5s median) and yields a retryable timeout alert.
            let borrowedBook = try await Self.withTimeout(seconds: 30) {
                try await self.fetchBook(acquisitionURL, true, true)
            }

            await clearProcessingState()

            let location = self.bookRegistry.location(forIdentifier: borrowedBook.identifier)
            // The pre-borrow `book` lets the helper tell a Place Hold success
            // apart from a CM Loan→Hold race loss.
            let mapping = Self.borrowResponseState(for: borrowedBook, preBorrowBook: book)

            self.bookRegistry.addBook(
                borrowedBook,
                location: location,
                state: mapping.state,
                fulfillmentId: nil as String?,
                readiumBookmarks: nil as [TPPReadiumBookmark]?,
                genericBookmarks: nil as [TPPBookLocation]?
            )
            self.bookRegistry.setState(mapping.state, for: borrowedBook.identifier)

            // Branch SELECTION + effect ORDER live in the pure
            // `BorrowReducerCore.postResponseEffects`; this loop runs each
            // decided effect (logging, MainActor hops, the throw, and the sync
            // `Task` stay here — the operation owns the effects).
            let postEffects = BorrowReducerCore.postResponseEffects(
                state: mapping.state,
                isStreamingHTML: borrowedBook.isStreamingHTML,
                attemptDownload: attemptDownload,
                hasRaceError: mapping.error != nil
            )

            for effect in postEffects {
                switch effect {
                case .failWithRaceError:
                    // PP-4178: registry is already updated to the hold state; now
                    // throw so the catch block surfaces the borrow-failed alert.
                    let raceError = mapping.error ?? .bookRegistry(.holdCopyUnavailable)
                    Task { [errorActivityTracker] in await errorActivityTracker.log(
                        "Borrow for '\(borrowedBook.title)' returned \(mapping.state) — CM Loan→Hold race (PP-4178)",
                        category: .borrow
                    ) }
                    TPPErrorLogger.logError(raceError, summary: "Borrow race: CM returned hold for '\(borrowedBook.title)'")
                    throw raceError

                case .announceBorrowSucceeded:
                    Task { [errorActivityTracker] in await errorActivityTracker.log("Borrow succeeded for '\(borrowedBook.title)', state: \(mapping.state)", category: .borrow) }
                    downloadAnnouncementService.announceBorrowSucceeded(for: borrowedBook)

                case .noteBorrowSucceeded:
                    // Awaited so effect order relative to `startDownload` is
                    // deterministic.
                    await MainActor.run { [onBorrowSucceeded] in onBorrowSucceeded() }

                case .startDownload:
                    // F-014: the borrow→download chain is one user-intent step
                    // from the half-sheet — fire whenever the borrow lands on
                    // `.downloadNeeded` (non-streaming). `.holding` and terminal
                    // states correctly skip it (nothing to download yet).
                    await MainActor.run { [weak self] in
                        self?.delegate?.startDownload(for: borrowedBook, withRequest: nil)
                    }

                case .scheduleHoldPositionSync:
                    // Sync shortly after so the hold position updates from the
                    // loans feed (the immediate response often returns position 0).
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        (self.bookRegistry as? TPPBookRegistry)?.sync()
                    }
                }
            }

            Self.clearBorrowReauthAttempted(for: bookIdentifier)

            return borrowedBook

        } catch let error as PalaceError {
            await clearProcessingState()

            // Pass the PalaceError as `originalError` so a 401 with no problem
            // doc (`.network(.unauthorized)` / `.forbidden`) still routes to reauth.
            let decision = await handleBorrowAuthErrorIfNeeded(
                error,
                originalError: error,
                for: book,
                attemptDownload: attemptDownload
            )

            switch decision {
            case .routeToReauth:
                throw error
            case .suppressAndClearSpinner:
                // SQ-007: the book is already registered with active
                // credentials. Skip the alert, and re-clear processing in case
                // a notification flipped it back since `clearProcessingState`.
                await MainActor.run {
                    self.bookRegistry.setProcessing(false, for: book.identifier)
                }
                throw error
            case .showGenericError:
                await MainActor.run {
                    self.showBorrowError(error, originalError: nil, for: book)
                }
                throw error
            }
        } catch {
            await clearProcessingState()

            let nsError = error as NSError
            let problemDoc = nsError.problemDocument

            let palaceError = PalaceError.from(error)

            let decision = await handleBorrowAuthErrorIfNeeded(
                palaceError,
                originalError: error,
                for: book,
                attemptDownload: attemptDownload,
                problemDocument: problemDoc
            )

            switch decision {
            case .routeToReauth:
                throw palaceError
            case .suppressAndClearSpinner:
                await MainActor.run {
                    self.bookRegistry.setProcessing(false, for: book.identifier)
                }
                throw palaceError
            case .showGenericError:
                await MainActor.run {
                    self.showBorrowError(palaceError, originalError: error, for: book, problemDocument: problemDoc)
                }
                throw palaceError
            }
        }
    }

    // MARK: - Auth-Error Handling

    /// Inspects a borrow failure and returns the routing decision the
    /// caller should follow. See `BorrowAuthErrorDecision`: the SQ-007
    /// suppression is distinct from "not an auth error" so a benign
    /// auto-re-borrow failure shows no credentials alert.
    private func handleBorrowAuthErrorIfNeeded(
        _ error: PalaceError,
        originalError: Error?,
        for book: TPPBook,
        attemptDownload: Bool,
        problemDocument: TPPProblemDocument? = nil
    ) async -> BorrowAuthErrorDecision {
        let userAccount = userAccountProvider()
        let authDef = userAccount.authDefinition
        let hasCredentials = userAccount.hasCredentials()

        let isAuthError: Bool = {
            if case .authentication = error { return true }

            // A 401 surfacing as `.network(.unauthorized)` / `.forbidden`
            // (an OPDS path can strip the problem doc) must route to reauth
            // rather than a generic "Network request failed (912)" alert.
            if case .network(.unauthorized) = error { return true }
            if case .network(.forbidden) = error { return true }

            if let problemDoc = problemDocument {
                if problemDoc.type == TPPProblemDocument.TypeInvalidCredentials { return true }

                if problemDoc.isRecoverableAuthError {
                    Log.info(#file, "Recoverable auth error detected: \(problemDoc.type ?? "unknown") — triggering re-auth (PP-3716)")
                    return true
                }

                if problemDoc.type == TPPProblemDocument.TypeNoActiveLoan,
                   authDef?.isBrowserBased == true,
                   hasCredentials {
                    Log.info(#file, "Browser-based auth (SAML/OIDC/OAuth): 'no-active-loan' with active credentials — treating as auth error (PP-3716; swarm_66819d80 broadened from SAML+OIDC to include OAuth-intermediary)")
                    return true
                }
            }

            if let nsError = originalError as NSError?, nsError.code == TPPErrorCode.invalidCredentials.rawValue {
                return true
            }

            return true
        }()

        guard isAuthError else { return .showGenericError }

        // SQ-007: suppress auth-error if the user already has an active
        // loan for this book. The auto-re-borrow path can fire 401
        // (loan-already-exists) which the network responder codes as
        // invalidCredentials — but credentials are valid, the borrow
        // simply isn't needed.
        let registeredState = self.bookRegistry.state(for: book.identifier)
        let alreadyHasLoan = BorrowReducerCore.alreadyHasActiveLoan(state: registeredState)
        if alreadyHasLoan && hasCredentials {
            Log.warn(#file, "[SQ-007] Borrow auth-error suppressed for '\(book.title)' — book is already in registry with state \(registeredState) and credentials are present. Treating as benign auto-re-borrow failure, not a credentials problem.")
            return .suppressAndClearSpinner
        }

        // Circuit breaker: don't re-auth if we already tried for this book.
        guard !Self.hasBorrowReauthBeenAttempted(for: book.identifier) else {
            Log.warn(#file, "Borrow re-auth already attempted for '\(book.title)' - showing error instead")
            return .showGenericError
        }

        Log.info(#file, "Borrow failed with auth error for '\(book.title)' - attempting re-authentication")
        Self.markBorrowReauthAttempted(for: book.identifier)

        if hasCredentials {
            userAccount.markCredentialsStale()
        }

        // `isBrowserBased` includes OAuth-intermediary (Clever), which needs
        // the same browser-reauth recovery as SAML/OIDC.
        let needsBrowserReauth = (authDef?.isBrowserBased == true) && hasCredentials
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
                    // Silent reauth failed, so the IdP session needs an
                    // interactive sign-in, same as SAML.
                    Log.info(#file, "OIDC silent re-auth failed/cancelled - falling back to sign-in modal")
                    if let coordinator = self.authCoordinator {
                        await coordinatorRetryBorrow(
                            book: book,
                            attemptDownload: attemptDownload,
                            coordinator: coordinator,
                            reason: .oidcRefreshFailed,
                            authLabel: "OIDC"
                        )
                    } else {
                        await presentSignInModalAndRetryBorrow(book: book, attemptDownload: attemptDownload, authLabel: "OIDC")
                    }
                }
            } else {
                Log.info(#file, "SAML/OAuth-intermediary session expired during borrow - credentials marked stale, triggering re-auth flow")
                if let coordinator = self.authCoordinator {
                    let reason: ReauthReason = (authDef?.isSaml == true)
                        ? .samlSessionExpired
                        : .invalidCredentials
                    await coordinatorRetryBorrow(
                        book: book,
                        attemptDownload: attemptDownload,
                        coordinator: coordinator,
                        reason: reason,
                        authLabel: (authDef?.isSaml == true) ? "SAML" : "OAuth-intermediary"
                    )
                } else {
                    await presentSignInModalAndRetryBorrow(book: book, attemptDownload: attemptDownload, authLabel: "SAML")
                }
            }
            return .routeToReauth

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
            return .routeToReauth
        }

        Log.warn(#file, "Auth error for \(authDef?.authType.rawValue ?? "unknown") auth type - no automatic recovery")
        return .showGenericError
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

        // gate retry button on per-operation retry budget.
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

    // MARK: - Coordinator-Routed Retry

    /// Asks the coordinator to refresh credentials (it dispatches the
    /// appropriate modal flow per IdP); on success clears the per-book
    /// circuit breaker and retries the borrow. On failure leaves the
    /// circuit breaker armed and lets the caller surface the alert.
    private func coordinatorRetryBorrow(
        book: TPPBook,
        attemptDownload: Bool,
        coordinator: AuthCoordinator,
        reason: ReauthReason,
        authLabel: String
    ) async {
        let outcome = await coordinator.refreshCredentialsIfNeeded(reason: reason)
        switch outcome {
        case .success:
            guard self.userAccountProvider().hasCredentials() else {
                Log.info(#file, "\(authLabel) coordinator refresh reported success but credentials missing — not retrying borrow for '\(book.title)'")
                Self.clearBorrowReauthAttempted(for: book.identifier)
                return
            }
            Log.info(#file, "\(authLabel) coordinator refresh succeeded, retrying borrow for '\(book.title)'")
            Self.clearBorrowReauthAttempted(for: book.identifier)
            Task { [weak self] in
                do {
                    _ = try await self?.borrowAsync(book, attemptDownload: attemptDownload)
                } catch {
                    Log.error(#file, "Retry borrow failed after \(authLabel) coordinator refresh: \(error.localizedDescription)")
                }
            }
        case .failure(let cancellation):
            Log.info(#file, "\(authLabel) coordinator declined refresh for '\(book.title)' — \(cancellation)")
            // Per-book circuit-breaker contract: keep the breaker armed on
            // `.userCancelled` / `.refreshAlreadyFailed` so the same book
            // doesn't re-prompt the user on a subsequent borrow tap. The
            // user explicitly said no (or the coordinator is in cooldown
            // from a recent failure) — re-prompting on the next tap is
            // exactly the loop the per-book breaker exists to prevent.
            // Only clear on programming-error cancellations so a future
            // tap can attempt fresh dispatch once the underlying problem
            // (e.g., no active account) resolves.
            switch cancellation {
            case .userCancelled, .refreshAlreadyFailed:
                // Keep breaker armed — book stays gated until retry button
                // (explicit user action) clears or account-switch resets.
                break
            case .noActiveAccount, .unsupportedAuthenticationType:
                Self.clearBorrowReauthAttempted(for: book.identifier)
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

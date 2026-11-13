//
//  BorrowOperation.swift
//  Palace
//
//  The borrow lifecycle: Adobe activation, the borrow fetch, response
//  evaluation (PP-4178 Loan→Hold race), registry update, and the failure
//  tail. `BorrowReducerCore` decides the success and failure plans; this
//  type runs them (retries, OIDC silent reauth, coordinator, sign-in modal).
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
import PalaceDownloads

// MARK: - Delegate

/// Callbacks the borrow operation hands back into MBDC's public
/// surface: `startDownload` for the auto-attempt-download success
/// path and `startBorrow` for the retry button in the error alert.
protocol BorrowOperationDelegate: AnyObject {
    @MainActor func startDownload(for book: TPPBook, withRequest initedRequest: URLRequest?)
    func startBorrow(for book: TPPBook, attemptDownload: Bool, borrowCompletion: (() -> Void)?)
}

// MARK: - BorrowOperation

/// - Sendable invariant: every stored dependency is a `let` bound at init. The
///   only mutable member is `weak var delegate`, assigned once during
///   `MyBooksDownloadCenter` construction (weak reads are atomic).
///   Circuit-breaker state lives in the lock-backed `static let reauthTracker`
///   and test-only retry handles in `retryRecorder` (see
///   BorrowOperation+ReauthBreaker.swift).
///   `@unchecked` because the delegate existential and the shared service
///   types are not themselves `Sendable`.
final class BorrowOperation: @unchecked Sendable {

    weak var delegate: BorrowOperationDelegate?

    /// Test-only record of sign-in-modal retries; see `BorrowRetryRecorder`.
    let retryRecorder = BorrowRetryRecorder()

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
    /// `TPPAlertUtils.alertWithDetails(...)` + `presentFromViewControllerOrNil`,
    /// which carries the "View Error Details" report (PP-3439).
    /// Tests stub to assert the path was hit without UIKit.
    private let presentBorrowErrorAlert: BorrowErrorAlertPresenting

    /// Reports the same failure on `downloadErrorPublisher`. Production wraps
    /// `DownloadProgressReporter.publishAndAnnounceError`. A failed borrow never
    /// reaches the registry, so this is the only signal that lets
    /// `BookDetailViewModel` leave the optimistic `.downloading` state
    /// `startDownloadAfterAuth` wrote (PP-5407). Published with
    /// `presentsAlert: false` because the alert above is already on screen.
    private let publishBorrowError: @MainActor (DownloadErrorInfo) -> Void

    /// Presents the sign-in modal. Production wraps
    /// `SignInModalPresenter.presentSignInModalForCurrentAccount(completion:)`.
    private let presentSignInModal: @MainActor (@escaping () -> Void) -> Void

    /// Attempts OIDC silent reauth via ASWebAuthenticationSession.
    /// Production handles the whole web-session dance; tests return
    /// a deterministic Bool.
    private let attemptOIDCReauth: () async -> Bool

    /// Auth-refresh coordinator. When non-nil, the SAML / generic browser
    /// sign-in in the failure plan routes through it instead of
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
        presentBorrowErrorAlert: @escaping BorrowErrorAlertPresenting,
        publishBorrowError: @escaping @MainActor (DownloadErrorInfo) -> Void,
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
        self.publishBorrowError = publishBorrowError
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
        presentBorrowErrorAlert: @escaping BorrowErrorAlertPresenting,
        publishBorrowError: @escaping @MainActor (DownloadErrorInfo) -> Void,
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
        self.publishBorrowError = publishBorrowError
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

        } catch {
            await clearProcessingState()
            return try await routeBorrowFailure(error, for: book, attemptDownload: attemptDownload)
        }
    }

    // MARK: - Failure Routing

    /// What a failure effect needs from the failed borrow.
    private struct BorrowFailure {
        let error: PalaceError
        let originalError: Error
        let problemDocument: TPPProblemDocument?
        let userAccount: TPPUserAccount
        let registeredState: TPPBookState
        let authTypeName: String
    }

    /// Runs the plan `BorrowReducerCore.failureEffects` decides, in order.
    /// Returns the book when a reauth retry borrowed it; otherwise throws the
    /// failure as a `PalaceError`.
    private func routeBorrowFailure(_ thrown: Error, for book: TPPBook, attemptDownload: Bool) async throws -> TPPBook {
        // A `PalaceError` reaches the alert without the thrown error or a
        // problem document. Classification still reads its NSError code, so a
        // 401 with no problem document still routes to reauth.
        let error: PalaceError
        let problemDocument: TPPProblemDocument?
        let includesOriginalError: Bool
        if let palaceError = thrown as? PalaceError {
            error = palaceError
            problemDocument = nil
            includesOriginalError = false
        } else {
            problemDocument = (thrown as NSError).problemDocument
            error = PalaceError.from(thrown)
            includesOriginalError = true
        }

        let userAccount = userAccountProvider()
        let authDef = userAccount.authDefinition
        let hasCredentials = userAccount.hasCredentials()
        let authKind = Self.failureAuthKind(authDef)

        let authError = BorrowReducerCore.authErrorReason(
            errorCase: Self.failureErrorCase(error),
            problemDocument: problemDocument.map {
                BorrowReducerCore.FailureProblemDocument(type: $0.type, isRecoverableAuthError: $0.isRecoverableAuthError)
            },
            isBrowserBased: authKind.isBrowserBased,
            hasCredentials: hasCredentials,
            nsErrorCode: (thrown as NSError).code
        )
        switch authError {
        case .recoverableProblemDocument:
            Log.info(#file, "Recoverable auth error detected: \(problemDocument?.type ?? "unknown") — triggering re-auth (PP-3716)")
        case .browserNoActiveLoan:
            Log.info(#file, "Browser-based auth (SAML/OIDC/OAuth): 'no-active-loan' with active credentials — treating as auth error (PP-3716)")
        default:
            break
        }

        let registeredState = bookRegistry.state(for: book.identifier)
        let plan = BorrowReducerCore.failureEffects(
            authError: authError,
            problemDocumentType: problemDocument?.type,
            registeredState: registeredState,
            hasCredentials: hasCredentials,
            reauthAlreadyAttempted: Self.hasBorrowReauthBeenAttempted(for: book.identifier),
            authKind: authKind,
            hasAuthCoordinator: authCoordinator != nil,
            includesOriginalError: includesOriginalError
        )

        let failure = BorrowFailure(
            error: error,
            originalError: thrown,
            problemDocument: problemDocument,
            userAccount: userAccount,
            registeredState: registeredState,
            authTypeName: authDef?.authType.rawValue ?? "unknown"
        )
        for effect in plan {
            if let borrowed = await runFailureEffect(effect, failure: failure, book: book, attemptDownload: attemptDownload) {
                return borrowed
            }
        }
        throw error
    }

    /// Runs one failure effect. Returns the book when a retry borrowed it.
    private func runFailureEffect(
        _ effect: BorrowReducerCore.FailureEffect,
        failure: BorrowFailure,
        book: TPPBook,
        attemptDownload: Bool
    ) async -> TPPBook? {
        switch effect {
        case .suppressAndReclearProcessing:
            Log.warn(#file, "[SQ-007] Borrow auth-error suppressed for '\(book.title)' — book is already in registry with state \(failure.registeredState) and credentials are present. Treating as benign auto-re-borrow failure, not a credentials problem.")
            await MainActor.run {
                self.bookRegistry.setProcessing(false, for: book.identifier)
            }

        case .showBorrowError(let includesOriginalError):
            let error = failure.error
            let originalError = includesOriginalError ? failure.originalError : nil
            let problemDocument = includesOriginalError ? failure.problemDocument : nil
            await MainActor.run {
                self.showBorrowError(error, originalError: originalError, for: book, problemDocument: problemDocument)
            }

        case .reauthBreakerTripped:
            Log.warn(#file, "Borrow re-auth already attempted for '\(book.title)' - showing error instead")

        case .markReauthAttempted:
            Log.info(#file, "Borrow failed with auth error for '\(book.title)' - attempting re-authentication")
            Self.markBorrowReauthAttempted(for: book.identifier)

        case .markCredentialsStale:
            failure.userAccount.markCredentialsStale()

        case .oidcSilentReauth(let fallback):
            Log.info(#file, "OIDC session expired during borrow - attempting silent re-auth via ASWebAuthenticationSession")
            guard await attemptOIDCReauth() else {
                // The IdP session needs an interactive sign-in, same as SAML.
                Log.info(#file, "OIDC silent re-auth failed/cancelled - falling back to sign-in modal")
                return await runFailureEffect(fallback, failure: failure, book: book, attemptDownload: attemptDownload)
            }
            Log.info(#file, "OIDC silent re-auth succeeded, retrying borrow for '\(book.title)'")
            // One awaited retry with the breaker still armed: a second failure
            // shows an error rather than re-authenticating again (PP-5359).
            do {
                return try await borrowAsync(book, attemptDownload: attemptDownload)
            } catch {
                Log.error(#file, "Retry borrow failed after OIDC re-auth: \(error.localizedDescription)")
            }

        case .coordinatorRefresh(let reason, let authLabel):
            guard let coordinator = authCoordinator else { return nil }
            return await coordinatorRetryBorrow(
                book: book,
                attemptDownload: attemptDownload,
                coordinator: coordinator,
                reason: reason,
                authLabel: authLabel
            )

        case .presentSignInModal(let authLabel, let requiresSignedIn):
            await presentSignInModalAndRetryBorrow(book: book, attemptDownload: attemptDownload,
                                                   authLabel: authLabel, requiresSignedIn: requiresSignedIn)

        case .noAutomaticRecovery:
            Log.warn(#file, "Auth error for \(failure.authTypeName) auth type - no automatic recovery")
        }
        return nil
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
            // Retry is the patron's own request, so it may sign in again.
            Self.clearBorrowReauthAttempted(for: book.identifier)
            self.delegate?.startBorrow(for: book, attemptDownload: true, borrowCompletion: nil)
        } : nil

        presentBorrowErrorAlert(title, message, originalError as NSError?, problemDoc, book, retryAction)
        // Then the resync signal. `presentsAlert: false` — the alert above is
        // the one the patron sees; this only unsticks the half-sheet.
        publishBorrowError(DownloadErrorInfo(bookId: book.identifier, title: title, message: message,
                                            kind: .borrow, retryAction: retryAction, presentsAlert: false))
    }

    // MARK: - Coordinator-Routed Retry

    /// Asks the coordinator to refresh credentials (it dispatches the
    /// appropriate modal flow per IdP); on success retries the borrow once,
    /// awaited, with the per-book circuit breaker still armed, and returns
    /// the book if that retry borrowed it. A failed retry shows its own error.
    private func coordinatorRetryBorrow(
        book: TPPBook,
        attemptDownload: Bool,
        coordinator: AuthCoordinator,
        reason: ReauthReason,
        authLabel: String
    ) async -> TPPBook? {
        let outcome = await coordinator.refreshCredentialsIfNeeded(reason: reason)
        switch outcome {
        case .success:
            guard self.userAccountProvider().hasCredentials() else {
                Log.info(#file, "\(authLabel) coordinator refresh reported success but credentials missing — not retrying borrow for '\(book.title)'")
                Self.clearBorrowReauthAttempted(for: book.identifier)
                return nil
            }
            Log.info(#file, "\(authLabel) coordinator refresh succeeded, retrying borrow for '\(book.title)'")
            // Retry once with the breaker still armed: if the retry fails
            // again it shows an error instead of signing in again. Clearing it
            // here let an identity provider with a live session re-prompt and
            // retry without end (PP-5359). A successful borrow clears it.
            do {
                return try await self.borrowAsync(book, attemptDownload: attemptDownload)
            } catch {
                Log.error(#file, "Retry borrow failed after \(authLabel) coordinator refresh: \(error.localizedDescription)")
                return nil
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
                // Keep breaker armed — book stays gated until the alert's
                // Retry (explicit user action), a successful borrow or an
                // account switch clears it.
                break
            case .noActiveAccount, .unsupportedAuthenticationType:
                Self.clearBorrowReauthAttempted(for: book.identifier)
            }
            return nil
        }
    }

    // MARK: - Sign-In Modal Retry

    /// Presents the sign-in modal and retries the borrow on success.
    /// Used by the SAML, OIDC and barcode/PIN paths.
    /// - Parameter requiresSignedIn: retry only if the account ended signed
    ///   in, not merely holding credentials.
    private func presentSignInModalAndRetryBorrow(book: TPPBook, attemptDownload: Bool, authLabel: String,
                                                  requiresSignedIn: Bool = false) async {
        await MainActor.run { [weak self] in
            guard let self = self else { return }
            self.presentSignInModal { [weak self] in
                guard let self else { return }

                let account = self.userAccountProvider()
                let signedIn = account.hasCredentials()
                    && (!requiresSignedIn || account.authState == .loggedIn)
                guard signedIn else {
                    Log.info(#file, "\(authLabel) re-auth cancelled or failed, not retrying borrow for '\(book.title)'")
                    Self.clearBorrowReauthAttempted(for: book.identifier)
                    return
                }

                Log.info(#file, "\(authLabel) re-auth completed, retrying borrow for '\(book.title)'")
                // Breaker stays armed for the retry (PP-5359).
                self.retainRetryForTesting(Task { [weak self] in
                    do {
                        _ = try await self?.borrowAsync(book, attemptDownload: attemptDownload)
                    } catch {
                        Log.error(#file, "Retry borrow failed after \(authLabel) re-auth: \(error.localizedDescription)")
                    }
                })
            }
        }
    }
}

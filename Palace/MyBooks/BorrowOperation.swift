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
import PalaceAuth
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
///   MUST NOT show the alert (the toast would be a false credentials
///   warning) AND MUST ensure the cell spinner is cleared idempotently
///   (defends against any path that bypasses `clearProcessingState`).
/// - `showGenericError`: not an auth error OR auth recovery isn't
///   available — caller proceeds with the standard `showBorrowError`
///   alert path.
///
/// Internal-only by design — we explicitly do NOT expand the public
/// surface here; the enum threads the decision out of an existing
/// `private` helper into its existing `private` caller in the same file.
private enum BorrowAuthErrorDecision {
    case routeToReauth
    case suppressAndClearSpinner
    case showGenericError
}

// MARK: - BorrowOperation

/// - Sendable invariant: every stored dependency is a `let` bound at init
///   (`bookRegistry`, `downloadAnnouncementService`, `errorActivityTracker`,
///   `debugSettings`, `userRetryTracker`, `userAccountProvider`,
///   `adobeDRMService`, the four closure-injected seams, `authCoordinator`) —
///   the same already-shared services this flow drives today under Swift-5
///   mode from `Task` / `MainActor.run` closures. The only mutable instance
///   member is `weak var delegate`, assigned exactly once during owner
///   (`MyBooksDownloadCenter`) construction and never reassigned; weak-reference
///   reads and ARC zeroing are atomic in the Swift runtime, so no explicit lock
///   is required. Circuit-breaker state lives in the `static let reauthTracker`
///   (`ReauthTracker`), a lock-backed `@unchecked Sendable` holder. `@unchecked` (rather than a
///   synthesized conformance) because `delegate`'s protocol existential and the
///   shared service types are not themselves `Sendable`; this conformance
///   asserts the serialization contract above and does not change runtime
///   behavior — it only formalizes how the flow already executes.
final class BorrowOperation: @unchecked Sendable {

    weak var delegate: BorrowOperationDelegate?

    // MARK: - Borrow Re-auth Circuit Breaker

    /// Tracks whether we've already attempted re-authentication for a
    /// borrow operation. Prevents infinite re-auth loops for persistent
    /// auth failures. Shared across BorrowOperation instances so
    /// account-switch state can be cleared centrally.
    ///
    /// Lock-backed holder rather than a `static var` + sibling `NSLock`:
    /// under Swift 6 `complete`-mode a mutable static is nonisolated global
    /// shared mutable state (a warning even when a paired lock guards every
    /// access, because the compiler can't see the pairing). Wrapping the set
    /// and its lock in one `@unchecked Sendable` holder makes the serialization
    /// contract explicit and the storage a single immutable `let`. Behavior is
    /// identical to the previous lock/defer accessors.
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

    /// Maps a book returned from a Borrow/Place-Hold request to the
    /// resulting registry state and any error that should be surfaced.
    ///
    /// Both buttons share `borrowAsync`, but the same OPDS response carries
    /// different meaning depending on what the user tapped:
    ///
    /// - Place Hold (pre availability == `unavailable`) → an
    ///   `unavailable`/`reserved` response is the expected queue placement,
    ///   NOT a failure. (PP-4178 follow-up — pre-fix, the alert was a false
    ///   positive for any Place Hold tap on a no-copies title.)
    /// - Borrow (pre availability is loan-class:
    ///   `limited`/`unlimited`/`ready`/`reserved`) → an `unavailable`/`reserved`
    ///   response means CM lost the Loan→Hold race and the loan was
    ///   downgraded to a hold. Surface the alert.
    ///
    /// Backward-compat: when `preBorrowBook` is nil, retains the original
    /// behavior (treat `unavailable`/`reserved` as race losses) for
    /// callers that don't have pre-borrow context.
    /// Race an async operation against a deadline. Whichever finishes first
    /// wins; the other is cancelled. On deadline expiry, throws
    /// `PalaceError.network(.timeout)` so the upstream catch block surfaces
    /// the standard borrow-error alert with a Retry option (instead of the
    /// half-sheet hanging on `isBorrowProcessing = true` indefinitely).
    /// F-014.
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

    /// E2 (WS7): the availability→state + Loan→Hold race logic now lives in the
    /// pure `BorrowReducerCore.responseState`. This static is retained as the
    /// stable entry point for external callers (`MyBooksDownloadCenter+Async`,
    /// the MBDC forwarder, and their tests) and simply delegates.
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

    /// swarm_66819d80 Module C: auth-refresh coordinator. When non-nil,
    /// the SAML / generic browser sign-in modal dispatch inside
    /// `handleBorrowAuthErrorIfNeeded` routes through the coordinator's
    /// single seam instead of presenting the modal via the closure-injected
    /// `presentSignInModal`. The per-book circuit breaker
    /// (`hasBorrowReauthBeenAttempted`) STAYS — the coordinator is
    /// process-wide single-flight, NOT per-book, so the per-book guard
    /// is still required to prevent runaway retries for a specific book.
    /// The static `attemptOIDCSilentReauth` helper also stays — only its
    /// trigger routes through the coordinator's fallback on failure.
    /// Optional so existing tests keep compiling without rework.
    private let authCoordinator: AuthCoordinator?

    /// Fire-and-forget side effect run once a borrow SUCCEEDS — the app-rating
    /// secondary trigger (PP-4088). Injected so the critical borrow path holds
    /// no hidden `AppContainer.production()` reach: production wires this to
    /// `AppContainer.production().ratingPromptPresenter.noteBorrowSucceeded()`
    /// (see `MyBooksDownloadCenter`); tests inject a recording/no-op closure so
    /// the success path is deterministic and does not build the full DI graph on
    /// the MainActor (which deadlocked the @MainActor contract tests). Defaults
    /// to a no-op so non-production construction sites need no change.
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

        // ensure Adobe DRM device activation before proceeding.
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
            // F-014: wrap fetchBook in an explicit 30s timeout. URLSession's
            // default `timeoutIntervalForRequest` is 60s — but in practice
            // we've observed CM/distributor connections sitting open for 120s+
            // when the server hangs the request mid-flight (e.g. staging
            // backpressure, slow LCP license fetch). Without an explicit
            // ceiling, isBorrowProcessing stays true and the half-sheet
            // shows Cancel-only with no recoverable error — the
            // BUG_FINDINGS_2026_05_12 "borrow stuck with Cancel-only UI"
            // bug. 30s is comfortably above a healthy borrow (median ~1.5s)
            // and below the URLSession default, so the user gets a clean
            // PalaceError.network(.timeout) → showBorrowError → "try again"
            // alert instead of an indefinite spinner.
            let borrowedBook = try await Self.withTimeout(seconds: 30) {
                try await self.fetchBook(acquisitionURL, true, true)
            }

            await clearProcessingState()

            let location = self.bookRegistry.location(forIdentifier: borrowedBook.identifier)
            // follow-up: pass `book` (pre-borrow) so the helper can
            // tell Place Hold success apart from a CM Loan→Hold race loss.
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
                    // App-rating secondary trigger (PP-4088). Injected seam
                    // instead of a direct `AppContainer.production()` reach; run
                    // sequentially (not fire-and-forget) so the emitted effect
                    // order is deterministic relative to `startDownload`.
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

            // Pass the PalaceError itself as `originalError` so the predicate
            // can also inspect `.network(.unauthorized)` / `.network(.forbidden)`
            // surfacing from a 401-with-no-problem-doc throw path that arrives
            // here instead of the second catch block (item #7 fix).
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
                // SQ-007: the book is already in the registry with active
                // credentials. Skip the misleading alert AND idempotently
                // re-clear setProcessing — `clearProcessingState` above
                // already cleared it, but bookRegistry implementations
                // (e.g. the cell-driven mock used in some UI plumbing
                // paths) may have flipped it back from a notification
                // dispatch between then and now. Cheap defense.
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
    /// caller should follow. See `BorrowAuthErrorDecision` for the
    /// three cases. Old return contract (`Bool`) coalesced the
    /// SQ-007 suppression with the "not an auth error at all" path,
    /// which sent the patron through a misleading credentials alert
    /// when the auto-re-borrow ran but wasn't needed.
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

            // Item #7: a 401 surfacing as `.network(.unauthorized)` /
            // `.network(.forbidden)` (e.g. from an OPDS path that strips
            // the problem doc) must route to re-auth instead of falling
            // through to a generic "unknown network error" alert.
            // Drives 35k+ "Network request failed (912)" non-fatals.
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

        // Broadened from `(isSaml || isOidc)` to `isBrowserBased` by
        // swarm_66819d80 so OAuth-intermediary (Clever) follows the same
        // browser-reauth recovery path as SAML/OIDC. Pinned by
        // `BorrowOperationCleverReauthTests`.
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
                    // swarm_66819d80 Module C: OIDC fallback routes through
                    // coordinator when wired (modal flow is identical to
                    // SAML at this point — IdP session needs interactive
                    // re-establishment). Per Option A, only the FAILURE
                    // path routes through the coordinator.
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
                // swarm_66819d80 Module C: SAML / OAuth-intermediary
                // browser flow routes through coordinator when wired.
                // Coordinator dispatches modal (always for SAML/OAuth-
                // intermediary per its routing matrix).
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

                // F-016: defer the session start so any prior SignInModalHostingController
                // (or the previous SFAuthenticationViewController) has time to finish
                // deallocating. Without this, calling session.start() while a previous
                // auth modal is still in its dealloc cycle produces the runtime warning
                // "Attempting to load the view of a view controller while it is
                // deallocating" and iOS cancels the new session with
                // ASWebAuthenticationSession error 3 ("presentation cancelled by user").
                // The cancellation leaves the user with still-stale credentials and the
                // borrow retry 401s again — driving a re-auth loop until the per-book
                // circuit breaker (hasBorrowReauthBeenAttempted) fires.
                //
                // 150ms is empirically enough for the UIKit dealloc + RunLoop drain on
                // current iOS releases; we keep it explicit (not Task.yield) so the
                // timing semantics survive a reader future Swift Concurrency rev.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    session.start()
                }
            }
        }
    }

    // MARK: - Coordinator-Routed Retry

    /// swarm_66819d80 Module C: coordinator-routed reauth-then-retry.
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

/// Provides a window anchor for `ASWebAuthenticationSession` in the
/// borrow flow's OIDC silent reauth path.
private final class OIDCBorrowPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = OIDCBorrowPresentationContext()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.mainKeyWindow ?? ASPresentationAnchor()
    }
}

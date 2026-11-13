//
//  DownloadAuthRetryHandler.swift
//  Palace
//
//  Download-failure auth/retry orchestration: 401-style session expiry,
//  no-active-loan re-borrow, and SAML / OIDC / token-refresh reauth.
//  `handleAuthFailureIfApplicable` returns `true` when it claimed the failure
//  (cleanup queued, sign-in or borrow retry started) so the caller skips the
//  default alert. Entry points are @MainActor to keep main-thread sequencing.
//

import Foundation
import PalaceAuth
import PalaceCatalog
import PalaceLogging
import PalaceBookModel
import PalaceBookRegistry

// MARK: - DownloadAuthRetryHandlerDelegate

/// Surface MBDC needs to expose so the handler can re-attempt the
/// download after a successful re-auth, or trigger an auto-borrow
/// after a stale `no-active-loan` failure.
protocol DownloadAuthRetryHandlerDelegate: AnyObject {
    func startDownload(for book: TPPBook, withRequest request: URLRequest?)
    func startBorrow(for book: TPPBook, attemptDownload: Bool, borrowCompletion: (() -> Void)?)
}

/// Re-reads a book's catalog entry.
///
/// A catalog entry's acquisition links are not scoped to a loan, so it is the
/// one place a usable borrow link survives after a loan ends. Injected as a
/// closure so a test can supply an entry without standing up the feed service,
/// and so the retry path depends on the capability rather than on OPDS.
typealias CatalogEntryFetcher = @Sendable (TPPBook) async -> TPPBook?

// MARK: - DownloadAuthRetryHandler

/// Decides whether a download-completion failure should trigger
/// re-authentication, an auto-borrow, or be passed back to the caller
/// as a regular alert. Holds no state of its own — every decision is a
/// fresh read of the current TPPUserAccount.
///
/// `@unchecked Sendable` because the `@Sendable` retry/clean-up Tasks capture
/// it `[weak self]`. Every stored property is immutable after init or
/// main-actor-confined: `delegate` is set once on the main actor after
/// construction and reached through `self` (never captured directly); the
/// non-Sendable `let`s are only touched on the main actor; `inFlightTasks` is
/// `@MainActor`. `final`, so a subclass cannot break the assertion.
final class DownloadAuthRetryHandler: @unchecked Sendable {

    weak var delegate: DownloadAuthRetryHandlerDelegate?

    private let stateManager: DownloadStateManager
    private let bookRegistry: TPPBookRegistryProvider
    private let reauthenticator: Reauthenticator
    private let alertPresenter: DownloadAlertPresenter

    /// Auth-refresh coordinator. When non-nil, the SAML / OIDC / generic
    /// browser branches of `handleAuthFailureIfApplicable` route through it.
    /// Per-book state transitions (`.SAMLStarted`, `.downloadNeeded`) and the
    /// `startDownload` retry stay here; the coordinator only owns credential
    /// refresh.
    private let authCoordinator: AuthCoordinator?

    /// Resolves the current user account on each call, so a library switch
    /// mid-flow is observed.
    private let userAccountProvider: () -> TPPUserAccount

    /// Foreign-host guard provider — see `AuthErrorClassifier.currentAccountHostsProvider`
    /// (PR #1018 cross-host logout). Returns the lowercased hosts of the
    /// current account's auth surface; a failure from any other host
    /// short-circuits before marking credentials stale or dispatching the
    /// coordinator. `nil` disables the guard.
    private let currentAccountHostsProvider: (@Sendable () -> Set<String>?)?
    private let catalogEntryFetcher: CatalogEntryFetcher?
    private let now: @Sendable () -> Date

    /// When each book's `no-active-loan` was last treated as a browser-session
    /// expiry.
    ///
    /// Browser auth cannot tell a timed-out session from a loan that ended: the
    /// server answers 400 for both, which is why PP-3716 assumes the session.
    /// The catalog cannot settle it either — an entry advertises a borrow link
    /// for a book that IS on loan (PP-5400, `TPPBook.mergingMetadataOnly`). So
    /// this asks the server again rather than inferring: re-authenticate and
    /// retry as before, and if 400 comes back with fresh credentials the loan
    /// itself has ended and the re-borrow applies (PP-5397).
    @MainActor private var sessionExpiryAttempts: [String: Date] = [:]

    /// How long a dispatched session-expiry retry and the failure that answers
    /// it count as one episode: one download round trip. Past it a failure is a
    /// new episode and gets the session-expiry treatment again, so a book that
    /// recovered once is not later read as a lapsed loan.
    private static let sessionExpiryEpisodeWindow: TimeInterval = 120

    /// Whether an episode recorded at `recorded` is still open at `reference`.
    ///
    /// One definition for the gate and for pruning, which ask the same question
    /// about different reference points. Two copies of the comparison meant the
    /// pruning boundary had no test of its own.
    private static func isEpisodeOpen(recorded: Date, at reference: Date) -> Bool {
        reference.timeIntervalSince(recorded) < sessionExpiryEpisodeWindow
    }

    /// Whether the no-active-loan retry can re-read a book's catalog entry
    /// before borrowing. False leaves it retrying the stored book, which is the
    /// dead-link path PP-5397 describes, so a test asserts production wires it.
    var canReReadCatalogEntry: Bool { catalogEntryFetcher != nil }

    /// Retained handles for the reauth-dispatch Tasks, so
    /// `cancelAllInFlightTasks()` can drop them instead of letting them write
    /// into the registry after the owning context is gone. Tasks remove
    /// themselves when their body finishes.
    ///
    /// Keyed by a per-launch `UUID` captured by value; capturing a launch-site
    /// `var task: Task!` is rejected by Swift 6 concurrency checking.
    @MainActor private var inFlightTasks: [UUID: Task<Void, Never>] = [:]

    init(
        stateManager: DownloadStateManager,
        bookRegistry: TPPBookRegistryProvider,
        reauthenticator: Reauthenticator,
        alertPresenter: DownloadAlertPresenter,
        userAccountProvider: @escaping () -> TPPUserAccount,
        authCoordinator: AuthCoordinator? = nil,
        currentAccountHostsProvider: (@Sendable () -> Set<String>?)? = nil,
        catalogEntryFetcher: CatalogEntryFetcher? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.stateManager = stateManager
        self.bookRegistry = bookRegistry
        self.reauthenticator = reauthenticator
        self.alertPresenter = alertPresenter
        self.userAccountProvider = userAccountProvider
        self.authCoordinator = authCoordinator
        self.currentAccountHostsProvider = currentAccountHostsProvider
        self.catalogEntryFetcher = catalogEntryFetcher
        self.now = now
    }

    deinit {
        // Nonisolated deinit cannot read the `@MainActor` `inFlightTasks`.
        // `cancelAllInFlightTasks()` is the cancellation seam; the
        // `[weak self]` guard in each Task body covers deinit.
    }

    // MARK: - Task lifecycle

    /// Cancels every retained in-flight Task and clears the tracking
    /// set. Call from any reset / sign-out / library-switch path that
    /// wants to abandon pending re-auth retries without waiting for
    /// them. Tasks check `Task.isCancelled` at every `await` hop so
    /// already-started Tasks unwind without re-entering the main actor
    /// after cancellation.
    @MainActor
    func cancelAllInFlightTasks() {
        for task in inFlightTasks.values {
            task.cancel()
        }
        inFlightTasks.removeAll()
    }

    /// Test/audit hook: number of retained Tasks currently in flight.
    /// Internal because the count is part of the cancellation contract
    /// (a test verifies the set is populated when a retry path runs and
    /// drained once it completes).
    @MainActor
    var inFlightTaskCount: Int { inFlightTasks.count }

    /// Launches a Task retained in `inFlightTasks` until its body returns.
    @MainActor
    @discardableResult
    private func launchTrackedTask(
        _ body: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        let id = UUID()
        let task = Task { [weak self] in
            await body()
            await MainActor.run { [weak self] in
                self?.inFlightTasks.removeValue(forKey: id)
            }
        }
        inFlightTasks[id] = task
        return task
    }

    /// Schedules a post-auth retry as a tracked main-actor Task, so
    /// `cancelAllInFlightTasks()` can drop it. Called from reauthenticator
    /// completions, which fire on an arbitrary queue.
    @MainActor
    private func scheduleRetainedRetry(
        _ body: @escaping @MainActor (DownloadAuthRetryHandler) -> Void
    ) {
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            if Task.isCancelled { return }
            body(self)
            self.inFlightTasks.removeValue(forKey: id)
        }
        inFlightTasks[id] = task
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

        // Foreign-host guard (PR #1018 cross-host logout). A 401 from a host
        // outside the current account's auth surface is never an expiry of
        // this account's session. The base-domain `isSameDomain` check in
        // `indicatesAuthenticationNeedsRefresh` misses this because libraries
        // can share `palaceproject.io`. A nil/empty host set (cold launch)
        // skips the guard.
        if httpResponse?.statusCode == 401,
           let host = originalURL?.host?.lowercased(),
           let hosts = currentAccountHostsProvider?(),
           !hosts.isEmpty,
           !hosts.contains(host) {
            Log.info(#file, "Foreign-host 401 from \(host) (current account hosts: \(hosts.sorted())) — not our account's session; skipping mark-stale + coordinator dispatch")
            return false
        }

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
            // A second failure inside the same episode answers a retry that was
            // dispatched after a completed re-authentication, so the session is
            // not what is missing — the loan is, and the re-borrow path applies
            // (PP-5397).
            //
            // `hasCredentials` stays true through `markCredentialsStale`, which
            // flips `authState` but keeps the credentials so the Adobe
            // activation survives. Were it ever state-based, the earlier
            // no-credentials branch would claim the failure first and this gate
            // would stop being reached — a silent no-op rather than a failure.
            let withinEpisode = sessionExpiryAttempts[book.identifier]
                .map { Self.isEpisodeOpen(recorded: $0, at: now()) } ?? false
            if reauthStrategy == .browser && hasCredentials && !withinEpisode {
                userAccount.markCredentialsStale()
                handleNoActiveLoanAsSessionExpiry(book: book, task: task, isSaml: userAccount.authDefinition?.isSaml == true)
                return true
            }

            // Consumed, so a later genuine expiry for this book is treated as
            // one rather than as another lapsed loan.
            sessionExpiryAttempts[book.identifier] = nil
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
        // The coordinator picks the mechanism for the active library; the
        // per-book state transition and download restart stay here.
        if let coordinator = self.authCoordinator {
            let reason: ReauthReason = isSaml ? .samlSessionExpired : .invalidCredentials
            launchTrackedTask { [weak self] in
                guard let self else { return }
                await self.cleanupTrackingState(book: book, task: task)
                if Task.isCancelled { return }
                let outcome = await coordinator.refreshCredentialsIfNeeded(reason: reason)
                if Task.isCancelled { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if isSaml {
                        self.bookRegistry.setState(.SAMLStarted, for: book.identifier)
                    } else {
                        self.bookRegistry.setState(.downloadNeeded, for: book.identifier)
                    }
                    switch outcome {
                    case .success:
                        Log.info(#file, "Coordinator refresh succeeded — retrying download for \(book.identifier)")
                        self.delegate?.startDownload(for: book, withRequest: nil)
                    case .failure(let cancellation):
                        Log.info(#file, "Coordinator declined to refresh for \(book.identifier) — \(cancellation)")
                    }
                }
            }
            return
        }

        if isSaml {
            // SAML cookies expired - need to re-auth via IDP
            Log.info(#file, "SAML session expired - triggering SAML re-auth flow")

            launchTrackedTask { [weak self] in
                guard let self else { return }
                await self.cleanupTrackingState(book: book, task: task)
                if Task.isCancelled { return }
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

            launchTrackedTask { [weak self] in
                guard let self else { return }
                await self.cleanupTrackingState(book: book, task: task)
                if Task.isCancelled { return }
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
        // Same routing as handleBrowserSessionExpired.
        if let coordinator = self.authCoordinator {
            let reason: ReauthReason = isSaml ? .samlSessionExpired : .invalidCredentials
            launchTrackedTask { [weak self] in
                guard let self else { return }
                await self.cleanupTrackingState(book: book, task: task)
                if Task.isCancelled { return }
                let outcome = await coordinator.refreshCredentialsIfNeeded(reason: reason)
                if Task.isCancelled { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    if isSaml {
                        self.bookRegistry.setState(.SAMLStarted, for: book.identifier)
                    } else {
                        self.bookRegistry.setState(.downloadNeeded, for: book.identifier)
                    }
                    switch outcome {
                    case .success:
                        Log.info(#file, "Coordinator refresh succeeded for no-active-loan path — retrying download for \(book.identifier)")
                        self.noteSessionExpiryRetryDispatched(for: book)
                        self.delegate?.startDownload(for: book, withRequest: nil)
                    case .failure(let cancellation):
                        Log.info(#file, "Coordinator declined to refresh for no-active-loan path on \(book.identifier) — \(cancellation)")
                    }
                }
            }
            return
        }

        if isSaml {
            Log.info(#file, "SAML: 'no-active-loan' treating as session expiry (PP-3716)")
            launchTrackedTask { [weak self] in
                guard let self else { return }
                await self.cleanupTrackingState(book: book, task: task)
                if Task.isCancelled { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.bookRegistry.setState(.SAMLStarted, for: book.identifier)
                    Log.info(#file, "SAML: Cleared failed download, retrying with SAML re-auth for \(book.identifier)")
                    self.noteSessionExpiryRetryDispatched(for: book)
                    self.delegate?.startDownload(for: book, withRequest: nil)
                }
            }
        } else {
            Log.info(#file, "Browser auth: 'no-active-loan' treating as session expiry")
            launchTrackedTask { [weak self] in
                guard let self else { return }
                await self.cleanupTrackingState(book: book, task: task)
                if Task.isCancelled { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.bookRegistry.setState(.downloadNeeded, for: book.identifier)
                    self.reauthenticate(retryWithFreshAuthState: book) { [weak self] in
                        self?.noteSessionExpiryRetryDispatched(for: book)
                    }
                }
            }
        }
    }

    /// Records that a session-expiry retry has been dispatched for `book`.
    ///
    /// Written here rather than where the expiry is first detected, because the
    /// two differ in both directions. A patron who dismisses sign-in has not
    /// re-authenticated, and recording at detection would turn their next
    /// attempt into a borrow they backed out of. And the interval the window
    /// bounds would otherwise contain the whole re-authentication — a web
    /// sheet, an identity provider, possibly a second factor, none of which
    /// this code bounds — so a sign-in slower than the window would loop on
    /// session expiry and never reach the re-borrow.
    ///
    /// Measured from the dispatched retry, the interval is one download round
    /// trip, which is what the window was chosen to cover.
    ///
    /// Two of the three callers follow a completed re-authentication: the
    /// coordinator's success arm and `reauthenticate`'s completion. The SAML
    /// arm records where the SAML flow begins instead, because that flow has no
    /// completion to wait for here. Production always takes the coordinator
    /// arm, which `AppContainer` supplies non-optionally.
    @MainActor
    private func noteSessionExpiryRetryDispatched(for book: TPPBook) {
        // Drop lapsed entries so a book that recovered on its retry does not
        // keep one for the handler's lifetime.
        let at = now()
        sessionExpiryAttempts = sessionExpiryAttempts.filter {
            Self.isEpisodeOpen(recorded: $0.value, at: at)
        }
        sessionExpiryAttempts[book.identifier] = at
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

        // The stored acquisitions are fulfillment links scoped to the loan that
        // just ended, which is why the download got 400 no-active-loan.
        // Borrowing with the same book sends `defaultAcquisition` — that same
        // dead link — so the retry failed identically and every tap for the next
        // few seconds with it (PP-5397). Re-read the catalog entry first, whose
        // links are not loan-scoped.
        guard let catalogEntryFetcher, book.alternateURL != nil else {
            startAutoBorrow(of: book, problemDoc: problemDoc, failureError: failureError)
            return
        }
        launchTrackedTask { [weak self] in
            guard let self else { return }
            let refreshed = await catalogEntryFetcher(book)
            if Task.isCancelled { return }
            let toBorrow = refreshed.map { Self.reborrowBook(stored: book, catalogEntry: $0) } ?? book
            if refreshed == nil {
                // Offline, or a feed that errored. Retrying the stored book is
                // no better than before this change, but it is no worse, and
                // giving up would cost the patron the attempt entirely.
                Log.warn(#file, "Could not re-read the catalog entry for \(book.identifier); retrying with the stored book")
            }
            await MainActor.run { [weak self] in
                self?.startAutoBorrow(of: toBorrow, problemDoc: problemDoc, failureError: failureError)
            }
        }
    }

    /// Builds the book the no-active-loan retry borrows with: the catalog
    /// entry's acquisition links, carried on the availability the patron was
    /// acting on.
    ///
    /// Taking the entry's links is the point — the stored ones are scoped to the
    /// loan that ended. Its availability must stay out, because
    /// `BorrowReducerCore.responseState` reads the pre-borrow book's
    /// availability to tell a deliberate Place Hold from a borrow the
    /// circulation manager downgraded to a hold (PP-4178). The entry reads
    /// `unavailable` whenever someone took the copy after the loan ended, and
    /// that reading would pass as place-hold intent and silence the alert. The
    /// patron reached this path from Download, so the loan-era availability is
    /// the faithful record of what they acted on, and keeping it leaves the
    /// discriminator deciding exactly what it decided before the re-read.
    ///
    /// Both guards below hold that neutrality. A stored book with no supported
    /// acquisition has no reading to carry over, and `preBorrowWasUnavailable`
    /// answers `false` for it — so taking the entry whole there would hand the
    /// discriminator the catalog's `unavailable` and silence the alert in the
    /// one case this function cannot speak for.
    static func reborrowBook(stored: TPPBook, catalogEntry: TPPBook) -> TPPBook {
        // A lean entry that carries no acquisition we support cannot improve the
        // retry, and the merge takes the entry's acquisitions wholesale — an
        // empty list would leave the borrow with no link at all, which is worse
        // than the dead one. This reads relation and type only; `availability`
        // is not consulted, so it cannot become a pre-filter on copies.
        guard catalogEntry.defaultAcquisition != nil else { return stored }
        let merged = stored.mergingPreservingMetadata(from: catalogEntry)
        guard let actedOn = stored.defaultAcquisition?.availability else { return stored }
        merged.acquisitions = merged.acquisitions.map { acquisition in
            TPPOPDSAcquisition(
                relation: acquisition.relation,
                type: acquisition.type,
                hrefURL: acquisition.hrefURL,
                indirectAcquisitions: acquisition.indirectAcquisitions,
                availability: actedOn,
                // Named rather than defaulted: the 5-argument convenience init
                // passes nil, so a copy made with it loses the vendor and would
                // keep losing fields as they are added.
                licensorVendor: acquisition.licensorVendor
            )
        }
        return merged
    }

    private func startAutoBorrow(of book: TPPBook, problemDoc: TPPProblemDocument, failureError: Error?) {
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
                // Reauthenticator completion fires on an arbitrary
                // queue. Hop to MainActor first — only there can we
                // retain the retry Task in `inFlightTasks`.
                //
                // no-track: this hop Task is fire-and-forget by design.
                // It owns no async work beyond awaiting MainActor and
                // immediately delegating to `scheduleRetainedRetry`,
                // which IS tracked. Tracking the hop itself would race
                // with its own MainActor entry.
                Task { @MainActor [weak self] in
                    self?.scheduleRetainedRetry { strongSelf in
                        let userAccount = strongSelf.userAccountProvider()
                        // Only retry if user successfully authenticated; if they cancelled, bail out
                        guard userAccount.hasCredentials() else {
                            Log.info(#file, "Authentication cancelled, not retrying download for \(book.identifier)")
                            return
                        }
                        Log.info(#file, "Authentication completed, retrying download for \(book.identifier)")
                        strongSelf.delegate?.startDownload(for: book, withRequest: nil)
                    }
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
    private func reauthenticate(
        retryWithFreshAuthState book: TPPBook,
        onRetryDispatched: (@MainActor () -> Void)? = nil
    ) {
        let userAccount = userAccountProvider()
        reauthenticator.authenticateIfNeeded(
            userAccount,
            usingExistingCredentials: false,
            authenticationCompletion: { [weak self] in
                // no-track: see presentSignInModal for the same pattern.
                // Hop Task is uninstrumented by design; the retry body
                // it schedules via `scheduleRetainedRetry` IS tracked.
                Task { @MainActor [weak self] in
                    self?.scheduleRetainedRetry { strongSelf in
                        let userAccount = strongSelf.userAccountProvider()
                        guard userAccount.authState == .loggedIn else {
                            Log.info(#file, "Re-auth cancelled or incomplete, not retrying download for \(book.identifier)")
                            return
                        }
                        Log.info(#file, "Re-auth completed, retrying download for \(book.identifier)")
                        onRetryDispatched?()
                        strongSelf.delegate?.startDownload(for: book, withRequest: nil)
                    }
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

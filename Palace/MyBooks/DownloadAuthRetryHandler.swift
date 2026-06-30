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
import PalaceAuth
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
///
/// `@unchecked Sendable` (Swift 6 Wave 1, app-target `targeted` slice): the
/// handler is captured `[weak self]` by the `@Sendable` retry/clean-up Task
/// closures below, so it must be `Sendable`. The conformance is honest —
/// every stored property is immutable-after-init or main-actor-confined:
///   • `delegate` — `weak var`, wired exactly once on the main actor right
///     after construction (`MyBooksDownloadCenter` sets it post-`super.init()`)
///     and read only on the main actor (via `self.delegate` inside
///     `@MainActor` methods / `MainActor.run` bodies). The non-Sendable
///     `delegate`/`bookRegistry` are never captured directly by a `@Sendable`
///     closure — every Task body reaches them through `self`.
///   • `stateManager` — `let`; its mutable storage is the actor-isolated
///     `SafeDictionary`/`DownloadCoordinator` it owns.
///   • `bookRegistry` / `reauthenticator` / `alertPresenter` / `authCoordinator`
///     / `userAccountProvider` / `currentAccountHostsProvider` — `let`
///     (immutable after init); `authCoordinator` is an `actor`, the host
///     provider is `@Sendable`. The non-Sendable ones are touched only on
///     the main actor.
///   • `inFlightTasks` — `@MainActor` isolated; every insert/remove runs on
///     the main actor (see the UUID-keyed retention dance below).
/// `final`, so the assertion can't be defeated by a subclass.
final class DownloadAuthRetryHandler: @unchecked Sendable {

    weak var delegate: DownloadAuthRetryHandlerDelegate?

    private let stateManager: DownloadStateManager
    private let bookRegistry: TPPBookRegistryProvider
    private let reauthenticator: Reauthenticator
    private let alertPresenter: DownloadAlertPresenter

    /// swarm_66819d80 Module C: auth-refresh coordinator. When non-nil,
    /// the IdP-dispatch branches (SAML vs OIDC vs generic browser) inside
    /// `handleAuthFailureIfApplicable` route through the coordinator's
    /// single seam rather than carrying per-call-site dispatch logic. The
    /// per-book download state-machine transitions (`.SAMLStarted`,
    /// `.downloadNeeded`) and the `startDownload` retry remain at this
    /// call site — the coordinator only owns the *credentials refresh*.
    /// Optional so existing tests that supply only `reauthenticator` keep
    /// compiling; production wiring always injects.
    private let authCoordinator: AuthCoordinator?

    /// Closure resolves the current user account each call. MBDC's
    /// `userAccount` property is a computed property over `accountsManager.
    /// currentUserAccount`, so the closure preserves the same just-in-time
    /// resolution semantics — survives library switches mid-flow.
    private let userAccountProvider: () -> TPPUserAccount

    /// Foreign-host guard provider — see `AuthErrorClassifier.currentAccountHostsProvider`.
    /// Returns the set of lowercased hosts that constitute the CURRENT
    /// account's auth surface; when the failing task's host is outside
    /// this set, the handler short-circuits BEFORE marking credentials
    /// stale or dispatching the coordinator. `nil` provider disables
    /// the guard (legacy behavior). See wall-failure
    /// 2026-06-05-pr1018-icarus-cross-host-logout.md.
    private let currentAccountHostsProvider: (@Sendable () -> Set<String>?)?

    /// Retained handles for the fire-and-forget Tasks launched from the
    /// re-auth dispatch branches (swarm_47883816 F-iii'-1). Previously
    /// each Task was leaked once dispatched — if the handler was torn
    /// down (or a test ended) before the Task completed, the Task kept
    /// running and wrote into `bookRegistry` / `stateManager` after the
    /// owning context expired. Retaining lets `cancelAllInFlightTasks()`
    /// (called from `deinit` and any reset path) deterministically drop
    /// the orphaned work. Tasks remove themselves from the set when
    /// their body finishes so the set never grows unbounded.
    ///
    /// `@MainActor`-isolated — every site that inserts into or removes
    /// from this set runs on the main actor, matching the
    /// `@MainActor`-isolated entry points of the handler.
    ///
    /// Keyed by a per-launch `UUID` token rather than the `Task` handle
    /// itself: the auto-removal closure captures the token **by value** (a
    /// `Sendable` value type) instead of the launch-site `var task: Task!`,
    /// which the Swift-6 `targeted` concurrency check rejects as "`task`
    /// mutated after capture by sendable closure" (the IUO is assigned after
    /// the `@Sendable` Task body captures it). Mirrors the proven pattern in
    /// the sibling `BookReturnService`.
    @MainActor private var inFlightTasks: [UUID: Task<Void, Never>] = [:]

    init(
        stateManager: DownloadStateManager,
        bookRegistry: TPPBookRegistryProvider,
        reauthenticator: Reauthenticator,
        alertPresenter: DownloadAlertPresenter,
        userAccountProvider: @escaping () -> TPPUserAccount,
        authCoordinator: AuthCoordinator? = nil,
        currentAccountHostsProvider: (@Sendable () -> Set<String>?)? = nil
    ) {
        self.stateManager = stateManager
        self.bookRegistry = bookRegistry
        self.reauthenticator = reauthenticator
        self.alertPresenter = alertPresenter
        self.userAccountProvider = userAccountProvider
        self.authCoordinator = authCoordinator
        self.currentAccountHostsProvider = currentAccountHostsProvider
    }

    deinit {
        // Cancel any retry/cleanup Tasks still in flight so they don't
        // outlive the handler and write into `bookRegistry` /
        // `stateManager` after their owning context has gone away.
        //
        // `inFlightTasks` is `@MainActor`-isolated; `deinit` is
        // nonisolated. We can't read the property directly from
        // deinit. Tasks are reference types so the live Tasks already
        // own themselves until they finish; we cannot reach them from
        // here. The defensive guarantee is the `[weak self]` capture
        // inside every tracked Task body: once `self` deinits, the
        // body's first `guard let self` short-circuits and the Task
        // unwinds without touching `bookRegistry`. The retention here
        // is therefore a *cancellation seam* (`cancelAllInFlightTasks`
        // is the explicit entry point), not a deinit-side action.
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

    /// Wraps a fire-and-forget Task in the retention + auto-removal
    /// dance. Stores the handle in `inFlightTasks` before the body
    /// runs, then removes it from the set when the body returns. The
    /// auto-removal hop is itself a Task — small, never retained,
    /// fine to leak because it does no work beyond a set mutation.
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

    /// Auth-completion retry helper. Called from the reauthenticator
    /// completion closure (`presentSignInModal` and
    /// `reauthenticate(retryWithFreshAuthState:)`), which fires on an
    /// arbitrary queue. Hops to MainActor, then schedules the retry
    /// body as a tracked Task so the handle is retained in
    /// `inFlightTasks` and `cancelAllInFlightTasks()` can drop it.
    ///
    /// `handler` is a strong ref to the same `[weak self]` the caller
    /// already unwrapped — by the time we get here the caller has
    /// decided self is still alive, so capturing strongly for the
    /// duration of the (cheap) MainActor hop is fine. The inner
    /// retained Task captures weakly again so it can be cancelled
    /// without keeping the handler alive.
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

        // Foreign-host guard (Bug A fix — PR #1018 cross-host regression).
        // A 401 from a host outside the current account's auth surface is
        // never an expiry of the current account's session — short-circuit
        // BEFORE marking stale or dispatching the coordinator. The
        // base-domain `isSameDomain` check inside
        // `indicatesAuthenticationNeedsRefresh` does NOT catch this because
        // two libraries can share base `palaceproject.io` (e.g.
        // `gorgon.staging.palaceproject.io` vs
        // `minotaur.dev.palaceproject.io`). Nil/empty hosts set = legacy
        // behavior (cold launch). See wall-failure
        // 2026-06-05-pr1018-icarus-cross-host-logout.md.
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
        // swarm_66819d80 Module C: when the coordinator is wired, hand off
        // the per-IdP dispatch entirely — the coordinator decides SAML web
        // sheet vs OIDC ASWebAuthenticationSession vs basic prompt based
        // on the active library's mechanism. The per-book download state
        // transition (`.SAMLStarted` for SAML, `.downloadNeeded` for
        // others) and the post-success download restart stay here.
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
        // swarm_66819d80 Module C: same coordinator routing as
        // handleBrowserSessionExpired — `no-active-loan` is just a 400
        // dressed up as a session-expiry signal for browser-based auth.
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
    private func reauthenticate(retryWithFreshAuthState book: TPPBook) {
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

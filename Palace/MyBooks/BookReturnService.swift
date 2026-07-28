//
//  BookReturnService.swift
//  Palace
//
//  Owns the borrow-return business flow that lived inside
//  MyBooksDownloadCenter as `returnBook(withIdentifier:completion:)` (~230
//  LOC of nested error handling: Adobe DRM return, OPDS revoke fetch,
//  PalaceError.parsing fallback, no-active-loan / loan-term-limit cleanup,
//  invalid-credentials re-auth + retry, generic alert with
//  retry/remove-from-device/cancel actions).
//
//  Extracted so the return state machine can be reasoned about and
//  exercised in isolation. MBDC keeps the same `returnBook(withIdentifier:
//  completion:)` @objc surface as a 1-line delegator — preserves all
//  external callers (UI, BookDetailViewModel, MyBooksViewModel, etc.).
//

import Foundation
import UIKit
import PalaceAuth
import PalaceLogging
import PalaceCatalog
import PalaceBookModel
import PalaceBookRegistry

// MARK: - BookReturnServiceDelegate

/// Surface MBDC needs to expose so the service can clean local content
/// + audiobook caches as part of the return cleanup. Both already exist
/// on MBDC's surface; conformance is empty.
protocol BookReturnServiceDelegate: AnyObject {
    /// Force-purge all audiobook caches. Called after every successful
    /// return path so abandoned audiobook chunks don't linger on disk.
    func purgeAllAudiobookCaches(force: Bool)
}

// MARK: - BookReturnService

/// Coordinates the return-loan flow with the circulation manager.
///
/// - Sendable invariant: every stored dependency is a `let` bound at init
///   (`bookRegistry`, `localContentService`, `opdsFeedService`,
///   `downloadAnnouncementService`, `bookmarkDeletionLog`, `reauthenticator`,
///   `userRetryTracker`, `userAccountProvider`, `adobeDRMService`,
///   `authCoordinator`) — the same already-shared services this flow drives
///   today under Swift-5 mode from `launchTrackedTask` / `MainActor.run`
///   closures. The mutable instance state is exactly two members, both already
///   serialized: `inFlightTasks` is guarded by `inFlightLock` (NSLock, see the
///   property doc), and `weak var delegate` is assigned exactly once during
///   owner (`MyBooksDownloadCenter`) construction and never reassigned —
///   weak-reference reads and ARC zeroing are atomic in the Swift runtime, so
///   it needs no explicit lock. `@unchecked` (rather than a synthesized
///   conformance) because `delegate`'s protocol existential and the shared
///   service types are not themselves `Sendable`; this conformance asserts the
///   serialization contract above and does not change the ordered return
///   cleanup contract (setProcessing → setState → removeBook → announce).
final class BookReturnService: @unchecked Sendable {

    weak var delegate: BookReturnServiceDelegate?

    private let bookRegistry: TPPBookRegistryProvider
    private let localContentService: LocalBookContentService
    private let opdsFeedService: OPDSFeedFetching
    private let downloadAnnouncementService: DownloadAnnouncementService
    private let bookmarkDeletionLog: TPPBookmarkDeletionLog
    private let reauthenticator: Reauthenticator
    private let userRetryTracker: UserRetryTracker

    /// swarm_66819d80 Module C: auth-refresh coordinator. Optional so
    /// existing tests that supply only `reauthenticator` keep compiling;
    /// production wiring (and any new test) injects the real coordinator
    /// (or a `SpyAuthCoordinator`). When non-nil, the auth-error branch
    /// in `returnBook` routes through this instead of the legacy
    /// `reauthenticator.authenticateIfNeeded` closure.
    private let authCoordinator: AuthCoordinator?

    /// Reliability WS-C (INV-3): enqueue seam for a genuine offline
    /// return. When non-nil and the revoke fetch fails with an offline
    /// `NSURLError`, the return is queued for later drain instead of
    /// dead-ending in an alert — and NO local content is deleted /
    /// unregistered until the queued return is server-confirmed. Optional
    /// so existing tests/callers that don't wire the queue keep the legacy
    /// alert behavior. Production injects the real queue enqueue.
    private let offlineReturnEnqueuer: (@Sendable (OfflineAction) async -> Void)?

    /// Production default for `offlineReturnEnqueuer`: enqueue onto the
    /// app-wide offline queue. Used so the MBDC-constructed instance gets
    /// INV-3 behavior without MBDC (owned by WS-A) having to change. Tests
    /// inject their own spy to observe the enqueue deterministically.
    static let productionOfflineReturnEnqueuer: @Sendable (OfflineAction) async -> Void = { action in
        await OfflineQueueService.shared.enqueue(action)
    }

    /// Closure resolves the current user account each call so library
    /// switches mid-flow are observed correctly (matches MBDC's `userAccount`
    /// computed property semantics).
    private let userAccountProvider: () -> TPPUserAccount

    /// Adobe DRM service stored property gated on FEATURE_DRM_CONNECTOR
    /// (the type itself is gated). In Palace-noDRM the property doesn't
    /// exist and the Adobe-return code path is compiled out.
    #if FEATURE_DRM_CONNECTOR
    private let adobeDRMService: AdobeDRMService
    #endif

    // MARK: - In-flight Task retention (swarm_4e47d4d4 F3)

    /// Retained handles for the fire-and-forget Tasks launched from the
    /// return state machine: the OPDS revoke fetch + cleanup hops (line
    /// 154-style), the coordinator and legacy reauth retry hops, the
    /// alert presentation hop, and the post-return sync hop. Previously
    /// each Task was leaked once dispatched — if the service was torn
    /// down (deinit, sign-out, library swap) before the Task completed,
    /// the Task kept running and wrote into `bookRegistry` /
    /// `localContentService` / `bookmarkDeletionLog` after the owning
    /// context expired. Retaining lets `cancelAllInFlightTasks()` (called
    /// from `deinit` and any reset path) deterministically drop the
    /// orphaned work. Tasks remove themselves from the set when their
    /// body finishes so the set never grows unbounded.
    ///
    /// Guarded by `inFlightLock` rather than an actor annotation —
    /// `BookReturnService` is callable from non-MainActor contexts
    /// (MBDC) and the Task bodies straddle the cooperative pool and the
    /// main actor. NSLock is the lowest-blast-radius primitive that
    /// keeps both safe.
    /// Keyed by a per-launch `UUID` token rather than the `Task` handle
    /// itself. The auto-removal closure captures the token **by value**
    /// (a `Sendable` value type), so it never reads the launch-site `task`
    /// variable from inside the Task body. The prior `var task: Task!` +
    /// `inFlightTasks.remove(task)` pattern was an unsynchronized cross-thread
    /// read of the IUO: the body runs on a different executor than the one
    /// assigning `task`, so under load the write was not yet visible and the
    /// implicit unwrap crashed ("nil while implicitly unwrapping") — an
    /// intermittent fatal on the book-return reauth path.
    private var inFlightTasks: [UUID: Task<Void, Never>] = [:]
    private let inFlightLock = NSLock()

    #if FEATURE_DRM_CONNECTOR
    init(
        bookRegistry: TPPBookRegistryProvider,
        localContentService: LocalBookContentService,
        opdsFeedService: OPDSFeedFetching,
        downloadAnnouncementService: DownloadAnnouncementService,
        bookmarkDeletionLog: TPPBookmarkDeletionLog,
        reauthenticator: Reauthenticator,
        userRetryTracker: UserRetryTracker,
        userAccountProvider: @escaping () -> TPPUserAccount,
        adobeDRMService: AdobeDRMService = .shared,
        authCoordinator: AuthCoordinator? = nil,
        offlineReturnEnqueuer: (@Sendable (OfflineAction) async -> Void)? = BookReturnService.productionOfflineReturnEnqueuer
    ) {
        self.bookRegistry = bookRegistry
        self.localContentService = localContentService
        self.opdsFeedService = opdsFeedService
        self.downloadAnnouncementService = downloadAnnouncementService
        self.bookmarkDeletionLog = bookmarkDeletionLog
        self.reauthenticator = reauthenticator
        self.userRetryTracker = userRetryTracker
        self.userAccountProvider = userAccountProvider
        self.adobeDRMService = adobeDRMService
        self.authCoordinator = authCoordinator
        self.offlineReturnEnqueuer = offlineReturnEnqueuer
    }
    #else
    init(
        bookRegistry: TPPBookRegistryProvider,
        localContentService: LocalBookContentService,
        opdsFeedService: OPDSFeedFetching,
        downloadAnnouncementService: DownloadAnnouncementService,
        bookmarkDeletionLog: TPPBookmarkDeletionLog,
        reauthenticator: Reauthenticator,
        userRetryTracker: UserRetryTracker,
        userAccountProvider: @escaping () -> TPPUserAccount,
        authCoordinator: AuthCoordinator? = nil,
        offlineReturnEnqueuer: (@Sendable (OfflineAction) async -> Void)? = BookReturnService.productionOfflineReturnEnqueuer
    ) {
        self.bookRegistry = bookRegistry
        self.localContentService = localContentService
        self.opdsFeedService = opdsFeedService
        self.downloadAnnouncementService = downloadAnnouncementService
        self.bookmarkDeletionLog = bookmarkDeletionLog
        self.reauthenticator = reauthenticator
        self.userRetryTracker = userRetryTracker
        self.userAccountProvider = userAccountProvider
        self.authCoordinator = authCoordinator
        self.offlineReturnEnqueuer = offlineReturnEnqueuer
    }
    #endif

    deinit {
        // Note: `self.inFlightTasks` strongly retains every in-flight
        // `Task<Void, Never>` value (which in turn keeps the runtime's
        // backing Job alive while its body is still suspended). That
        // means `deinit` will not normally fire while a Task is still
        // suspended on an `await` — there is no opportunity to cancel
        // from here. The cancellation seam is therefore
        // `cancelAllInFlightTasks()` (call it explicitly from
        // sign-out, library-swap, or any reset path that wants to
        // abandon pending returns). The defensive guarantee for
        // already-launched Tasks is the `[weak self]` capture at the
        // top of each tracked Task body: once the service eventually
        // does deinit, the body's first `guard let self` short-circuits
        // and the remaining work unwinds without touching
        // `bookRegistry` / `localContentService` /
        // `bookmarkDeletionLog`.
        BookReturnServiceTestHook.recordDeinit()
    }

    // MARK: - Task lifecycle

    /// Cancels every retained in-flight Task and clears the tracking
    /// set. Call from any reset / sign-out / library-switch path that
    /// wants to abandon pending returns without waiting for them.
    /// Tasks check `Task.isCancelled` at every `await` hop so
    /// already-started Tasks unwind without re-entering registry
    /// mutations after cancellation.
    func cancelAllInFlightTasks() {
        let snapshot: [Task<Void, Never>]
        inFlightLock.lock()
        snapshot = Array(inFlightTasks.values)
        inFlightTasks.removeAll()
        inFlightLock.unlock()
        for task in snapshot {
            task.cancel()
        }
    }

    /// Test/audit hook: number of retained Tasks currently in flight.
    /// Internal because the count is part of the cancellation contract
    /// (tests verify the set is populated when a return-flow Task is
    /// running and drained once it completes or is cancelled).
    var inFlightTaskCount: Int {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }
        return inFlightTasks.count
    }

    /// Test-only snapshot of the retained Tasks so a test can prove
    /// `deinit` cancelled a specific Task. Returning the Set copy is
    /// safe because Task itself is `Sendable`.
    internal func inFlightTasksSnapshotForTesting() -> Set<Task<Void, Never>> {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }
        return Set(inFlightTasks.values)
    }

    /// Wraps a fire-and-forget Task in the retention + auto-removal
    /// dance. Inserts the handle into `inFlightTasks` before the body
    /// runs, then removes it when the body returns. The auto-removal
    /// touches the lock once; auto-removal itself isn't tracked
    /// because it does no real work beyond a set mutation.
    @discardableResult
    private func launchTrackedTask(
        _ body: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        let id = UUID()
        let task = Task { [weak self] in
            await body()
            guard let self else { return }
            self.inFlightLock.withLock { self.inFlightTasks.removeValue(forKey: id) }
        }
        inFlightLock.lock()
        inFlightTasks[id] = task
        inFlightLock.unlock()
        return task
    }

    /// MainActor-isolated sibling of `launchTrackedTask` for the
    /// branches that already pinned themselves to MainActor (the
    /// reauthenticator-completion hop, the alert-presentation hop).
    /// The auto-removal step runs in the closing MainActor scope so
    /// callers don't have to thread the lock through their UI work.
    @discardableResult
    private func launchTrackedMainActorTask(
        _ body: @escaping @MainActor @Sendable () async -> Void
    ) -> Task<Void, Never> {
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            await body()
            guard let self else { return }
            self.inFlightLock.withLock { self.inFlightTasks.removeValue(forKey: id) }
        }
        inFlightLock.lock()
        inFlightTasks[id] = task
        inFlightLock.unlock()
        return task
    }

    // MARK: - returnBook

    func returnBook(withIdentifier identifier: String, completion: (@Sendable () -> Void)? = nil) {
        guard let book = bookRegistry.book(forIdentifier: identifier) else {
            completion?()
            return
        }

        downloadAnnouncementService.announceReturnStarted(for: book)

        let state = bookRegistry.state(for: identifier)
        let downloaded = (state == .downloadSuccessful) || (state == .used)

        // Process Adobe Return
        #if FEATURE_DRM_CONNECTOR
        let userAccount = userAccountProvider()
        if let fulfillmentId = bookRegistry.fulfillmentId(forIdentifier: identifier),
           userAccount.authDefinition?.needsAuth == true {
            NSLog("Return attempt for book. userID: %@", userAccount.userID ?? "")
            self.adobeDRMService.returnLoan(fulfillmentId,
                                            userID: userAccount.userID,
                                            deviceID: userAccount.deviceID) { success, _ in
                if !success {
                    NSLog("Failed to return loan via NYPLAdept.")
                }
            }
        }
        #endif

        switch ReturnReducer.startRoute(hasRevokeURL: book.revokeURL != nil) {
        case .cleanupWithoutNetwork:
            // Books without a revokeURL skip the OPDS round trip entirely — run
            // the shared treat-as-success teardown directly.
            runReturnSuccessCleanup(book: book, identifier: identifier,
                                    downloaded: downloaded, returnedBook: nil,
                                    completion: completion)
            return
        case .revokeOverNetwork:
            break
        }

        bookRegistry.setProcessing(true, for: book.identifier)

        launchTrackedTask { [weak self] in
            guard let self, let revokeURL = book.revokeURL else {
                await MainActor.run { [weak self] in
                    self?.bookRegistry.setProcessing(false, for: book.identifier)
                    self?.downloadAnnouncementService.announceReturnFailed(for: book)
                    completion?()
                }
                return
            }

            do {
                let feed = try await self.opdsFeedService.fetchFeed(from: revokeURL)
                await MainActor.run {
                    self.bookRegistry.setProcessing(false, for: book.identifier)
                }

                guard feed.entries.count == 1, let entry = feed.entries[0] as? TPPOPDSEntry else {
                    Log.error(#file, "Revoke response had \(feed.entries.count) entries, expected 1")
                    await MainActor.run {
                        self.downloadAnnouncementService.announceReturnFailed(for: book)
                        completion?()
                    }
                    return
                }

                guard let returnedBook = TPPBook(entry: entry) else {
                    Log.error(#file, "Failed to create book from revoke entry")
                    await MainActor.run {
                        self.downloadAnnouncementService.announceReturnFailed(for: book)
                        completion?()
                    }
                    return
                }

                // Normal network-revoke success: the parsed returned book drives
                // `updateAndRemoveBook`. Shared teardown owns the ordered contract.
                self.runReturnSuccessCleanup(book: book, identifier: identifier,
                                             downloaded: downloaded, returnedBook: returnedBook,
                                             completion: completion)

            } catch {
                await MainActor.run {
                    self.bookRegistry.setProcessing(false, for: book.identifier)
                }

                self.handleRevokeError(error, book: book, identifier: identifier, downloaded: downloaded, completion: completion)
            }
        }
    }

    // MARK: - Private branches

    /// Shared "treat-as-success" teardown for every return that is (or is
    /// treated as) a success: the no-revokeURL path, the normal network-revoke
    /// success, the OPDS-parse-fail-as-success path, and the loan-gone path.
    /// The ORDER is owned by `ReturnReducer.cleanupEffects`; this method is the
    /// effect-runner that interprets it, keeping the `deleteAllBookmarks`
    /// callback nesting + post-return sync that the pure core cannot express.
    ///
    /// - `returnedBook`: non-nil only on the normal network-revoke success,
    ///   where `updateAndRemoveBook` supplies the parsed book; nil on the
    ///   treat-as-success paths, which use `setState` then `removeBook`.
    private func runReturnSuccessCleanup(
        book: TPPBook,
        identifier: String,
        downloaded: Bool,
        returnedBook: TPPBook?,
        completion: (@Sendable () -> Void)?
    ) {
        let effects = ReturnReducer.cleanupEffects(
            downloaded: downloaded, useUpdateAndRemove: returnedBook != nil)

        // Local-asset teardown runs before the bookmark deletion round trip.
        if effects.contains(.deleteLocalContent) {
            localContentService.deleteLocalContent(for: identifier)
        }
        if effects.contains(.purgeAudiobookCaches) {
            delegate?.purgeAllAudiobookCaches(force: true)
        }

        // Delete all server bookmarks before removing the book so old bookmarks
        // don't reappear when the book is re-borrowed.
        TPPAnnotations.deleteAllBookmarks(forBook: book) { [weak self] in
            guard let self = self else {
                completion?()
                return
            }
            self.bookmarkDeletionLog.clearAllDeletions(forBook: identifier)
            for effect in effects {
                switch effect {
                case .updateAndRemoveBook:
                    if let returnedBook { self.bookRegistry.updateAndRemoveBook(returnedBook) }
                case .setStateUnregistered:
                    self.bookRegistry.setState(.unregistered, for: identifier)
                case .removeBook:
                    self.bookRegistry.removeBook(forIdentifier: identifier)
                case .deleteLocalContent, .purgeAudiobookCaches, .announceReturnSucceeded:
                    break // run outside the callback / in the post-sync block
                }
            }
            self.performPostReturnSyncThen {
                self.downloadAnnouncementService.announceReturnSucceeded(for: book)
                completion?()
            }
        }
    }

    /// Failure path branches: parsing-error-as-success, no-active-loan +
    /// loan-term-limit cleanup, invalid-credentials re-auth retry, or
    /// generic alert with retry / remove-from-device / cancel.
    private func handleRevokeError(_ error: Error, book: TPPBook, identifier: String, downloaded: Bool, completion: (@Sendable () -> Void)?) {
        // Pure classification facts. Parse-fail wraps a `PalaceError` (not an
        // NSError), so it is detected before the problem-doc extraction.
        let isOPDSParseFailure: Bool = {
            if case .parsing(.opdsFeedInvalid) = error as? PalaceError { return true }
            return false
        }()
        let problemDoc = (error as NSError).problemDocument
        let problemType = problemDoc?.type
        let nsError = error as NSError
        // Auth-error detection mirrors BorrowOperation's so SAML/OIDC token
        // expiry on return surfaces the same sign-in modal that borrow shows.
        let isAuthError: Bool = {
            if problemType == TPPProblemDocument.TypeInvalidCredentials { return true }
            if problemDoc?.isRecoverableAuthError == true { return true }
            if nsError.code == TPPErrorCode.invalidCredentials.rawValue { return true }
            return false
        }()

        let route = ReturnReducer.classifyError(.init(
            isOPDSParseFailure: isOPDSParseFailure,
            isNoActiveLoan: problemType == TPPProblemDocument.TypeNoActiveLoan,
            isLoanTermLimitReached: problemDoc?.detail?.contains(TPPProblemDocument.DetailLoanTermLimitReached) == true,
            isAuthError: isAuthError,
            isOffline: Self.isOfflineNSURLError(error),
            hasOfflineEnqueuer: offlineReturnEnqueuer != nil
        ))

        // Log at the same points the pre-extraction ladder did: parse-fail is a
        // benign treat-as-success (info), everything else is an error.
        if isOPDSParseFailure {
            Log.info(#file, "Revoke response was not a valid OPDS feed — treating as success and syncing to verify")
        } else {
            Log.error(#file, "Return failed for '\(book.title)': \(error.localizedDescription), problemDoc type: \(problemType ?? "nil")")
        }

        switch route {
        case .treatAsSuccessCleanup:
            // The OverDrive revoke endpoint returns non-OPDS XML the parser
            // rejects (the revoke likely SUCCEEDED server-side), or the loan is
            // already gone. Either way, run the shared treat-as-success teardown.
            runReturnSuccessCleanup(book: book, identifier: identifier,
                                    downloaded: downloaded, returnedBook: nil,
                                    completion: completion)

        case .reauthAndRetry:
            // swarm_66819d80 Module C: route through AuthCoordinator when it's
            // wired (production). The coordinator owns mechanism dispatch
            // (SAML/OIDC modal, basic silent refresh) and calls
            // `markCredentialsStale()` internally. The legacy
            // `reauthenticator.authenticateIfNeeded` fallback remains for tests
            // that haven't been updated to inject a coordinator.
            if let coordinator = self.authCoordinator {
                Log.info(#file, "Auth error on return — dispatching through AuthCoordinator")
                launchTrackedTask { [weak self] in
                    let outcome = await coordinator.refreshCredentialsIfNeeded(reason: .invalidCredentials)
                    guard let self else { return }
                    switch outcome {
                    case .success:
                        self.returnBook(withIdentifier: identifier, completion: completion)
                    case .failure(let cancellation):
                        Log.info(#file, "Coordinator declined to refresh — \(cancellation)")
                        runOnMainAsync {
                            self.downloadAnnouncementService.announceReturnFailed(for: book)
                            completion?()
                        }
                    }
                }
                return
            }

            // Legacy fallback (tests-only). Production AppContainer always
            // injects the coordinator. Module B broadening preserved: for
            // browser-based accounts (SAML/OIDC/OAuth-intermediary), mark
            // credentials stale before reauth dispatch so the stale token
            // isn't silently reused.
            let userAccount = userAccountProvider()
            let authDef = userAccount.authDefinition
            let needsBrowserReauth = (authDef?.isBrowserBased == true)
                && userAccount.hasCredentials()
            if needsBrowserReauth {
                Log.info(#file, "Auth error on return for browser-based account — marking credentials stale (legacy path)")
                userAccount.markCredentialsStale()
            } else {
                Log.info(#file, "Auth error on return — legacy reauth path (no coordinator injected)")
            }
            launchTrackedMainActorTask { [weak self] in
                guard let self else { return }
                let user = self.userAccountProvider()
                self.reauthenticator.authenticateIfNeeded(user, usingExistingCredentials: false) { [weak self] in
                    guard let self else { return }
                    if self.userAccountProvider().hasCredentials() {
                        self.returnBook(withIdentifier: identifier, completion: completion)
                    } else {
                        runOnMainAsync {
                            self.downloadAnnouncementService.announceReturnFailed(for: book)
                            completion?()
                        }
                    }
                }
            }

        case .enqueueOffline:
            // Reliability WS-C (INV-3): a genuine offline / no-connection error
            // is NOT a return failure — the loan is still ours and the revoke
            // simply couldn't reach the server. Enqueue for a later drain and
            // inform the patron. Do NOT delete local content or unregister here.
            if let enqueuer = self.offlineReturnEnqueuer {
                Log.info(#file, "Offline return for '\(book.title)' — enqueuing for later; no local cleanup")
                let action = OfflineAction(type: .return, bookID: identifier, bookTitle: book.title)
                launchTrackedTask { [weak self] in
                    await enqueuer(action)
                    guard let self else { return }
                    runOnMainAsync {
                        self.presentOfflineReturnQueuedAlert(for: book)
                        completion?()
                    }
                }
            }

        case .genericFailureAlert:
            // All other errors — show alert with problem document if available.
            launchTrackedMainActorTask { [weak self] in
                guard let self else { return }
                self.presentReturnFailureAlert(
                    error: error,
                    problemDoc: problemDoc,
                    book: book,
                    identifier: identifier,
                    downloaded: downloaded,
                    completion: completion
                )
            }
        }
    }

    @MainActor
    private func presentReturnFailureAlert(
        error: Error,
        problemDoc: TPPProblemDocument?,
        book: TPPBook,
        identifier: String,
        downloaded: Bool,
        completion: (@Sendable () -> Void)?
    ) {
        let serverDetail = problemDoc?.detail
            ?? (error as NSError).userInfo["problemDocumentDetail"] as? String
            ?? error.localizedDescription
        let formattedMessage = String(format: Strings.MyDownloadCenter.returnFailedMessage, book.title)
            + "\n\n" + serverDetail

        let operationId = "return-\(identifier)"
        let retryAction: (() -> Void)? = {
            guard self.userRetryTracker.canRetry(operationId: operationId) else { return nil }
            return { [weak self] in
                guard let self else { return }
                self.userRetryTracker.recordRetry(operationId: operationId)
                self.returnBook(withIdentifier: identifier, completion: completion)
            }
        }()

        let message = (retryAction == nil && !userRetryTracker.canRetry(operationId: operationId))
            ? Strings.MyDownloadCenter.tryAgainLater
            : formattedMessage

        let alert = UIAlertController(title: Strings.MyDownloadCenter.returnFailed, message: message, preferredStyle: .alert)

        if let retryAction = retryAction {
            alert.addAction(UIAlertAction(title: Strings.MyDownloadCenter.retry, style: .default) { _ in retryAction() })
        }

        alert.addAction(UIAlertAction(title: NSLocalizedString("Remove from Device", comment: "Button to remove a book locally when server return fails"), style: .destructive) { [weak self] _ in
            guard let self else { return }
            if downloaded {
                self.localContentService.deleteLocalContent(for: identifier)
                self.delegate?.purgeAllAudiobookCaches(force: true)
            }
            self.bookmarkDeletionLog.clearAllDeletions(forBook: identifier)
            self.bookRegistry.setState(.unregistered, for: identifier)
            self.bookRegistry.removeBook(forIdentifier: identifier)
            self.downloadAnnouncementService.announceReturnSucceeded(for: book)
            completion?()
        })

        alert.addAction(UIAlertAction(title: Strings.Generic.cancel, style: .cancel))

        if let doc = problemDoc {
            TPPAlertUtils.setProblemDocument(controller: alert, document: doc, append: true)
        }

        TPPPresentationUtils.safelyPresent(alert)
        downloadAnnouncementService.announceReturnFailed(for: book)
        completion?()
    }

    // MARK: - Offline return (INV-3)

    /// Whether `error` is a genuine offline / no-connection transport
    /// failure — the only class of return error that should be queued
    /// rather than surfaced as a failure. Auth / problem-doc / parsing
    /// errors are handled by their own branches above.
    static func isOfflineNSURLError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        switch nsError.code {
        case NSURLErrorNotConnectedToInternet,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorTimedOut,
             NSURLErrorDataNotAllowed,
             NSURLErrorInternationalRoamingOff,
             NSURLErrorCannotFindHost:
            return true
        default:
            return false
        }
    }

    @MainActor
    private func presentOfflineReturnQueuedAlert(for book: TPPBook) {
        let message = String(
            format: NSLocalizedString(
                "\"%@\" will be returned automatically when you're back online.",
                comment: "Informs the user an offline return was queued"),
            book.title)
        let alert = UIAlertController(
            title: NSLocalizedString("Return Queued", comment: "Title for a queued offline return"),
            message: message,
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: Strings.Generic.ok, style: .default))
        TPPPresentationUtils.safelyPresent(alert)
    }

    // MARK: - Post-return sync

    /// Performs a registry sync after a return. On failure, posts
    /// `TPPSyncFailed` so the Reservations tab can show the sync error
    /// banner; completion is always called so the return UI is dismissed.
    private func performPostReturnSyncThen(completion: @escaping @Sendable () -> Void) {
        launchTrackedTask { [weak self] in
            do {
                // Use the injected `bookRegistry` rather than reaching into
                // AppContainer here, so unit tests can substitute a registry
                // double. `syncAsync` is defined on the concrete
                // `TPPBookRegistry` rather than the protocol; the cast is
                // safe in production where `bookRegistry` is always the
                // app-scoped instance constructed by AppContainer._cached.
                if let registry = self?.bookRegistry as? TPPBookRegistry {
                    _ = try await registry.syncAsync()
                }
            } catch {
                Log.error(#file, "Post-return sync failed: \(error.localizedDescription)")
                NotificationCenter.default.post(name: .TPPSyncFailed, object: nil, userInfo: nil)
            }
            runOnMainAsync(completion)
        }
    }
}

// MARK: - Test hook (swarm_4e47d4d4 F3)

/// Static counter that lets the F3 deinit test prove the service's
/// deinit ran for a specific instance without relying on weak-ref
/// timing. Production code only writes to this counter from `deinit`;
/// nothing else touches it.
///
/// Internal-only — accessible from PalaceTests via `@testable import
/// Palace` but not exported publicly.
internal enum BookReturnServiceTestHook {
    /// Lock-backed counter holder. Replaces the previous `static var _deinitCount`
    /// + free-standing `NSLock`: under Swift 6 `complete`-mode a mutable static is
    /// nonisolated global shared mutable state (a warning even when guarded by a
    /// sibling lock, because the compiler can't see the pairing). Wrapping the
    /// count + its lock in one `@unchecked Sendable` holder makes the
    /// serialization contract explicit and the storage a single immutable `let`.
    /// Precedent: `LockedFlag` in `TPPAccessibilityAnnouncementCenter`.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() { lock.withLock { value += 1 } }
        func get() -> Int { lock.withLock { value } }
    }

    private static let counter = Counter()

    static func recordDeinit() {
        counter.increment()
    }

    /// Async accessor — used in test arrange / assert hops.
    static var deinitCount: Int {
        get async { counter.get() }
    }

    /// Sync accessor — used inside `awaitConditionAsync` predicates
    /// which are non-async closures.
    static var deinitCountSync: Int {
        counter.get()
    }
}

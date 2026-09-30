//
//  BookReturnService.swift
//  Palace
//
//  The loan-return flow: Adobe DRM return, OPDS revoke fetch, no-active-loan /
//  loan-term-limit cleanup, invalid-credentials reauth + retry, offline queueing,
//  and the retry/remove/cancel alert. MyBooksDownloadCenter's @objc
//  `returnBook(withIdentifier:completion:)` delegates here.
//

import Foundation
import UIKit
import PalaceAuth
import PalaceLogging
import PalaceCatalog
import PalaceBookModel
import PalaceBookRegistry
import PalaceUtilities

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
/// - Sendable invariant: every stored dependency is a `let` bound at init. The
///   only mutable state is `inFlightTasks` (guarded by `inFlightLock`) and
///   `weak var delegate` (assigned once during `MyBooksDownloadCenter`
///   construction; weak reads are atomic). `@unchecked` because the delegate
///   existential and the shared service types are not themselves `Sendable`.
final class BookReturnService: @unchecked Sendable {

    weak var delegate: BookReturnServiceDelegate?

    private let bookRegistry: TPPBookRegistryProvider
    private let localContentService: LocalBookContentService
    private let opdsFeedService: OPDSFeedFetching
    private let downloadAnnouncementService: DownloadAnnouncementService
    private let bookmarkDeletionLog: TPPBookmarkDeletionLog
    private let reauthenticator: Reauthenticator
    private let userRetryTracker: UserRetryTracker

    /// Auth-refresh coordinator. When non-nil, the auth-error branch in
    /// `returnBook` routes through it instead of
    /// `reauthenticator.authenticateIfNeeded`.
    private let authCoordinator: AuthCoordinator?

    /// Enqueue seam for a genuine offline return. When non-nil and the revoke
    /// fetch fails with an offline `NSURLError`, the return is queued instead
    /// of ending in an alert, and no local content is deleted or unregistered
    /// until the server confirms the queued return. nil keeps the alert.
    private let offlineReturnEnqueuer: (@Sendable (OfflineAction) async -> Void)?

    /// Production default for `offlineReturnEnqueuer`: the app-wide offline queue.
    static let productionOfflineReturnEnqueuer: @Sendable (OfflineAction) async -> Void = { action in
        await OfflineQueueService.shared.enqueue(action)
    }

    /// Closure resolves the current user account each call so library
    /// switches mid-flow are observed correctly (matches MBDC's `userAccount`
    /// computed property semantics).
    private let userAccountProvider: () -> TPPUserAccount

    /// Cancels any pending throttled remote listening-position write for a
    /// book. Called at the start of the return flow so a queued snapshot cannot
    /// flush after `deleteAllBookmarks` and restore the deleted server
    /// position. Production routes it to the audiobook session; defaults to a
    /// no-op.
    private let remotePositionWriteCanceller: @Sendable (String) -> Void

    /// Adobe DRM service stored property gated on FEATURE_DRM_CONNECTOR
    /// (the type itself is gated). In Palace-noDRM the property doesn't
    /// exist and the Adobe-return code path is compiled out.
    #if FEATURE_DRM_CONNECTOR
    private let adobeDRMService: AdobeDRMService
    #endif

    // MARK: - In-flight Task retention

    /// Retained handles for the Tasks the return flow launches, so
    /// `cancelAllInFlightTasks()` can drop them on sign-out / library switch
    /// instead of letting them write into the registry after the owning context
    /// is gone. Tasks remove themselves when their body finishes.
    ///
    /// Guarded by `inFlightLock` rather than an actor because callers are not
    /// main-actor and the Task bodies straddle the cooperative pool and the
    /// main actor. Keyed by a per-launch `UUID` captured by value: reading a
    /// launch-site `var task: Task!` from inside the body raced the assignment
    /// and crashed on the implicit unwrap.
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
        offlineReturnEnqueuer: (@Sendable (OfflineAction) async -> Void)? = BookReturnService.productionOfflineReturnEnqueuer,
        remotePositionWriteCanceller: @escaping @Sendable (String) -> Void = { _ in }
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
        self.remotePositionWriteCanceller = remotePositionWriteCanceller
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
        offlineReturnEnqueuer: (@Sendable (OfflineAction) async -> Void)? = BookReturnService.productionOfflineReturnEnqueuer,
        remotePositionWriteCanceller: @escaping @Sendable (String) -> Void = { _ in }
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
        self.remotePositionWriteCanceller = remotePositionWriteCanceller
    }
    #endif

    deinit {
        // No cancellation here: deinit cannot run while a retained Task is
        // suspended. `cancelAllInFlightTasks()` is the cancellation seam; the
        // `[weak self]` guard in each Task body covers a later deinit.
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

    /// Launches a Task retained in `inFlightTasks` until its body returns.
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

    /// MainActor-isolated sibling of `launchTrackedTask`.
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

        // Cancel any pending remote listening-position write before cleanup, so
        // a queued snapshot cannot flush after `deleteAllBookmarks` and restore
        // the server position on re-borrow. Every return sub-path passes here.
        remotePositionWriteCanceller(identifier)

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
                    // serverAuthoritative: every path into this method is a
                    // confirmed (or treat-as-confirmed) server outcome. The
                    // #18414 guard refuses a non-authoritative empty save over a
                    // non-empty shelf, so without this flag returning the only
                    // book on the shelf would leave it to reappear on relaunch.
                    // Not applied to "Remove from Device", where the server
                    // return failed and the removal must stay refusable.
                    if let returnedBook {
                        self.bookRegistry.updateAndRemoveBook(returnedBook, serverAuthoritative: true)
                    }
                case .setStateUnregistered:
                    self.bookRegistry.setState(.unregistered, for: identifier)
                case .removeBook:
                    // serverAuthoritative — see the `.updateAndRemoveBook` note above.
                    self.bookRegistry.removeBook(forIdentifier: identifier, serverAuthoritative: true)
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

        // Parse-fail is a benign treat-as-success (info); everything else is an error.
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
            // The coordinator (always wired in production) owns mechanism
            // dispatch and calls `markCredentialsStale()` itself.
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

            // Fallback when no coordinator is injected (tests). Browser-based
            // accounts mark credentials stale first so the stale token is not
            // reused.
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
            // Offline is not a return failure: the loan is still held. Enqueue
            // for a later drain and tell the patron; do not delete local content
            // or unregister here.
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
                // `syncAsync` exists only on the concrete `TPPBookRegistry`,
                // which production always injects; test doubles skip the sync.
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

// MARK: - Test hook

/// Deinit counter so a test can prove the service deinitialized without
/// relying on weak-ref timing. Production only writes to it from `deinit`.
internal enum BookReturnServiceTestHook {
    /// Count and lock in one `@unchecked Sendable` holder: a mutable static
    /// guarded by a sibling lock still warns under Swift 6 complete checking.
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

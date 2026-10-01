//
//  DownloadStartCoordinator.swift
//  Palace
//
//  Borrow/start entry points:
//    - `startBorrow`: runs `delegate.borrowAsync` and releases the coordinator
//      slot on a `.holding` result or a throw, or the queue stalls.
//    - `startDownloadAsync`: duplicate-start guard, state classification,
//      capacity check (enqueue at the cap), throttle delay, slot registration,
//      then the credential prompt or the per-state dispatcher.
//    - `startDownloadIfAvailable`: starts limited / unlimited / ready books.
//

import Foundation
import PalaceLogging
import PalaceBookModel
import PalaceBookRegistry

// MARK: - Delegate

/// Callbacks into MyBooksDownloadCenter. Other collaborators are passed at
/// init so this surface stays small.
protocol DownloadStartCoordinatorDelegate: AnyObject {
    func borrowAsync(_ book: TPPBook, attemptDownload: Bool) async throws -> TPPBook
    func schedulePendingStartsIfPossible()
}

// MARK: - DownloadStartCoordinator

/// Sendable carrier for the non-Sendable `borrowCompletion` closure captured by
/// the `Task` in `startBorrow`. Marking the closure `@Sendable` instead would
/// ripple onto every caller closure that mutates non-Sendable state.
/// Invariant: invoked at most once, inside the single `startBorrow` Task.
/// `internal` so tests can await `startBorrowAsync`.
final class BorrowCompletionBox: @unchecked Sendable {
    let call: (() -> Void)?
    init(_ call: (() -> Void)?) { self.call = call }
}

/// - Sendable invariant: every stored dependency is a `let` bound at init. The
///   only mutable member is `weak var delegate`, assigned once during
///   `MyBooksDownloadCenter` construction. Task bodies touch only the
///   actor-serialized `stateManager.downloadCoordinator` and the injected
///   closures; the account id is snapshotted at start so a library switch
///   cannot change it. `@unchecked` because the stored service types are not
///   `Sendable`.
final class DownloadStartCoordinator: @unchecked Sendable {

    weak var delegate: DownloadStartCoordinatorDelegate?

    private let stateManager: DownloadStateManager
    private let bookRegistry: TPPBookRegistryProvider

    /// True when an LCP `.lcpa` transfer is already running for this identifier.
    /// Wired post-init by `MyBooksDownloadCenter`; nil in contexts that never
    /// fulfil LCP content.
    ///
    /// `downloadInfo` and `state == .downloading` are NOT sufficient gates for the
    /// content phase: the former is cleared ~100 ms in, and a book whose content is
    /// being re-fetched in the background deliberately does not claim `.downloading`
    /// (that would offer a Cancel that cannot stop the transfer). Without this a
    /// patron tapping Download mid-transfer starts a second full archive fetch.
    var hasActiveLCPContentTransfer: ((String) -> Bool)?
    private let userAccountProvider: () -> TPPUserAccount
    /// Reads the "currently selected library UUID" at download-start time.
    /// Captured once into a let-binding at the top of
    /// `startDownloadAsync` so the rest of the path resolves credentials
    /// against the originally-selected account — closes the library-swap-
    /// mid-download window that produced spurious sign-in modals.
    private let currentAccountIdProvider: () -> String?
    private let errorActivityTracker: ErrorActivityTracker
    private let queueOrchestrator: DownloadQueueOrchestrator

    /// Closure-injected per-state handlers. In production these forward
    /// to DownloadStartDispatcher.processUnregisteredState +
    /// .processDownloadWithCredentials and
    /// CredentialPromptCoordinator.requestCredentialsAndStartDownload.
    /// Closure injection keeps tests from having to stand up the full
    /// dispatcher + credential-prompt graph just to verify routing.
    ///
    /// `processWithCredentials` takes the captured `accountId` so the
    /// dispatcher can resolve `bearerAuthorized(request:accountId:)` against
    /// the originally-selected library, even if `currentAccountId` flips
    /// mid-flight (library swap during a multi-chunk download).
    private let processUnregistered: (TPPBook, TPPBookLocation?, Bool?) -> TPPBookState
    private let processWithCredentials: (TPPBook, TPPBookState, URLRequest?, String) -> Void
    private let requestCredentials: (TPPBook) -> Void

    /// Sentinel UUID for "no account selected at capture time." Kept lexically
    /// identical to `AccountsManager.noAccountSentinelUUID` (private there) so
    /// downstream `userAccount(for:)` lookups return the same no-credentials
    /// placeholder instance the rest of the resolver path returns. Capturing
    /// this token instead of `nil` makes the capture-at-start invariant
    /// explicit: there is always SOME id, and a missing one is the sentinel,
    /// not the current account at request-build time.
    static let capturedNoAccountSentinelUUID = "__no_account_selected__"

    /// `processWithCredentials` takes the captured accountId as its 4th
    /// argument so the dispatcher can pin bearer auth to the library that was
    /// selected when the download started.
    init(
        stateManager: DownloadStateManager,
        bookRegistry: TPPBookRegistryProvider,
        userAccountProvider: @escaping () -> TPPUserAccount,
        currentAccountIdProvider: @escaping () -> String?,
        errorActivityTracker: ErrorActivityTracker,
        queueOrchestrator: DownloadQueueOrchestrator,
        processUnregistered: @escaping (TPPBook, TPPBookLocation?, Bool?) -> TPPBookState,
        processWithCredentials: @escaping (TPPBook, TPPBookState, URLRequest?, String) -> Void,
        requestCredentials: @escaping (TPPBook) -> Void
    ) {
        self.stateManager = stateManager
        self.bookRegistry = bookRegistry
        self.userAccountProvider = userAccountProvider
        self.currentAccountIdProvider = currentAccountIdProvider
        self.errorActivityTracker = errorActivityTracker
        self.queueOrchestrator = queueOrchestrator
        self.processUnregistered = processUnregistered
        self.processWithCredentials = processWithCredentials
        self.requestCredentials = requestCredentials
    }

    /// Convenience init for tests that assert routing only: a 3-arg
    /// `processWithCredentials` (the captured accountId is dropped) and a nil
    /// account reader, so the captured id is the sentinel.
    convenience init(
        stateManager: DownloadStateManager,
        bookRegistry: TPPBookRegistryProvider,
        userAccountProvider: @escaping () -> TPPUserAccount,
        errorActivityTracker: ErrorActivityTracker,
        queueOrchestrator: DownloadQueueOrchestrator,
        processUnregistered: @escaping (TPPBook, TPPBookLocation?, Bool?) -> TPPBookState,
        processWithCredentials: @escaping (TPPBook, TPPBookState, URLRequest?) -> Void,
        requestCredentials: @escaping (TPPBook) -> Void
    ) {
        self.init(
            stateManager: stateManager,
            bookRegistry: bookRegistry,
            userAccountProvider: userAccountProvider,
            currentAccountIdProvider: { nil },
            errorActivityTracker: errorActivityTracker,
            queueOrchestrator: queueOrchestrator,
            processUnregistered: processUnregistered,
            processWithCredentials: { book, state, request, _ in
                processWithCredentials(book, state, request)
            },
            requestCredentials: requestCredentials
        )
    }

    // MARK: - startBorrow

    /// Legacy callback-based borrow entry. Wraps the modern async
    /// borrowAsync with slot-release semantics: if the post-borrow
    /// state is `.holding` (server returned a hold instead of a
    /// downloadable loan) or borrowAsync threw, the active-download
    /// slot is freed and pending starts are rescheduled — otherwise
    /// the download queue gets stuck.
    func startBorrow(
        for book: TPPBook,
        attemptDownload shouldAttemptDownload: Bool,
        borrowCompletion: (() -> Void)? = nil
    ) {
        // Swift 6 `complete`: box the non-Sendable `borrowCompletion` before the
        // `sending` `Task` boundary (see `BorrowCompletionBox`). Boxing avoids
        // `@Sendable`-ing the param, which would ripple to the caller closures.
        let borrowCompletionBox = BorrowCompletionBox(borrowCompletion)
        Task { [weak self] in
            await self?.startBorrowAsync(
                for: book,
                attemptDownload: shouldAttemptDownload,
                borrowCompletionBox: borrowCompletionBox
            )
        }
    }

    /// The `async` body of `startBorrow`, awaitable so async callers and tests
    /// can join the slot-release, reschedule and completion side effects
    /// instead of polling. Takes the box so boxing happens once, at the `Task`
    /// boundary.
    func startBorrowAsync(
        for book: TPPBook,
        attemptDownload shouldAttemptDownload: Bool,
        borrowCompletionBox: BorrowCompletionBox
    ) async {
        do {
            _ = try await self.delegate?.borrowAsync(book, attemptDownload: shouldAttemptDownload)

            let newState = self.bookRegistry.state(for: book.identifier)
            if newState == .holding {
                await self.stateManager.downloadCoordinator.registerCompletion(identifier: book.identifier)
                let remainingCount = await self.stateManager.downloadCoordinator.activeCount
                Log.info(#file, "📊 Borrow resulted in hold for '\(book.title)', released slot, remaining active: \(remainingCount)")
                self.delegate?.schedulePendingStartsIfPossible()
            }

            borrowCompletionBox.call?()
        } catch {
            Log.error(#file, "Borrow failed: \(error.localizedDescription)")
            await self.stateManager.downloadCoordinator.registerCompletion(identifier: book.identifier)
            let remainingCount = await self.stateManager.downloadCoordinator.activeCount
            Log.info(#file, "📊 Borrow failed for '\(book.title)', released slot, remaining active: \(remainingCount)")
            self.delegate?.schedulePendingStartsIfPossible()
            borrowCompletionBox.call?()
        }
    }

    // MARK: - startDownloadIfAvailable

    func startDownloadIfAvailable(book: TPPBook) {
        let downloadAction = { [weak self] in
            Task { [weak self] in
                await self?.startDownloadAsync(for: book, withRequest: nil)
            }
        }

        book.defaultAcquisition?.availability.match(
            unavailable: nil,
            limited: { _ in downloadAction() },
            unlimited: { _ in downloadAction() },
            reserved: nil,
            ready: { _ in downloadAction() }
        )
    }

    // MARK: - startDownloadAsync

    func startDownloadAsync(for book: TPPBook, withRequest initedRequest: URLRequest? = nil) async {
        // Capture-at-start invariant (Option 1 of the TPPUserAccount migration
        // retro): pin the user's currently-selected library UUID into a let-
        // binding BEFORE any branch can re-resolve `currentUserAccount`. The
        // captured id is threaded through to the dispatcher, which feeds it
        // into `bearerAuthorized(request:accountId:)` — closing the library-
        // swap-mid-download window deterministically.
        //
        // The sentinel branch is intentional: when no account is selected at
        // capture time, we record the sentinel rather than nil. Downstream
        // `userAccount(for:)` lookups on the sentinel return the same no-
        // credentials placeholder for the life of the download, so a fresh-
        // install user who selects a library mid-flight won't have THIS
        // download silently start carrying that new library's bearer token.
        let capturedAccountId: String = currentAccountIdProvider()
            ?? DownloadStartCoordinator.capturedNoAccountSentinelUUID

        let existingInfo = await stateManager.bookIdentifierToDownloadInfo.get(book.identifier)
        if existingInfo != nil {
            Log.debug(#file, "Download already in progress for '\(book.title)', skipping duplicate start")
            return
        }

        if hasActiveLCPContentTransfer?(book.identifier) == true {
            Log.debug(#file, "LCP content transfer already running for '\(book.title)', skipping duplicate start")
            return
        }

        let userAccount = userAccountProvider()
        var state = bookRegistry.state(for: book.identifier)
        let location = bookRegistry.location(forIdentifier: book.identifier)
        let loginRequired = (userAccount.authDefinition?.needsAuth ?? false) && !userAccount.hasCredentials()

        Log.info(#file, "📥 Starting download for '\(book.title)' - state: \(state), hasCredentials: \(userAccount.hasCredentials()), loginRequired: \(loginRequired), capturedAccountId: \(capturedAccountId)")

        await errorActivityTracker.log("Starting download for '\(book.title)'", category: .download)

        switch state {
        case .unregistered:
            state = processUnregistered(book, location, loginRequired)
        case .downloading:
            Log.debug(#file, "Book '\(book.title)' is already downloading (state check), skipping")
            return
        case .downloadFailed, .downloadNeeded, .holding, .SAMLStarted:
            break
        case .downloadSuccessful, .used, .unsupported, .returning:
            NSLog("Ignoring nonsensical download request.")
            return
        }

        let maxConcurrent = stateManager.maxConcurrentDownloads
        let canStart = await stateManager.downloadCoordinator.canStartDownload(maxConcurrent: maxConcurrent)
        let activeCount = await stateManager.downloadCoordinator.activeCount

        if !canStart {
            Log.debug(#file, "Max concurrent downloads reached (\(activeCount)/\(maxConcurrent)), enqueueing '\(book.title)'")
            queueOrchestrator.enqueuePending(book)
            return
        }

        let throttleDelay = await stateManager.downloadCoordinator.shouldThrottleStart()
        if throttleDelay > 0 {
            Log.info(#file, "⏱️ Throttling download start for '\(book.title)' by \(String(format: "%.1f", throttleDelay))s")
            try? await Task.sleep(nanoseconds: UInt64(throttleDelay * 1_000_000_000))
        }

        await stateManager.downloadCoordinator.registerStart(identifier: book.identifier)

        if loginRequired {
            Log.info(#file, "Login required for '\(book.title)', requesting credentials")
            requestCredentials(book)
        } else {
            Log.info(#file, "Credentials available, processing download for '\(book.title)'")
            processWithCredentials(book, state, initedRequest, capturedAccountId)
        }
    }
}

//
//  DownloadStartCoordinator.swift
//  Palace
//
//  Owns the four borrow/start entry points lifted out of MBDC:
//
//    - `startBorrow(for:attemptDownload:borrowCompletion:)` — wraps
//      `delegate.borrowAsync(...)` and releases the download-coordinator
//      slot when the result is `.holding` (server returned a hold) or
//      when borrowAsync threw. Without these releases, downloads get
//      stuck in the queue because the slot is never freed.
//
//    - `startDownload(for:withRequest:)` (public @objc shim)
//      — preserved on MBDC as a 1-line @objc Task wrapper since it's
//      called from app code (BookDetailView etc.). The async path is
//      `startDownloadAsync(...)` here.
//
//    - `startDownloadAsync(for:withRequest:)` — the main orchestrator:
//      duplicate-start guard, state classification (returns early on
//      .downloading / terminal states; preprocesses .unregistered via
//      the dispatcher), capacity check (enqueues at the cap), throttle
//      delay, slot registration, and routing to either the credential
//      prompt or the per-state dispatcher.
//
//    - `startDownloadIfAvailable(book:)` — pattern-matches book
//      availability (limited / unlimited / ready start, others stay
//      put) and forwards to startDownload.
//
//  borrowAsync itself stays on MBDC (it lives in MBDC+Async.swift and
//  is too tangled to lift in this commit). The coordinator forwards
//  to it via `delegate.borrowAsync(...)`.
//

import Foundation
import PalaceLogging

// MARK: - Delegate

/// Surface the coordinator needs MBDC to expose. `borrowAsync` is the
/// big one — it stays on MBDC for now because lifting borrowAsync's
/// 200+ LOC out of MBDC+Async is its own job. The other dependencies
/// (startDispatcher, credentialPromptCoordinator, queueOrchestrator)
/// live in MBDC and are passed to the coordinator at init time, not
/// through this delegate, so the protocol surface stays small.
protocol DownloadStartCoordinatorDelegate: AnyObject {
    func borrowAsync(_ book: TPPBook, attemptDownload: Bool) async throws -> TPPBook
    func schedulePendingStartsIfPossible()
}

// MARK: - DownloadStartCoordinator

/// - Sendable invariant (Swift 6 `complete`-mode): every stored dependency is a
///   `let` bound at init (`stateManager`, `bookRegistry`, `userAccountProvider`,
///   `currentAccountIdProvider`, `errorActivityTracker`, `queueOrchestrator`,
///   and the three closure-injected per-state handlers). The only mutable member
///   is `weak var delegate`, assigned exactly once during owner
///   (`MyBooksDownloadCenter`) construction and never reassigned (weak-ref reads
///   + ARC zeroing are atomic). `startBorrow` / `startDownloadAsync` hop into
///   `Task { }`, touching only the actor-serialized
///   `stateManager.downloadCoordinator` and the injected closures. The captured
///   account-id (a `String`) is snapshotted into a `let` at start so the
///   library-swap window stays closed — no auth-host scoping is broadened here.
///   `@unchecked` only because the stored service types are not themselves
///   `Sendable`.
/// Sendable carrier for the non-Sendable `(() -> Void)?` `borrowCompletion`
/// closure captured by the `sending` `Task` closure in `startBorrow`. Boxing
/// lets the `Task` capture a Sendable carrier instead of the raw closure,
/// clearing the "passing closure as a 'sending' parameter" diagnostic WITHOUT
/// marking `borrowCompletion` `@Sendable` — which would ripple onto every
/// caller closure (`TokenRefreshInterceptor`, `DownloadStartDispatcher`,
/// `DownloadAuthRetryHandler`) that captures `[weak delegate]`/`[weak self]`
/// and mutates non-Sendable state.
/// INVARIANT — the boxed closure is invoked at most once, inside the single
/// `startBorrow` `Task` (both the success and `catch` terminal paths of
/// `startBorrowAsync`), never concurrently; its own thread-affinity is the
/// caller's contract (unchanged).
///
/// `internal` (not `private`) so the joinable `startBorrowAsync` seam — which
/// takes the box rather than the raw closure to preserve the single boxing at
/// the `Task` boundary — is `await`-able from the test target under
/// `@testable import`. No production behavior depends on the access level.
final class BorrowCompletionBox: @unchecked Sendable {
    let call: (() -> Void)?
    init(_ call: (() -> Void)?) { self.call = call }
}

final class DownloadStartCoordinator: @unchecked Sendable {

    weak var delegate: DownloadStartCoordinatorDelegate?

    private let stateManager: DownloadStateManager
    private let bookRegistry: TPPBookRegistryProvider
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

    /// Module-A designated init: accepts a `processWithCredentials` closure
    /// that takes the captured accountId as its 4th argument so the
    /// dispatcher can pin bearer auth to the originally-selected library.
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

    /// Legacy convenience init used by pre-Module-A tests that constructed
    /// the coordinator with a 3-arg `processWithCredentials` closure (no
    /// accountId). Adapts to the 4-arg internal shape by dropping the
    /// captured accountId at the call boundary. `currentAccountIdProvider`
    /// defaults to a nil reader; the resulting captured id is the sentinel,
    /// which is appropriate for tests that don't exercise captured-accountId
    /// semantics (they assert routing only).
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

    /// Behavior-identical `async` body of `startBorrow`. The fire-and-forget
    /// entry point above is `Task { await startBorrowAsync(...) }`; callers
    /// already inside an `async` context (and tests) can `await` it directly
    /// to JOIN the slot-release + reschedule + completion side effects instead
    /// of polling a wall-clock deadline for the detached Task to settle (which
    /// starves under CI oversubscription and blows the executionTimeAllowance).
    ///
    /// Takes the `BorrowCompletionBox` (not the raw closure) so the sole
    /// caller keeps its single boxing at the `Task` boundary; the ordered
    /// side effects — borrowAsync → post-state read → registerCompletion →
    /// activeCount → schedulePendingStartsIfPossible → completion — are
    /// verbatim what the previous inline Task ran.
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

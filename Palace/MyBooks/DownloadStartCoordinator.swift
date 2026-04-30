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

final class DownloadStartCoordinator {

    weak var delegate: DownloadStartCoordinatorDelegate?

    private let stateManager: DownloadStateManager
    private let bookRegistry: TPPBookRegistryProvider
    private let userAccountProvider: () -> TPPUserAccount
    private let errorActivityTracker: ErrorActivityTracker
    private let queueOrchestrator: DownloadQueueOrchestrator

    /// Closure-injected per-state handlers. In production these forward
    /// to DownloadStartDispatcher.processUnregisteredState +
    /// .processDownloadWithCredentials and
    /// CredentialPromptCoordinator.requestCredentialsAndStartDownload.
    /// Closure injection keeps tests from having to stand up the full
    /// dispatcher + credential-prompt graph just to verify routing.
    private let processUnregistered: (TPPBook, TPPBookLocation?, Bool?) -> TPPBookState
    private let processWithCredentials: (TPPBook, TPPBookState, URLRequest?) -> Void
    private let requestCredentials: (TPPBook) -> Void

    init(
        stateManager: DownloadStateManager,
        bookRegistry: TPPBookRegistryProvider,
        userAccountProvider: @escaping () -> TPPUserAccount,
        errorActivityTracker: ErrorActivityTracker,
        queueOrchestrator: DownloadQueueOrchestrator,
        processUnregistered: @escaping (TPPBook, TPPBookLocation?, Bool?) -> TPPBookState,
        processWithCredentials: @escaping (TPPBook, TPPBookState, URLRequest?) -> Void,
        requestCredentials: @escaping (TPPBook) -> Void
    ) {
        self.stateManager = stateManager
        self.bookRegistry = bookRegistry
        self.userAccountProvider = userAccountProvider
        self.errorActivityTracker = errorActivityTracker
        self.queueOrchestrator = queueOrchestrator
        self.processUnregistered = processUnregistered
        self.processWithCredentials = processWithCredentials
        self.requestCredentials = requestCredentials
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
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.delegate?.borrowAsync(book, attemptDownload: shouldAttemptDownload)

                let newState = self.bookRegistry.state(for: book.identifier)
                if newState == .holding {
                    await self.stateManager.downloadCoordinator.registerCompletion(identifier: book.identifier)
                    let remainingCount = await self.stateManager.downloadCoordinator.activeCount
                    Log.info(#file, "📊 Borrow resulted in hold for '\(book.title)', released slot, remaining active: \(remainingCount)")
                    self.delegate?.schedulePendingStartsIfPossible()
                }

                borrowCompletion?()
            } catch {
                Log.error(#file, "Borrow failed: \(error.localizedDescription)")
                await self.stateManager.downloadCoordinator.registerCompletion(identifier: book.identifier)
                let remainingCount = await self.stateManager.downloadCoordinator.activeCount
                Log.info(#file, "📊 Borrow failed for '\(book.title)', released slot, remaining active: \(remainingCount)")
                self.delegate?.schedulePendingStartsIfPossible()
                borrowCompletion?()
            }
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
        let existingInfo = await stateManager.bookIdentifierToDownloadInfo.get(book.identifier)
        if existingInfo != nil {
            Log.debug(#file, "Download already in progress for '\(book.title)', skipping duplicate start")
            return
        }

        let userAccount = userAccountProvider()
        var state = bookRegistry.state(for: book.identifier)
        let location = bookRegistry.location(forIdentifier: book.identifier)
        let loginRequired = (userAccount.authDefinition?.needsAuth ?? false) && !userAccount.hasCredentials()

        Log.info(#file, "📥 Starting download for '\(book.title)' - state: \(state), hasCredentials: \(userAccount.hasCredentials()), loginRequired: \(loginRequired)")

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
            processWithCredentials(book, state, initedRequest)
        }
    }
}

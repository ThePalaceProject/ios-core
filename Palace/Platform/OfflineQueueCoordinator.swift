//
//  OfflineQueueCoordinator.swift
//  Palace
//
//  Supplies `OfflineQueueService`'s executor, dispatching queued actions:
//    .return / .cancelHold -> BookReturnService revoke (via MBDC.returnQueuedBook)
//    .borrow  / .hold      -> MyBooksDownloadCenter.startBorrow
//  Deduped by `bookID`+`type` so a succeeded return is not re-applied. Returns
//  `true` only on server-confirmed success. Registered once from `AppContainer`.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation
import PalaceBookModel
import PalaceBookRegistry

// MARK: - OfflineExecutorRegistering

/// Narrow seam the coordinator needs from the queue: install the single
/// executor closure and the reader that scopes it, and start a drain when a
/// library becomes runnable, without pulling in the full queue surface.
protocol OfflineExecutorRegistering: Sendable {
    func setExecutor(
        _ executor: @escaping OfflineActionExecutor,
        currentLibraryID: @escaping @Sendable () -> String?
    ) async
    func drainIfOnline() async
}

extension OfflineQueueService: OfflineExecutorRegistering {}

// MARK: - OfflineCirculationPerforming

/// The two circulation entry points the production executor drives, narrowed
/// from `MyBooksDownloadCenter` so the executor is testable with a fake.
protocol OfflineCirculationPerforming: AnyObject, Sendable {
    /// `completion` may run more than once: the return-failure alert completes
    /// when shown, and again on Remove from Device or after Retry.
    func returnQueuedBook(withIdentifier identifier: String, completion: (@Sendable () -> Void)?)
    func startBorrow(for book: TPPBook, attemptDownload: Bool, borrowCompletion: (() -> Void)?)
}

extension MyBooksDownloadCenter: OfflineCirculationPerforming {}

// MARK: - OfflineQueueCoordinator

final class OfflineQueueCoordinator: @unchecked Sendable {

    /// Per-type action handlers. Each returns `true` only on
    /// server-confirmed success. Injected so the coordinator is
    /// unit-testable without standing up the real services.
    struct Handlers: Sendable {
        let performReturn: @Sendable (OfflineAction) async -> Bool
        let performBorrow: @Sendable (OfflineAction) async -> Bool
        let performHold: @Sendable (OfflineAction) async -> Bool
        let performCancelHold: @Sendable (OfflineAction) async -> Bool
    }

    private let queue: OfflineExecutorRegistering
    private let handlers: Handlers
    private let dedupe: DedupeBox
    private let runnableLibraryID: @Sendable () -> String?
    private let libraryReady: AnyPublisher<Void, Never>
    private let readyDrains = ReadyDrainBox()

    /// - Parameters:
    ///   - dedupeTTL: how long a *completed* (server-confirmed) bookID+type
    ///     stays deduped. After it elapses, a legitimate second same-type
    ///     action for the same book in the same session (e.g. return -> re-borrow
    ///     -> return again) is allowed through rather than silently skipped.
    ///     In-flight dedupe is unconditional (never TTL-bounded).
    ///   - now: injectable clock for deterministic TTL tests.
    ///   - runnableLibraryID: the library whose actions may run now, or nil;
    ///     the queue hands over only that library's actions.
    ///   - libraryReady: fires when a library becomes runnable, to start its drain.
    init(
        queue: OfflineExecutorRegistering,
        handlers: Handlers,
        runnableLibraryID: @escaping @Sendable () -> String?,
        libraryReady: AnyPublisher<Void, Never> = Empty().eraseToAnyPublisher(),
        dedupeTTL: TimeInterval = 300,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.queue = queue
        self.handlers = handlers
        self.runnableLibraryID = runnableLibraryID
        self.libraryReady = libraryReady
        self.dedupe = DedupeBox(ttl: dedupeTTL, now: now)
    }

    /// Register the executor on the queue. Idempotent at the queue level
    /// (a second call simply replaces the closure), but intended to run
    /// exactly once at launch.
    func registerExecutor() async {
        await queue.setExecutor({ [weak self] action in
            guard let self else { return false }
            return await self.execute(action)
        }, currentLibraryID: runnableLibraryID)
        let queue = self.queue
        let readyDrains = self.readyDrains
        readyDrains.set(libraryReady.sink { _ in
            readyDrains.track(Task { await queue.drainIfOnline() })
        })
        // A library that became runnable before registration has no pending trigger.
        await queue.drainIfOnline()
    }

    /// The dispatch + dedupe body. Exposed internally so tests can drive
    /// it directly as well as through the queue.
    func execute(_ action: OfflineAction) async -> Bool {
        let key = Self.dedupeKey(for: action)

        // Collapse a duplicate (same bookID+type) that already
        // succeeded or is in-flight. Treat it as already-done (`true`) so
        // the queue removes it without re-applying the side effect.
        guard await dedupe.begin(key) else {
            return true
        }

        let success = await dispatch(action)

        if success {
            await dedupe.complete(key)
        } else {
            // Allow a genuine failure to be retried by the queue.
            await dedupe.rollback(key)
        }
        return success
    }

    /// Test-only join on the drains started by library-ready signals so far.
    func _awaitTriggeredDrainsForTesting() async {
        for task in readyDrains.takeTasks() {
            await task.value
        }
    }

    /// Clears dedupe state. Test/reset seam.
    func reset() async {
        await dedupe.clear()
    }

    // MARK: - Private

    private func dispatch(_ action: OfflineAction) async -> Bool {
        switch action.type {
        case .return:
            return await handlers.performReturn(action)
        case .borrow:
            return await handlers.performBorrow(action)
        case .hold:
            return await handlers.performHold(action)
        case .cancelHold:
            return await handlers.performCancelHold(action)
        }
    }

    /// Keyed by library too: the same book ID at two libraries is two loans.
    static func dedupeKey(for action: OfflineAction) -> String {
        "\(action.libraryID ?? ""):\(action.type.rawValue):\(action.bookID)"
    }

    /// The current library once the registry has finished loading it, else nil.
    /// Until then the registry may hold another library's records, or none, and
    /// an absent book says nothing about this library's shelf.
    static func runnableLibraryID(current: String?, loaded: String?) -> String? {
        guard let current, current == loaded else { return nil }
        return current
    }

    /// States that represent a confirmed active loan after a borrow. Used
    /// to fail-closed the offline `.borrow` executor branch.
    static func isActiveLoanState(_ state: TPPBookState) -> Bool {
        switch state {
        case .downloadNeeded, .downloading, .downloadSuccessful, .used:
            return true
        default:
            return false
        }
    }

    /// A placed hold lands in `.holding`. Used to fail-closed the offline
    /// `.hold` executor branch. Pure so the decision is unit-testable
    /// without a live download center.
    static func isHeldState(_ state: TPPBookState) -> Bool {
        state == .holding
    }

    /// Server-confirmed return: the registry either no longer knows the
    /// book, or has moved it out of any active-loan state. Pure so the
    /// `.return`/`.cancelHold` confirmation is unit-testable.
    static func isReturnConfirmed(state: TPPBookState, bookPresent: Bool) -> Bool {
        state == .unregistered || !bookPresent
    }
}

// MARK: - DedupeBox

/// Actor-guarded dedupe ledger. `begin` returns `false` when the key is
/// already in-flight or completed, so the caller can short-circuit a
/// duplicate. `rollback` releases an in-flight key after a genuine
/// failure so the queue's retry can re-attempt it.
private actor DedupeBox {
    private var inFlight: Set<String> = []
    /// Completed keys with the timestamp of completion. A key blocks a
    /// duplicate only while within `ttl` of its completion, so a book's
    /// legitimate later same-type action isn\'t permanently suppressed.
    private var completed: [String: Date] = [:]
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date

    init(ttl: TimeInterval, now: @escaping @Sendable () -> Date) {
        self.ttl = ttl
        self.now = now
    }

    func begin(_ key: String) -> Bool {
        // In-flight is always a hard block (no concurrent double-apply).
        if inFlight.contains(key) { return false }
        // Completed blocks only within the TTL window; prune stale entries.
        if let completedAt = completed[key] {
            if now().timeIntervalSince(completedAt) < ttl {
                return false
            }
            completed[key] = nil
        }
        inFlight.insert(key)
        return true
    }

    func complete(_ key: String) {
        inFlight.remove(key)
        completed[key] = now()
    }

    func rollback(_ key: String) {
        inFlight.remove(key)
    }

    func clear() {
        inFlight.removeAll()
        completed.removeAll()
    }
}

// MARK: - Production wiring

extension OfflineQueueCoordinator {

    /// Builds the production coordinator wired to the real services via
    /// their EXISTING public APIs. `.return`/`.cancelHold` route through
    /// `MyBooksDownloadCenter.returnQueuedBook` (the revoke flow owned by
    /// `BookReturnService`); `.borrow`/`.hold` route through
    /// `MyBooksDownloadCenter.startBorrow`. Server-confirmation for a
    /// return is read from the registry after the flow completes: a book
    /// that is no longer registered (or no longer downloaded) was
    /// confirmed returned by the server.
    ///
    /// The registry and credentials are the current library's, so each handler
    /// runs only while the action's library is current and loaded in the
    /// registry, and confirms only if it still is when the flow completes. The
    /// queue already picks only such actions; these checks cover a library
    /// switch after that pick. Declining there costs the action one retry,
    /// never a confirmation. A registry load drains the newly loaded library.
    static func production(
        queue: OfflineExecutorRegistering = OfflineQueueService.shared,
        downloadCenter: any OfflineCirculationPerforming,
        bookRegistry: TPPBookRegistryProvider,
        currentLibraryID: @escaping @Sendable () -> String?
    ) -> OfflineQueueCoordinator {
        let runnableLibraryID: @Sendable () -> String? = {
            Self.runnableLibraryID(current: currentLibraryID(), loaded: bookRegistry.loadedAccountID)
        }
        let libraryReady = bookRegistry.registryStatePublisher
            .filter { $0 == .loaded }
            .map { _ in () }
            .eraseToAnyPublisher()

        let performReturn: @Sendable (OfflineAction) async -> Bool = { action in
            let bookID = action.bookID
            return await withCheckedContinuation { checked in
                let continuation = ResumeOnce(checked)
                Task { @MainActor in
                    guard action.belongs(toLibrary: runnableLibraryID()) else {
                        continuation.resume(returning: false)
                        return
                    }
                    downloadCenter.returnQueuedBook(withIdentifier: bookID) {
                        // Server-confirmed if the registry no longer holds
                        // the book as an active downloaded loan.
                        let confirmed = action.belongs(toLibrary: runnableLibraryID())
                            && Self.isReturnConfirmed(
                                state: bookRegistry.state(for: bookID),
                                bookPresent: bookRegistry.book(forIdentifier: bookID) != nil)
                        continuation.resume(returning: confirmed)
                    }
                }
            }
        }

        let performBorrow: @Sendable (OfflineAction) async -> Bool = { action in
            let bookID = action.bookID
            return await withCheckedContinuation { checked in
                let continuation = ResumeOnce(checked)
                Task { @MainActor in
                    guard action.belongs(toLibrary: runnableLibraryID()),
                          let book = bookRegistry.book(forIdentifier: bookID) else {
                        continuation.resume(returning: false)
                        return
                    }
                    downloadCenter.startBorrow(for: book, attemptDownload: true) {
                        // `startBorrow` carries no success/error signal, so
                        // confirm via registry state: a borrowed loan lands
                        // in an active-loan state. Anything else (still
                        // unregistered, download-failed) is NOT confirmed —
                        // return false so the queue keeps it and retries,
                        // rather than optimistically dropping a failed borrow.
                        let confirmed = action.belongs(toLibrary: runnableLibraryID())
                            && Self.isActiveLoanState(bookRegistry.state(for: bookID))
                        continuation.resume(returning: confirmed)
                    }
                }
            }
        }

        let performHold: @Sendable (OfflineAction) async -> Bool = { action in
            let bookID = action.bookID
            return await withCheckedContinuation { checked in
                let continuation = ResumeOnce(checked)
                Task { @MainActor in
                    guard action.belongs(toLibrary: runnableLibraryID()),
                          let book = bookRegistry.book(forIdentifier: bookID) else {
                        continuation.resume(returning: false)
                        return
                    }
                    downloadCenter.startBorrow(for: book, attemptDownload: false) {
                        // A placed hold lands in `.holding`. Any other state
                        // is not a confirmed hold -> fail-closed (stay queued).
                        let confirmed = action.belongs(toLibrary: runnableLibraryID())
                            && Self.isHeldState(bookRegistry.state(for: bookID))
                        continuation.resume(returning: confirmed)
                    }
                }
            }
        }

        // Cancelling a hold uses the same revoke endpoint as a return.
        let performCancelHold = performReturn

        return OfflineQueueCoordinator(
            queue: queue,
            handlers: Handlers(
                performReturn: performReturn,
                performBorrow: performBorrow,
                performHold: performHold,
                performCancelHold: performCancelHold
            ),
            runnableLibraryID: runnableLibraryID,
            libraryReady: libraryReady
        )
    }
}

/// Resumes a continuation at most once. A circulation completion can run more
/// than once, and the first call's outcome is the one the queue acts on.
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        let pending: CheckedContinuation<Value, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}

/// Holds the registry-load subscription for the coordinator's lifetime and,
/// under XCTest only, the drain Tasks it starts so a test can join them.
private final class ReadyDrainBox: @unchecked Sendable {
    private static let retainsTasks =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    private let lock = NSLock()
    private var cancellable: AnyCancellable?
    private var tasks: [Task<Void, Never>] = []

    func set(_ cancellable: AnyCancellable) {
        lock.withLock { self.cancellable = cancellable }
    }

    func track(_ task: Task<Void, Never>) {
        guard Self.retainsTasks else { return }
        lock.withLock { tasks.append(task) }
    }

    func takeTasks() -> [Task<Void, Never>] {
        lock.withLock {
            defer { tasks = [] }
            return tasks
        }
    }
}

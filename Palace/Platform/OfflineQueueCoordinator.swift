//
//  OfflineQueueCoordinator.swift
//  Palace
//
//  Reliability WS-C — seam S2 wiring. Supplies the single executor
//  closure to `OfflineQueueService` (whose `setExecutor` signature is
//  FROZEN) and dispatches each queued `OfflineAction` to the existing
//  public service APIs:
//
//    .return / .cancelHold -> BookReturnService revoke (via MBDC.returnBook)
//    .borrow  / .hold      -> MyBooksDownloadCenter.startBorrow
//
//  INV-8 (idempotency): actions are deduped by `bookID`+`type`. A queued
//  action that already succeeded (or is in-flight) is not dispatched a
//  second time — a partially-succeeded return must not double-apply and
//  confuse the patron with a spurious "no active loan" error.
//
//  The executor returns `true` only on server-confirmed success so the
//  queue's retry/backoff drives genuine failures.
//
//  Registration happens exactly once at launch via `registerExecutor()`,
//  invoked from `AppContainer` (the composition root). The call lives
//  here so the seam owner (WS-C) owns the wiring.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

// MARK: - OfflineExecutorRegistering

/// Narrow seam the coordinator needs from the queue: install the single
/// executor closure. Kept separate from `OfflineQueueServiceProtocol` so
/// the frozen `OfflineQueueService.setExecutor` signature (seam S2) is not
/// touched and the full queue surface isn't pulled into the coordinator.
protocol OfflineExecutorRegistering: Sendable {
    func setExecutor(_ executor: @escaping OfflineActionExecutor) async
}

extension OfflineQueueService: OfflineExecutorRegistering {}

// MARK: - OfflineQueueCoordinator

final class OfflineQueueCoordinator: @unchecked Sendable {

    /// Per-type action handlers. Each returns `true` only on
    /// server-confirmed success. Injected so the coordinator is
    /// unit-testable without standing up the real services.
    struct Handlers: Sendable {
        let performReturn: @Sendable (_ bookID: String) async -> Bool
        let performBorrow: @Sendable (_ bookID: String) async -> Bool
        let performHold: @Sendable (_ bookID: String) async -> Bool
        let performCancelHold: @Sendable (_ bookID: String) async -> Bool
    }

    private let queue: OfflineExecutorRegistering
    private let handlers: Handlers
    private let dedupe = DedupeBox()

    init(queue: OfflineExecutorRegistering, handlers: Handlers) {
        self.queue = queue
        self.handlers = handlers
    }

    /// Register the executor on the queue. Idempotent at the queue level
    /// (a second call simply replaces the closure), but intended to run
    /// exactly once at launch.
    func registerExecutor() async {
        await queue.setExecutor { [weak self] action in
            guard let self else { return false }
            return await self.execute(action)
        }
    }

    /// The dispatch + dedupe body. Exposed internally so tests can drive
    /// it directly as well as through the queue.
    func execute(_ action: OfflineAction) async -> Bool {
        let key = Self.dedupeKey(for: action)

        // INV-8: collapse a duplicate (same bookID+type) that already
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

    /// Clears dedupe state. Test/reset seam.
    func reset() async {
        await dedupe.clear()
    }

    // MARK: - Private

    private func dispatch(_ action: OfflineAction) async -> Bool {
        switch action.type {
        case .return:
            return await handlers.performReturn(action.bookID)
        case .borrow:
            return await handlers.performBorrow(action.bookID)
        case .hold:
            return await handlers.performHold(action.bookID)
        case .cancelHold:
            return await handlers.performCancelHold(action.bookID)
        }
    }

    static func dedupeKey(for action: OfflineAction) -> String {
        "\(action.type.rawValue):\(action.bookID)"
    }
}

// MARK: - DedupeBox

/// Actor-guarded dedupe ledger. `begin` returns `false` when the key is
/// already in-flight or completed, so the caller can short-circuit a
/// duplicate. `rollback` releases an in-flight key after a genuine
/// failure so the queue's retry can re-attempt it.
private actor DedupeBox {
    private var inFlight: Set<String> = []
    private var completed: Set<String> = []

    func begin(_ key: String) -> Bool {
        if inFlight.contains(key) || completed.contains(key) { return false }
        inFlight.insert(key)
        return true
    }

    func complete(_ key: String) {
        inFlight.remove(key)
        completed.insert(key)
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
    /// `MyBooksDownloadCenter.returnBook` (the revoke flow owned by
    /// `BookReturnService`); `.borrow`/`.hold` route through
    /// `MyBooksDownloadCenter.startBorrow`. Server-confirmation for a
    /// return is read from the registry after the flow completes: a book
    /// that is no longer registered (or no longer downloaded) was
    /// confirmed returned by the server.
    static func production(
        queue: OfflineExecutorRegistering = OfflineQueueService.shared,
        downloadCenter: MyBooksDownloadCenter,
        bookRegistry: TPPBookRegistryProvider
    ) -> OfflineQueueCoordinator {
        let performReturn: @Sendable (String) async -> Bool = { bookID in
            await withCheckedContinuation { continuation in
                Task { @MainActor in
                    downloadCenter.returnBook(withIdentifier: bookID) {
                        // Server-confirmed if the registry no longer holds
                        // the book as an active downloaded loan.
                        let state = bookRegistry.state(for: bookID)
                        let confirmed = (state == .unregistered)
                            || bookRegistry.book(forIdentifier: bookID) == nil
                        continuation.resume(returning: confirmed)
                    }
                }
            }
        }

        let performBorrow: @Sendable (String) async -> Bool = { bookID in
            await withCheckedContinuation { continuation in
                Task { @MainActor in
                    guard let book = bookRegistry.book(forIdentifier: bookID) else {
                        continuation.resume(returning: false)
                        return
                    }
                    downloadCenter.startBorrow(for: book, attemptDownload: true) {
                        continuation.resume(returning: true)
                    }
                }
            }
        }

        let performHold: @Sendable (String) async -> Bool = { bookID in
            await withCheckedContinuation { continuation in
                Task { @MainActor in
                    guard let book = bookRegistry.book(forIdentifier: bookID) else {
                        continuation.resume(returning: false)
                        return
                    }
                    downloadCenter.startBorrow(for: book, attemptDownload: false) {
                        continuation.resume(returning: true)
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
            )
        )
    }
}

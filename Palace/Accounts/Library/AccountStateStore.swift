//
//  AccountStateStore.swift
//  Palace
//
//  Account.LoadState storage, keyed by UUID rather than stored on Account.
//  `AccountsManager` replaces Account instances when the network catalog
//  replaces the disk-cache preload; state stored on the instance would be
//  invisible to holders of the old one, and their `awaitReady()` would hang.
//  The UUID is stable across those swaps.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
@preconcurrency import Combine

/// External storage for Account load-state state machines, keyed by
/// account UUID. See docs/architecture/account-state-machine.md.
///
/// `@unchecked Sendable`: the only mutable state, `subjects`, is guarded by
/// `lock`; `CurrentValueSubject` is safe to `send`/`sink` across threads.
public final class AccountStateStore: @unchecked Sendable {

    public static let shared = AccountStateStore()

    /// Tests construct an isolated store; production uses `.shared`.
    internal init() {}

    private let lock = NSLock()
    private var subjects: [String: CurrentValueSubject<Account.LoadState, Never>] = [:]

    /// Current state for a given account UUID. Returns `.notLoaded` if
    /// no state machine has been driven for this UUID yet.
    ///
    /// `internal` (not `public`) because `Account.LoadState` is internal; making
    /// it public would require making `Account` public.
    func state(for uuid: String) -> Account.LoadState {
        return subject(for: uuid).value
    }

    /// AsyncStream of state transitions for a given UUID. Emits the
    /// current state immediately on subscribe, then each transition.
    /// Multiple subscribers safe (CurrentValueSubject broadcasts).
    /// Cancellation cleans up the Combine subscription automatically.
    func stateStream(for uuid: String) -> AsyncStream<Account.LoadState> {
        let subject = self.subject(for: uuid)
        return AsyncStream { continuation in
            let cancellable = subject.sink { state in
                continuation.yield(state)
            }
            continuation.onTermination = { _ in
                cancellable.cancel()
            }
        }
    }

    /// Drive a state transition. Production caller: `AccountsManager`
    /// during `preloadAccountsFromDiskCacheSync` and `loadCatalogs`.
    /// Test caller: directly via `Account._setState(_:)`.
    ///
    /// Internal access — only AccountsManager + tests should drive
    /// transitions. Application code consumes the state machine via
    /// `Account.awaitReady()` / `Account.loadState` instead.
    func setState(_ state: Account.LoadState, for uuid: String) {
        subject(for: uuid).send(state)
    }

    /// Reset state for a UUID to `.notLoaded`. Called by AccountsManager
    /// on library reselect or sign-out. Test helper for isolation.
    func reset(for uuid: String) {
        setState(.notLoaded, for: uuid)
    }

    #if DEBUG
    /// Test-only: terminally drain every state-machine stream so no parked
    /// `awaitReady()` awaiter survives a test boundary.
    ///
    /// `.notLoaded` alone is non-terminal (`awaitReady()` continues on it), so
    /// parked awaiters would leak and starve the cooperative thread pool. Each
    /// subject first gets `.detailsEvicted(.libraryDeselected)`, which
    /// `awaitReady()` treats as terminal, then `.notLoaded` to restore the
    /// baseline. The subjects are not replaced, because parked awaiters are
    /// subscribed to the existing ones; sends happen outside the lock to avoid
    /// re-entrancy through `onTermination`.
    internal func _resetAllForTesting() {
        lock.lock()
        let snapshot = subjects
        lock.unlock()
        for (uuid, subject) in snapshot {
            subject.send(.detailsEvicted(.libraryDeselected(uuid: uuid)))
            subject.send(.notLoaded)
        }
    }
    #endif

    // MARK: - Internals

    private func subject(for uuid: String) -> CurrentValueSubject<Account.LoadState, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let existing = subjects[uuid] {
            return existing
        }
        let new = CurrentValueSubject<Account.LoadState, Never>(.notLoaded)
        subjects[uuid] = new
        return new
    }
}

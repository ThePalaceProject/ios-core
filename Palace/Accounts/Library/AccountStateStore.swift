//
//  AccountStateStore.swift
//  Palace
//
//  External state-machine storage for Account.LoadState, keyed by UUID.
//
//  Why external (vs. stored on Account itself):
//
//  `AccountsManager.account(_:)` does NOT return stable instances. The
//  F-016 fix `preloadAccountsFromDiskCacheSync` constructs Account objects
//  from the disk cache and writes them into `accountSets[hash]`. When
//  `loadCatalogs()` later completes, it REPLACES the array with newly-
//  constructed Account instances from the network response. If state
//  storage lived on the Account instance, the state transition would
//  land on the new instance, but consumers holding the old instance
//  would never see it — every awaitReady() call against a stale
//  reference would hang forever.
//
//  Keying storage by UUID in this external store decouples the state
//  machine from Account instance identity. AccountsManager (or tests)
//  drive transitions via `setState(_:for:)`; consumers fetch the gate
//  via `awaitReady(for:)`. The state machine survives Account instance
//  swaps because the UUID stays stable across them.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
@preconcurrency import Combine

/// External storage for Account load-state state machines, keyed by
/// account UUID. See docs/architecture/account-state-machine.md.
///
/// `@unchecked Sendable` invariant: the only mutable state is `subjects`,
/// which is read and written exclusively under `lock` (an `NSLock`) via
/// the private `subject(for:)` accessor. `lock` is an immutable `let`.
/// The `CurrentValueSubject` values are safe to `send`/`sink` across
/// threads. No property is mutated outside the lock, so the singleton is
/// safe to share process-wide.
public final class AccountStateStore: @unchecked Sendable {

    /// Process-wide singleton. The state machine is single-instance per
    /// account UUID; storing it process-wide matches how AccountsManager
    /// itself is consumed.
    public static let shared = AccountStateStore()

    /// `internal` initializer so tests can construct an isolated store.
    /// Production callers should use `.shared`.
    internal init() {}

    private let lock = NSLock()
    private var subjects: [String: CurrentValueSubject<Account.LoadState, Never>] = [:]

    /// Current state for a given account UUID. Returns `.notLoaded` if
    /// no state machine has been driven for this UUID yet.
    ///
    /// NOTE (Accounts-Wiring triage 2026-05-18): downgraded from `public`
    /// to `internal` because the return type `Account.LoadState` is
    /// internal-by-inheritance (the enclosing `final class Account` is
    /// internal). Swift refuses `public func -> InternalType`. Restoring
    /// `public` requires also elevating `Account` to `public`, which is
    /// out of scope for the wiring module per the swarm contract. Flagged
    /// for the integrator: revert if elevating `Account` to public is
    /// preferred for the ADR's external-consumer story.
    func state(for uuid: String) -> Account.LoadState {
        return subject(for: uuid).value
    }

    /// AsyncStream of state transitions for a given UUID. Emits the
    /// current state immediately on subscribe, then each transition.
    /// Multiple subscribers safe (CurrentValueSubject broadcasts).
    /// Cancellation cleans up the Combine subscription automatically.
    ///
    /// NOTE: see `state(for:)` above for the public→internal downgrade
    /// rationale. Same constraint applies here.
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

    /// Test-only: clear ALL state-machine storage. Production code must
    /// never call this; tests use it to isolate cases when running with
    /// `.shared` (preferred: construct a fresh `AccountStateStore()`
    /// instead so production state is never touched).
    #if DEBUG
    /// Test-only: terminally drain every state-machine stream so no parked
    /// `awaitReady()` awaiter can survive a test boundary.
    ///
    /// The prior implementation sent only `.notLoaded`, which is NON-TERMINAL:
    /// an `awaitReady()` loop parked on `.detailsLoading` receives `.notLoaded`,
    /// hits `case .notLoaded: continue`, and stays suspended forever — leaking
    /// the Task. Those leaked awaiters accumulate across the suite and starve
    /// the Swift cooperative thread pool, which is why instant mock-based tests
    /// (e.g. `CatalogPreloaderTests`) "hang" >60s and a different victim fails
    /// each CI run.
    ///
    /// Two sends per subject, in order:
    ///   1. `.detailsEvicted(.libraryDeselected)` — a TERMINAL value that
    ///      `awaitReady()` already treats as terminal (it throws
    ///      `AccountLoadError.evicted`). This reaches every parked `for await`
    ///      through the normal value-yield path — the SAME path that delivers
    ///      every other state — so it reliably UNPARKS leaked awaiters.
    ///      (`.libraryDeselected` is documented for exactly this: "Awaiters
    ///      observe this terminal so they can fail-fast instead of hanging.")
    ///   2. `.notLoaded` — restores the per-test baseline so the next test
    ///      reads a clean `.notLoaded` current value (the original reset
    ///      behaviour).
    ///
    /// Crucially we do NOT clear/replace the subjects: a parked awaiter is
    /// subscribed to the EXISTING per-UUID subject, so the terminal must be
    /// sent THROUGH that same subject (clearing first would orphan it). The
    /// sends are issued OUTSIDE the lock to avoid re-entrancy through a
    /// subscriber's `onTermination`.
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

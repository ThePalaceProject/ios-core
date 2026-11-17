//
//  AuthDocumentLoader.swift
//  Palace
//
//  Per-account authentication-document fetch and its `Account.LoadState`
//  transitions: the readiness driver every `awaitReady()` consumer gates on.
//  A class, not an actor, because `driveCurrentAccountAuthDocIfNeeded` is called
//  synchronously from the `AccountsManager.currentAccount` setter.
//  `@unchecked Sendable`: `inflightAuthDocFetches` is guarded by `inflightAuthDocLock`.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceLogging

/// Drives per-account auth-document fetches through the `Account.LoadState` machine
/// with a per-UUID single-flight guard.
final class AuthDocumentLoader: @unchecked Sendable {

    /// How long a single-flight `authentication_document` fetch may remain in-flight
    /// before a subsequent fetch treats it as wedged (dropped completion) and reclaims
    /// the slot. Sized above a healthy auth-doc round-trip so a genuinely concurrent
    /// fetch is still deduped, while a dropped-completion wedge self-heals on the next
    /// drive.
    static let authDocInflightTimeout: TimeInterval = 30

    /// Per-UUID single-flight guard, keyed by UUID → the `Date` the fetch started.
    /// The start-time value (rather than a bare `Set`) lets a wedged fetch be reclaimed
    /// once older than `authDocInflightTimeout` (HelpSpot #18414). Read/written ONLY
    /// under `inflightAuthDocLock`.
    private var inflightAuthDocFetches = [String: Date]()
    private let inflightAuthDocLock = NSLock()

    /// Read side of the state machine. Terminal writes go through
    /// `Account._setState`, which in production reaches the same store.
    private let accountStateStore: AccountStateStore

    private let currentAccountProvider: () -> Account?

    /// Signed-in credential state for `Account.loadAuthenticationDocument`. Nil
    /// once the owning manager is deallocated: the loader reaches it through a
    /// weak reference and can outlive it.
    private let signedInStateProvider: () -> TPPSignedInStateProvider?

    /// Whether the owning manager has been torn down (a DEBUG test-boundary reset). When
    /// true, the loader must not drive any state (neither the synchronous `.detailsLoading`
    /// nor the async terminal), or a late drive pollutes the next test. Production binds
    /// `{ false }`.
    private let isTornDown: @Sendable () -> Bool

    init(
        accountStateStore: AccountStateStore,
        currentAccountProvider: @escaping () -> Account?,
        signedInStateProvider: @escaping () -> TPPSignedInStateProvider?,
        isTornDown: @escaping @Sendable () -> Bool
    ) {
        self.accountStateStore = accountStateStore
        self.currentAccountProvider = currentAccountProvider
        self.signedInStateProvider = signedInStateProvider
        self.isTornDown = isTornDown
    }

    /// Whether an auth-doc fetch completion may write its own terminal
    /// (`.detailsLoaded`/`.detailsFailed`). Returns `false` when the account has since
    /// been evicted by a library switch — the deliberate, newer `.detailsEvicted`
    /// terminal supersedes the in-flight fetch this completion belonged to, and awaiters
    /// rely on it to fail fast and redrive on return. Pure so the guard is
    /// unit-testable without a controllable async fetch.
    static func fetchCompletionMayWriteTerminal(currentState: Account.LoadState) -> Bool {
        if case .detailsEvicted = currentState { return false }
        return true
    }

    /// Wraps `Account.loadAuthenticationDocument` with a per-UUID single-flight guard and
    /// the `.detailsLoading → .detailsLoaded/.detailsFailed` state-machine transitions.
    /// The second concurrent caller for the same UUID does NOT fire a duplicate HTTP
    /// request; the state stream's broadcast (`CurrentValueSubject`) covers multi-consumer
    /// observation.
    func fetchAuthDocumentWithStateMachine(
        for account: Account,
        completion: @escaping (Bool) -> Void
    ) {
        // Test-isolation (entry guard): once the owning manager was explicitly torn down
        // (`cancelBackgroundWork()` in the composition root's test-boundary reset), it must not
        // drive any auth-doc state. `isTornDown` is `{ false }` in production (see init).
        if isTornDown() {
            completion(false)
            return
        }

        let now = Date()
        inflightAuthDocLock.lock()
        let existingStart = inflightAuthDocFetches[account.uuid]
        let isStaleWedge: Bool
        if let existingStart {
            isStaleWedge = now.timeIntervalSince(existingStart) >= Self.authDocInflightTimeout
        } else {
            isStaleWedge = false
        }
        // Claim (or re-claim) the slot unless a genuinely-recent fetch owns it.
        let deduping = existingStart != nil && !isStaleWedge
        if !deduping {
            inflightAuthDocFetches[account.uuid] = now
        }
        inflightAuthDocLock.unlock()

        if deduping {
            // A fresh fetch for this UUID is already in flight. Don't fire a duplicate
            // HTTP request — the state stream's broadcast covers multi-consumer
            // observation. Caller's completion gets `true` so the calling DispatchGroup
            // (if any) balances.
            completion(true)
            return
        }

        if isStaleWedge {
            // The prior in-flight fetch never reported back (its network completion was
            // dropped) — the account is wedged at `.detailsLoading`. We reclaimed the
            // slot above; re-fire so `awaitReady()` callers aren't stuck forever
            // (HelpSpot #18414). Re-entering `.detailsLoading` below is the retryable
            // reset: the stream re-broadcasts and the fresh fetch drives a real terminal.
            Log.warn(#file, "Auth-doc fetch for \(account.uuid) was wedged in-flight beyond \(Self.authDocInflightTimeout)s — reclaiming and re-firing")
        }

        account._setState(.detailsLoading)
        account.loadAuthenticationDocument(using: signedInStateProvider()) { [weak self] success in
            guard let self = self else {
                completion(success)
                return
            }
            self.inflightAuthDocLock.lock()
            self.inflightAuthDocFetches.removeValue(forKey: account.uuid)
            self.inflightAuthDocLock.unlock()

            // Test-isolation (completion guard): companion to the entry guard — an
            // in-flight fetch that completes after the manager was torn down must not
            // land its terminal `_setState` after the test boundary. `{ false }` in prod.
            if self.isTornDown() {
                completion(success)
                return
            }

            // A fetch superseded by a library switch must not overwrite the eviction
            // marker the `currentAccount` setter wrote. The setter cancels the fetch and
            // then writes `.detailsEvicted`; the cancellation completion arrives later
            // with `success == false`. Overwriting with `.detailsFailed` would stop the
            // redrive on switch-back and leave `awaitReady()` consumers stuck (PR #1021).
            // A success that lands just before cancellation is dropped for the same reason.
            if AuthDocumentLoader.fetchCompletionMayWriteTerminal(
                currentState: self.accountStateStore.state(for: account.uuid)
            ) {
                if success, let details = account.details {
                    account._setState(.detailsLoaded(details))
                } else {
                    account._setState(.detailsFailed(
                        .authDocumentFetchFailed(underlyingDescription: "loadAuthenticationDocument returned false")
                    ))
                }
            }
            completion(success)
        }
    }

    /// Fires `fetchAuthDocumentWithStateMachine` for the current account when its
    /// `LoadState` is non-terminal. Used by the `loadCatalogs` warm-path + the
    /// library-switch setter to close the driver gap — without it, `awaitReady()` callers
    /// hang waiting for `.detailsLoaded`/`.detailsFailed`. No-op when there is no current
    /// account, or when state has settled at a terminal value.
    func driveCurrentAccountAuthDocIfNeeded() {
        guard let account = currentAccountProvider() else { return }
        switch accountStateStore.state(for: account.uuid) {
        case .detailsLoaded:
            return // terminal — `awaitReady()` awaiters resolve via the loaded details
        case .detailsEvicted(.libraryDeselected):
            // The setter writes this marker against the prior uuid on a library
            // switch. If this account is current again the marker is stale, so
            // re-drive; otherwise `awaitReady()` callers keep throwing `.evicted`.
            // A genuine 404 is `.detailsFailed(.accountNotFound)` and does not redrive
            // (PR #1021).
            //
            // No `default`: a new `AccountEvictionReason` must fail to compile here
            // so its author decides whether it re-drives on re-entry (add it to this
            // arm) or not (add an arm that returns).
            break
        case .detailsFailed:
            return // genuine load failure — caller must retry explicitly
        case .notLoaded, .basicInfoLoaded, .detailsLoading:
            break
        }
        fetchAuthDocumentWithStateMachine(for: account) { _ in }
    }

    #if DEBUG
    /// Test-only: seed the single-flight map so wedge/dedupe paths are exercised
    /// deterministically without burning `authDocInflightTimeout` wall-clock.
    func _seedInflightAuthDocForTesting(uuid: String, age: TimeInterval) {
        inflightAuthDocLock.lock()
        inflightAuthDocFetches[uuid] = Date().addingTimeInterval(-age)
        inflightAuthDocLock.unlock()
    }

    func _inflightAuthDocContainsForTesting(uuid: String) -> Bool {
        inflightAuthDocLock.lock(); defer { inflightAuthDocLock.unlock() }
        return inflightAuthDocFetches[uuid] != nil
    }
    #endif
}

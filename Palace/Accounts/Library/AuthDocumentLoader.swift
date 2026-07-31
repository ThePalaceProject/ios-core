//
//  AuthDocumentLoader.swift
//  Palace
//
//  god-class decomposition — Wave 3 / 3a-3 (the third in-target collaborator split
//  out of `AccountsManager`).
//
//  The per-account authentication-document fetch + state-machine wiring: the
//  single-flight guard, the `.detailsLoading → .detailsLoaded/.detailsFailed`
//  transitions, and the `.detailsEvicted` disambiguation that keeps a library-switch
//  cancellation from clobbering the eviction marker. This is the readiness driver
//  that every `awaitReady()` consumer (audiobook open, token refresh, bookmark sync,
//  CarPlay auth, sign-in) gates on, extracted behind an injected collaborator so the
//  hub carries none of it and a packaged `AccountsManager` names none of the state.
//
//  A `final class @unchecked Sendable` (NOT an actor): `driveCurrentAccountAuthDocIfNeeded`
//  is called SYNCHRONOUSLY from the `AccountsManager.currentAccount` property setter,
//  which cannot `await` — the same class-not-actor rationale as `AccountRegistryStore`.
//  `@unchecked Sendable` invariant: the only mutable state is `inflightAuthDocFetches`,
//  read/written exclusively under `inflightAuthDocLock`.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import PalaceLogging

/// Drives per-account auth-document fetches through the `Account.LoadState` machine
/// with a per-UUID single-flight guard. See the file header for the class-not-actor
/// and `@unchecked Sendable` rationale. Injected into `AccountsManager`; tests
/// construct it directly with spy providers.
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

    /// Per-uuid load-state store. Read side of the state machine (the terminal WRITE
    /// goes through `Account._setState`, which sinks to the shared account-state store; in
    /// production this is the same instance — the read/write asymmetry is prod-identical
    /// and out of scope, matching the note in `AccountsManagerAuthDocContractTests`).
    private let accountStateStore: AccountStateStore

    /// Resolves the current account to drive. Injected so the loader stays agnostic of
    /// the defaults-backed `currentAccountId` → `registryStore.account(uuid)` lookup.
    private let currentAccountProvider: () -> Account?

    /// Resolves the signed-in credential state for `Account.loadAuthenticationDocument`.
    /// `TPPSignedInStateProvider?` (the parameter's own type) — nil only if the owning
    /// manager has been deallocated, which cannot happen while the loader (its `lazy var`)
    /// is alive to call this.
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
    /// rely on it to fail-fast + redrive on return. Pure so the guard is unit-testable
    /// without a controllable async fetch. CP-D1 (swarm_27c181b5).
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

            // A fetch SUPERSEDED by a library switch must not overwrite the eviction
            // marker the `currentAccount` setter wrote. Sequence (CP-D1, swarm_27c181b5):
            // the setter cancels this account's in-flight fetch THEN writes
            // `.detailsEvicted(.libraryDeselected)`; this cancellation completion then
            // fires ASYNC with `success == false` (NSURLError -999). Without this guard
            // it clobbers `.detailsEvicted` with `.detailsFailed(.authDocumentFetchFailed)`,
            // and on switch-back `driveCurrentAccountAuthDocIfNeeded` reads `.detailsFailed`
            // → the "genuine failure, don't redrive" arm → `awaitReady()` consumers stay
            // stuck (the regression class PR #1021 split the enum to prevent). Applies to
            // success too: a fetch that landed just before cancellation must not resurrect
            // the now-non-current account.
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
            // `.detailsEvicted(.libraryDeselected)` is the eviction marker the
            // `currentAccount` setter writes against the PRIOR uuid on a library switch.
            // If this account is back to being current, that marker is stale — re-drive
            // so awaitReady() callers (audiobook open, token refresh, bookmark sync,
            // CarPlay auth) don't throw `.evicted` forever after a swap-away/swap-back.
            //
            // PR #1021 (Module A, swarm_51f248d5) split this case off from
            // `.detailsFailed(.accountNotFound)` so the eviction marker stops sharing
            // storage with the genuine HTTP-404 load failure below. Now a real
            // `.accountNotFound` correctly hits the `.detailsFailed` arm and does NOT
            // redrive.
            //
            // FORWARD-COMPAT (swarm_18b0d071 wave 3 Module B): this arm matches ONLY
            // `.libraryDeselected` today. When a NEW `AccountEvictionReason` case is
            // added, the implementer must choose:
            //   (a) "Re-drive on re-entry" (reversible UX action) — add
            //       `case .detailsEvicted(.<newReason>):` to THIS arm.
            //   (b) "Do NOT re-drive" (irreversible) — add a NEW arm that `return`s
            //       (mirroring `.detailsFailed`).
            // The `default` case is deliberately NOT added — Swift's exhaustiveness
            // check fails at compile time when a new reason is added, forcing the
            // future implementer to make the (a)/(b) decision explicit here rather than
            // silently inheriting the wrong behaviour from a default fall-through.
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

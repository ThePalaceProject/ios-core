//
//  Account+State.swift
//  Palace
//
//  Account.LoadState state machine + `awaitReady()` readiness gate.
//
//  PoC for the 3.2.0 systemic fix to the load-readiness race class.
//  See docs/architecture/account-state-machine.md for the full ADR.
//
//  This file is ADDITIVE: it introduces the new API surface without
//  modifying any existing behavior. `Account.details?` reads continue
//  to work as before. The 3.2.0 swarm sprint wires
//  AccountsManager.loadCatalogs to drive state transitions and migrates
//  ~15-25 call sites that read `account.details` to await readiness.
//
//  STORAGE: state lives in `AccountStateStore.shared` keyed by Account
//  UUID, NOT on the Account instance itself. AccountsManager replaces
//  Account instances during `loadCatalogs` (constructs new objects from
//  network response); state stored on the instance would be lost on
//  every load cycle. The external store survives instance swaps.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

extension Account {

    // MARK: - State

    /// Authoritative load state for an Account. Driven by AccountsManager
    /// during `loadCatalogs()` and per-library `authentication_document`
    /// fetches.
    ///
    /// Forward-only under the cold-launch path; cycles only on library
    /// reselect (reset to `.notLoaded`) or user-initiated retry of a
    /// failed load (`.detailsFailed` → `.detailsLoading`).
    ///
    /// `.detailsFailed` carries the LITERAL semantics of "the load
    /// pipeline produced an error" (HTTP failure, schema mismatch, etc.).
    /// `.detailsEvicted` is a SIBLING terminal carrying eviction-marker
    /// semantics — written by the `currentAccount` setter against the
    /// PRIOR uuid on a library switch so awaiters can fail fast instead
    /// of hanging. The two are deliberately distinct so consumers
    /// (`driveCurrentAccountAuthDocIfNeeded`, `awaitReady()`, age-check)
    /// can disambiguate at switch arms without sharing storage.
    public enum LoadState: Sendable {
        case notLoaded
        case basicInfoLoaded
        case detailsLoading
        case detailsLoaded(AccountDetails)
        case detailsFailed(AccountLoadError)
        /// Eviction marker — written against the prior account UUID when
        /// the user switches libraries. NOT a "load failed" — the account
        /// may still be perfectly valid; it's just no longer current. Any
        /// awaiter on the prior UUID observes the terminal and fails fast
        /// with `AccountLoadError.evicted(reason:)` so it doesn't hang
        /// indefinitely waiting for a transition that will never come on
        /// the prior account's stream. Re-entering the same UUID later
        /// overwrites this through the `.basicInfoLoaded` path on the
        /// next preload/loadCatalogs.
        case detailsEvicted(AccountEvictionReason)
    }

    /// Current load state for this account. Defaults to `.notLoaded`
    /// until AccountsManager drives a transition (wired up in 3.2.0
    /// swarm sprint).
    public var loadState: LoadState {
        AccountStateStore.shared.state(for: uuid)
    }

    /// AsyncStream of state transitions for this account. Emits the
    /// current state immediately on subscribe, then each transition.
    /// Multiple subscribers safe; cancellation cleans up automatically.
    public var stateStream: AsyncStream<LoadState> {
        AccountStateStore.shared.stateStream(for: uuid)
    }

    // MARK: - Readiness Gate

    /// Async readiness gate. Blocks until state transitions to
    /// `.detailsLoaded(AccountDetails)` or `.detailsFailed(AccountLoadError)`.
    /// New code that needs `AccountDetails` MUST use this gate; do not
    /// read `details?` directly outside of documented legacy-tolerant
    /// sites (Bucket C in the ADR migration plan).
    ///
    /// Single-flight per UUID: multiple concurrent callers all unblock
    /// on the same state transition. AccountsManager is responsible for
    /// single-flighting the underlying authentication_document fetch
    /// (wired up in 3.2.0 swarm Phase 1).
    ///
    /// Cancellation: honors `Task.checkCancellation()`. Cancelling one
    /// awaiter does NOT abort the load — other awaiters keep going.
    ///
    /// - Returns: Resolved `AccountDetails` on success.
    /// - Throws: `AccountLoadError` on failure; `CancellationError` if
    ///   the awaiting Task is cancelled.
    public func awaitReady() async throws -> AccountDetails {
        // Fast path: already terminal.
        if let terminal = try Self.resolveTerminal(loadState) {
            return terminal
        }

        // Slow path: await the next terminal state via the stream.
        for await state in stateStream {
            try Task.checkCancellation()
            if let terminal = try Self.resolveTerminal(state) {
                return terminal
            }
        }
        // Stream terminated without resolution — treat as cancellation.
        throw CancellationError()
    }

    /// Bounded readiness gate. Identical resolution semantics to
    /// `awaitReady()` but races the stream against a `timeout`. If the
    /// account is still non-terminal after `timeout` seconds — e.g. the
    /// per-UUID `authentication_document` fetch wedged at `.detailsLoading`
    /// because its network completion was dropped — this throws
    /// `AccountLoadError.readinessTimedOut(timeout:)` instead of hanging
    /// forever.
    ///
    /// The gate itself is NOT reset on timeout: the account stays in its
    /// pre-terminal state so a later drive (`driveCurrentAccountAuthDocIfNeeded`)
    /// can still resolve it, and a caller that owns a retry policy
    /// (`BookRegistrySync.sync`) can `try await` again on the next trigger.
    /// This is the account-side half of the HelpSpot #18414 self-heal: an
    /// unbounded `awaitReady()` behind registry-sync was the load-forever /
    /// empty-My-Books wedge.
    ///
    /// - Parameter timeout: Seconds to wait for a terminal state. Values
    ///   ≤ 0 mean "fail immediately if not already terminal."
    /// - Returns: Resolved `AccountDetails` on success.
    /// - Throws: `AccountLoadError.readinessTimedOut(timeout:)` on timeout;
    ///   the account's `AccountLoadError` on failure; `CancellationError`
    ///   if the awaiting Task is cancelled.
    public func awaitReady(timeout: TimeInterval) async throws -> AccountDetails {
        // Fast path: already terminal — never pay the timeout cost.
        if let terminal = try Self.resolveTerminal(loadState) {
            return terminal
        }

        let stream = stateStream
        return try await withThrowingTaskGroup(of: AccountDetails.self) { group in
            group.addTask {
                for await state in stream {
                    try Task.checkCancellation()
                    if let terminal = try Self.resolveTerminal(state) {
                        return terminal
                    }
                }
                throw CancellationError()
            }
            group.addTask {
                let nanos = UInt64(max(0.0, timeout) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanos)
                throw AccountLoadError.readinessTimedOut(timeout: timeout)
            }
            do {
                guard let first = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                return first
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    /// Maps a `LoadState` to a terminal outcome: returns the details on
    /// `.detailsLoaded`, throws on `.detailsFailed`/`.detailsEvicted`, and
    /// returns `nil` for the non-terminal states (`.notLoaded`,
    /// `.basicInfoLoaded`, `.detailsLoading`) so the caller keeps waiting.
    /// Extracted so the bounded and unbounded gates share one source of
    /// truth for the terminal decision (DRY — a divergence here would let
    /// one gate resolve on a state the other treats as pending).
    private static func resolveTerminal(_ state: LoadState) throws -> AccountDetails? {
        switch state {
        case .detailsLoaded(let details):
            return details
        case .detailsFailed(let error):
            throw error
        case .detailsEvicted(let reason):
            throw AccountLoadError.evicted(reason: reason)
        case .notLoaded, .basicInfoLoaded, .detailsLoading:
            return nil
        }
    }

    // MARK: - Internal Transition Seam (for AccountsManager + tests)

    /// Drive the state machine. Wired up in the 3.2.0 swarm sprint:
    /// `AccountsManager.preloadAccountsFromDiskCacheSync` should call
    /// `_setState(.basicInfoLoaded)`, the authentication_document fetch
    /// transitions to `.detailsLoading` then either `.detailsLoaded` or
    /// `.detailsFailed`, and library reselect resets to `.notLoaded`.
    ///
    /// Internal access — only AccountsManager and unit tests should
    /// drive the state machine. Call sites that need `AccountDetails`
    /// use `awaitReady()` instead.
    func _setState(_ state: LoadState) {
        AccountStateStore.shared.setState(state, for: uuid)
    }
}

// MARK: - Errors

/// Errors surfaced from the Account load pipeline. Migration of
/// `AccountsManager.loadCatalogs` failure paths into these cases is part
/// of the 3.2.0 swarm sprint.
public enum AccountLoadError: Error, Equatable, Sendable {
    /// Network or HTTP-status failure fetching the per-library
    /// `authentication_document`.
    case authDocumentFetchFailed(underlyingDescription: String)

    /// The fetched authentication_document parsed as JSON but didn't
    /// have the shape we expected (missing required fields,
    /// schema-mismatched).
    case malformedAuthDocument(reason: String)

    /// AccountsManager doesn't know about this UUID. Caller should not
    /// have a reference to the Account at all in this case, but the
    /// load pipeline can race library-removal in rare cases.
    ///
    /// LITERAL semantics only — a genuine HTTP 404 / catalog-removal /
    /// race in the load pipeline. NOT to be used as an eviction marker
    /// on library switch — use `LoadState.detailsEvicted` for that.
    case accountNotFound(uuid: String)

    /// `awaitReady()` observed a `.detailsEvicted` terminal — the account
    /// is no longer current (user switched libraries). Distinct from
    /// `.accountNotFound` (which means real load failure) so awaiters can
    /// disambiguate "give up because the library is gone" from "the load
    /// pipeline broke." Surfacing the reason lets callers decide whether
    /// to retry, re-resolve, or simply discard the request.
    case evicted(reason: AccountEvictionReason)

    /// A bounded `awaitReady(timeout:)` gave up before the account reached
    /// a terminal state — the `authentication_document` fetch is taking
    /// longer than the caller's budget (typically because its network
    /// completion was dropped and the account is wedged at `.detailsLoading`).
    /// Distinct from `.authDocumentFetchFailed`: the fetch did NOT report a
    /// failure, it simply never resolved in time. Callers with a retry policy
    /// (registry sync) treat this as "try again on the next trigger" rather
    /// than a hard error. Not surfaced to users — reuses existing silent-retry
    /// paths (HelpSpot #18414).
    case readinessTimedOut(timeout: TimeInterval)
}

/// Reasons an account's LoadState may transition to `.detailsEvicted`.
/// Distinct from `AccountLoadError` because eviction is NOT a load
/// failure — the underlying account may still be perfectly valid; it
/// just stopped being the user-relevant one.
public enum AccountEvictionReason: Equatable, Sendable {
    /// User switched libraries away from this account.
    /// Awaiters on the prior account observe this terminal so they can
    /// fail-fast instead of hanging. Re-entering this UUID overwrites
    /// the marker via the basicInfoLoaded path on the next preload/
    /// loadCatalogs.
    case libraryDeselected(uuid: String)
}

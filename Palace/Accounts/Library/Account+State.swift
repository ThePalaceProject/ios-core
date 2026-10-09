//
//  Account+State.swift
//  Palace
//
//  Account.LoadState state machine + `awaitReady()` readiness gate.
//  See docs/architecture/account-state-machine.md.
//
//  State lives in `AccountStateStore.shared` keyed by UUID, not on the
//  Account instance, because AccountsManager replaces instances during
//  `loadCatalogs`.
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
    /// `.detailsFailed` means the load pipeline produced an error.
    /// `.detailsEvicted` is a separate terminal: the eviction marker, kept
    /// distinct so consumers can tell the two apart.
    public enum LoadState: Sendable {
        case notLoaded
        case basicInfoLoaded
        case detailsLoading
        case detailsLoaded(AccountDetails)
        case detailsFailed(AccountLoadError)
        /// Written against the prior account UUID when the user switches
        /// libraries. Not a load failure: the account is just no longer
        /// current. Awaiters on that UUID fail fast with
        /// `AccountLoadError.evicted(reason:)` instead of hanging. Overwritten
        /// via `.basicInfoLoaded` if the UUID becomes current again.
        case detailsEvicted(AccountEvictionReason)
    }

    /// Current load state for this account. Defaults to `.notLoaded`
    /// until AccountsManager drives a transition.
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
    /// on the same state transition. AccountsManager single-flights the
    /// underlying authentication_document fetch.
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
    func awaitReady(timeout: TimeInterval) async throws -> AccountDetails {
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

    // MARK: - Internal Transition Seam

    /// Drive the state machine. Writers are the account-loading code
    /// (`AccountsManager`, `AccountRegistryLoader`, `AuthDocumentLoader`, and
    /// `loadAuthenticationDocument` on success) and unit tests; call sites that
    /// need `AccountDetails` use `awaitReady()`.
    func _setState(_ state: LoadState) {
        AccountStateStore.shared.setState(state, for: uuid)
    }
}

// MARK: - Errors

/// Errors surfaced from the Account load pipeline.
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
    /// Not an eviction marker; use `LoadState.detailsEvicted` for that.
    case accountNotFound(uuid: String)

    /// `awaitReady()` observed a `.detailsEvicted` terminal: the user
    /// switched libraries. Distinct from `.accountNotFound` so callers can
    /// tell "no longer current" from "the load pipeline broke".
    case evicted(reason: AccountEvictionReason)

    /// A bounded `awaitReady(timeout:)` gave up before a terminal state,
    /// typically because a dropped network completion left the account at
    /// `.detailsLoading`. Callers with a retry policy (registry sync) retry
    /// on the next trigger; not surfaced to users (HelpSpot #18414).
    case readinessTimedOut(timeout: TimeInterval)
}

/// Reasons an account's LoadState may transition to `.detailsEvicted`.
/// Eviction is not a load failure: the account may still be valid.
public enum AccountEvictionReason: Equatable, Sendable {
    /// User switched libraries away from this account.
    case libraryDeselected(uuid: String)
}

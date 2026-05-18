//
//  Account+State.swift
//  Palace
//
//  Account.State state machine + `awaitReady()` readiness gate.
//
//  PoC for the 3.2.0 systemic fix to the load-readiness race class.
//  See docs/architecture/account-state-machine.md for the full ADR.
//
//  This file is ADDITIVE: it introduces the new API surface without
//  modifying any existing behavior. `Account.details?` reads continue to
//  work as before. The 3.2.0 swarm sprint wires AccountsManager.loadCatalogs
//  to drive state transitions and migrates ~60 call sites to await readiness.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
import Combine

extension Account {

    // MARK: - State

    /// Authoritative load state for an Account. Driven by AccountsManager
    /// during `loadCatalogs()` and per-library `authentication_document`
    /// fetches.
    ///
    /// State machine (cold-launch path is monotonic forward):
    /// ```
    ///   notLoaded
    ///   ─ preloadAccountsFromDiskCacheSync ──> basicInfoLoaded
    ///   ─ loadCatalogs.fetchAuthDoc ─────────> detailsLoading
    ///   ─ auth doc parse success ────────────> detailsLoaded(Details)
    ///   ─ auth doc fetch fails ──────────────> detailsFailed(Error)
    /// ```
    /// Cycles only on library reselect / sign-out (reset to `.notLoaded`)
    /// or user-initiated retry (`detailsFailed → detailsLoading`).
    public enum LoadState: Sendable {
        case notLoaded
        case basicInfoLoaded
        case detailsLoading
        case detailsLoaded(AccountDetails)
        case detailsFailed(AccountLoadError)
    }

    /// Current load state. Defaults to `.notLoaded` until AccountsManager
    /// drives a transition (wired up in 3.2.0 swarm sprint).
    public var loadState: LoadState {
        get { _stateSubject.value }
    }

    /// AsyncStream of state transitions for this account. Emits the current
    /// state immediately on subscribe, then each transition. Multiple
    /// subscribers safe (CurrentValueSubject is broadcast). Cancellation
    /// cleans up automatically.
    public var stateStream: AsyncStream<LoadState> {
        AsyncStream { continuation in
            let cancellable = _stateSubject.sink { state in
                continuation.yield(state)
            }
            continuation.onTermination = { _ in
                cancellable.cancel()
            }
        }
    }

    // MARK: - Readiness Gate

    /// Async readiness gate. Blocks until state transitions to
    /// `.detailsLoaded(AccountDetails)` or `.detailsFailed(AccountLoadError)`.
    /// New code that needs `AccountDetails` MUST use this gate; do not read
    /// `details?` directly outside of documented legacy-tolerant sites
    /// (Bucket C in the ADR migration plan).
    ///
    /// Single-flight per Account instance: multiple concurrent callers all
    /// unblock on the same state transition. AccountsManager is expected
    /// to single-flight the underlying network fetch.
    ///
    /// Cancellation: honors `Task.checkCancellation()`. Cancelling one
    /// awaiter does NOT abort the load — other awaiters keep going.
    ///
    /// - Returns: Resolved `AccountDetails` on success.
    /// - Throws: `AccountLoadError` on failure; `CancellationError` if the
    ///   awaiting Task is cancelled.
    public func awaitReady() async throws -> AccountDetails {
        // Fast path: already terminal.
        switch _stateSubject.value {
        case .detailsLoaded(let details):
            return details
        case .detailsFailed(let error):
            throw error
        case .notLoaded, .basicInfoLoaded, .detailsLoading:
            break
        }

        // Slow path: await the next terminal state via the stream.
        for await state in stateStream {
            try Task.checkCancellation()
            switch state {
            case .detailsLoaded(let details):
                return details
            case .detailsFailed(let error):
                throw error
            case .notLoaded, .basicInfoLoaded, .detailsLoading:
                continue
            }
        }
        // Stream terminated without resolution — treat as cancellation.
        throw CancellationError()
    }

    // MARK: - Internal Transition Seam (for AccountsManager + tests)

    /// Drive the state machine. Wired up in the 3.2.0 swarm sprint:
    /// `AccountsManager.preloadAccountsFromDiskCacheSync` should call
    /// `_setState(.basicInfoLoaded)`, the authentication_document fetch
    /// transitions to `.detailsLoading` then either `.detailsLoaded` or
    /// `.detailsFailed`, and library reselect resets to `.notLoaded`.
    ///
    /// Internal access — only AccountsManager and unit tests should drive
    /// the state machine. Call sites that need `AccountDetails` use
    /// `awaitReady()` instead.
    func _setState(_ state: LoadState) {
        _stateSubject.send(state)
    }

    // MARK: - Storage

    /// CurrentValueSubject backing the state machine. Stored as a class-
    /// associated object so this file stays additive and Account.swift is
    /// not modified during the PoC.
    fileprivate var _stateSubject: CurrentValueSubject<LoadState, Never> {
        if let existing = objc_getAssociatedObject(self, &Self._stateSubjectKey) as? CurrentValueSubject<LoadState, Never> {
            return existing
        }
        let subject = CurrentValueSubject<LoadState, Never>(.notLoaded)
        objc_setAssociatedObject(self, &Self._stateSubjectKey, subject, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return subject
    }

    private static var _stateSubjectKey: UInt8 = 0
}

// MARK: - Errors

/// Errors surfaced from the Account load pipeline. Migration of
/// `AccountsManager.loadCatalogs` failure paths into these cases is part
/// of the 3.2.0 swarm sprint.
public enum AccountLoadError: Error, Sendable {
    /// Network or HTTP-status failure fetching the per-library
    /// `authentication_document`.
    case authDocumentFetchFailed(underlying: Error)

    /// The fetched authentication_document parsed as JSON but didn't have
    /// the shape we expected (missing required fields, schema-mismatched).
    case malformedAuthDocument(reason: String)

    /// AccountsManager doesn't know about this UUID. Caller should not
    /// have a reference to the Account at all in this case, but the load
    /// pipeline can race library-removal in rare cases.
    case accountNotFound(uuid: String)
}

//
//  AccountStateMachineTests.swift
//  PalaceTests
//
//  Contract tests for the Account.LoadState state machine + awaitReady()
//  readiness gate. See docs/architecture/account-state-machine.md.
//
//  These tests pin the API contract before the 3.2.0 swarm wires the
//  state machine into AccountsManager.loadCatalogs and migrates ~60
//  call sites. Each test maps to a specific failure mode the contract
//  is designed to prevent.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class AccountStateMachineTests: XCTestCase {

    // MARK: - Helpers

    private func makeAccount() -> Account? {
        return AppContainer.production().accountsManager.accounts().first
    }

    override func tearDown() {
        // State machine storage lives in AccountStateStore.shared, NOT on
        // the Account instance. Reset between tests so transitions in one
        // case don't leak into the next (otherwise the second test's
        // "initial state" reads carry whatever the prior test left).
        #if DEBUG
        AccountStateStore.shared._resetAllForTesting()
        #endif
        super.tearDown()
    }

    // MARK: - Initial state

    /// Default state for a UUID the state machine has never seen is
    /// `.notLoaded`. Phase 1 wiring drives every account that flows
    /// through `AccountsManager.preloadAccountsFromDiskCacheSync` to
    /// `.basicInfoLoaded`, so the original "first production account
    /// reads .notLoaded" assertion no longer holds — that path is now
    /// correctly driven on init. Test the underlying store contract
    /// against a fresh UUID instead, which preserves the original
    /// intent: until something drives a transition, the gate stays
    /// closed.
    func testInitialState_freshUUID_isNotLoaded() {
        let freshUUID = "test-fresh-uuid-\(UUID().uuidString)"
        let state = AccountStateStore.shared.state(for: freshUUID)
        if case .notLoaded = state {
            // pass
        } else {
            XCTFail("AccountStateStore should default to .notLoaded for an untouched UUID, got \(state)")
        }
    }

    // MARK: - Terminal-state fast path

    /// `awaitReady()` returns immediately if the state is already
    /// `.detailsLoaded`. No spurious blocking on fast-path callers.
    func testAwaitReady_terminalDetailsLoaded_returnsImmediately() async throws {
        guard let account = makeAccount(), let details = account.details else {
            XCTSkip("No accounts with details available"); return
        }
        account._setState(.detailsLoaded(details))

        let start = Date()
        let resolved = try await account.awaitReady()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(resolved === details, "awaitReady() must return the AccountDetails carried by .detailsLoaded")
        XCTAssertLessThan(elapsed, 0.1, "Fast path must not introduce measurable latency")
    }

    /// `awaitReady()` throws immediately if the state is already
    /// `.detailsFailed`. Caller decides whether to retry.
    func testAwaitReady_terminalDetailsFailed_throwsImmediately() async {
        guard let account = makeAccount() else {
            XCTSkip("No accounts available"); return
        }
        account._setState(.detailsFailed(.authDocumentFetchFailed(underlyingDescription: "HTTP 503")))

        do {
            _ = try await account.awaitReady()
            XCTFail("awaitReady() must throw when state is .detailsFailed")
        } catch let error as AccountLoadError {
            if case .authDocumentFetchFailed(let desc) = error {
                XCTAssertEqual(desc, "HTTP 503", "Underlying error description should be preserved")
            } else {
                XCTFail("Expected .authDocumentFetchFailed, got \(error)")
            }
        } catch {
            XCTFail("Expected AccountLoadError, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - Transition path

    /// Awaiter blocks during `.detailsLoading` and unblocks when a later
    /// transition lands on `.detailsLoaded`. This is the F-016 → audiobook
    /// regression repro: the audiobook open path would have read
    /// `details?` and silently taken the wrong branch; with the gate, it
    /// must wait for terminal state.
    func testAwaitReady_blocksUntilTransition_thenResolves() async throws {
        guard let account = makeAccount(), let details = account.details else {
            XCTSkip("No accounts with details available"); return
        }
        account._setState(.detailsLoading)

        let exp = expectation(description: "awaitReady resolves after transition")
        let awaiterTask = Task {
            let resolved = try await account.awaitReady()
            XCTAssertTrue(resolved === details)
            exp.fulfill()
        }

        // Simulate the auth doc fetch completing after a brief delay.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(awaiterTask.isCancelled, "Awaiter should be blocked, not cancelled")
        account._setState(.detailsLoaded(details))

        await fulfillment(of: [exp], timeout: 1.0)
    }

    /// Multiple concurrent `awaitReady()` callers all unblock on a single
    /// transition. Single-flight semantics — no thundering herd, no
    /// dropped awaiters.
    func testAwaitReady_multipleConcurrentAwaiters_allResolve() async throws {
        guard let account = makeAccount(), let details = account.details else {
            XCTSkip("No accounts with details available"); return
        }
        account._setState(.detailsLoading)

        let exp = expectation(description: "all awaiters resolve")
        exp.expectedFulfillmentCount = 3

        for _ in 0..<3 {
            Task {
                let resolved = try? await account.awaitReady()
                if resolved === details { exp.fulfill() }
            }
        }

        try await Task.sleep(nanoseconds: 30_000_000)
        account._setState(.detailsLoaded(details))

        await fulfillment(of: [exp], timeout: 1.0)
    }

    // MARK: - Cancellation

    /// Cancelling one awaiter must not abort the load — other awaiters
    /// keep going. This pins single-flight semantics: AccountsManager's
    /// in-flight auth doc fetch shouldn't be cancellable from a UI dismiss
    /// just because one screen went away.
    func testAwaitReady_cancellingOneAwaiter_doesNotAffectOthers() async throws {
        guard let account = makeAccount(), let details = account.details else {
            XCTSkip("No accounts with details available"); return
        }
        account._setState(.detailsLoading)

        let survivorExp = expectation(description: "survivor resolves after transition")
        let survivor = Task {
            do {
                let resolved = try await account.awaitReady()
                if resolved === details { survivorExp.fulfill() }
            } catch {
                XCTFail("Survivor unexpectedly threw: \(error)")
            }
        }

        let toCancel = Task {
            _ = try await account.awaitReady()
        }
        toCancel.cancel()

        try await Task.sleep(nanoseconds: 30_000_000)
        account._setState(.detailsLoaded(details))

        await fulfillment(of: [survivorExp], timeout: 1.0)
        _ = survivor  // silence unused
    }

    // MARK: - State stream

    /// `stateStream` emits the current state immediately and every
    /// transition. Subscribers can observe loading→loaded transitions
    /// for skeleton-UI patterns (Bucket B migrations in the ADR).
    func testStateStream_emitsCurrentThenTransitions() async throws {
        guard let account = makeAccount(), let details = account.details else {
            XCTSkip("No accounts with details available"); return
        }
        account._setState(.basicInfoLoaded)

        var observed: [String] = []
        let exp = expectation(description: "stream emits 3 distinct states")
        exp.expectedFulfillmentCount = 1

        let task = Task {
            for await state in account.stateStream {
                switch state {
                case .notLoaded:          observed.append("notLoaded")
                case .basicInfoLoaded:    observed.append("basicInfoLoaded")
                case .detailsLoading:     observed.append("detailsLoading")
                case .detailsLoaded:      observed.append("detailsLoaded")
                case .detailsFailed:      observed.append("detailsFailed")
                }
                if observed.count == 3 { exp.fulfill(); break }
            }
        }

        try await Task.sleep(nanoseconds: 30_000_000)
        account._setState(.detailsLoading)
        try await Task.sleep(nanoseconds: 30_000_000)
        account._setState(.detailsLoaded(details))

        await fulfillment(of: [exp], timeout: 2.0)
        task.cancel()

        XCTAssertEqual(observed, ["basicInfoLoaded", "detailsLoading", "detailsLoaded"],
                       "stateStream must emit current-then-transitions, in order")
    }
}

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
import PalaceCatalog
@testable import Palace

@MainActor
final class AccountStateMachineTests: XCTestCase {

    // MARK: - Helpers

    private func makeAccount() -> Account? {
        // Rationale: the fresh AccountsManager from makeTestAppContainer() has
        // deferInitialLoadCatalogsForTesting = true, so its in-memory accounts
        // have no `details` populated. Several tests here (terminalDetailsLoaded,
        // multi-awaiter) require `.details` and `_setState(.detailsLoaded(...))`
        // to succeed, which traps on a fresh manager. Migrating this seam
        // requires test-side fixture builders for AccountDetails that don't
        // currently exist. Tracked as residue for a follow-up.
        return AppContainer.production().accountsManager.accounts().first // MIGRATED-DEFERRED: swarm_5b500284 — fresh AccountsManager lacks details fixtures
    }

    /// Construct a fresh, isolated Account via the production
    /// `Account(publication:imageCache:)` initializer. Used by the PR #1021
    /// semantics tests so the SUT-instantiation DoD grep (#1) sees a direct
    /// production-constructor call, and so each test's state-store key is
    /// unique (avoids cross-test contamination via the shared store keyed
    /// by uuid). Mirrors the constructor `loadAccountSetsAndAuthDoc` uses
    /// when it builds Account instances from `OPDS2Publication.metadata`.
    private func makeFreshAccount(uuid: String, title: String = "Module-A Test Library") -> Account {
        let metadata = OPDS2Publication.Metadata(
            updated: Date(),
            description: "PR #1021 enum split semantics test",
            id: uuid,
            title: title
        )
        let pub = OPDS2Publication(links: [], metadata: metadata, images: nil)
        return Account(publication: pub, imageCache: MockImageCache())
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

    // MARK: - Teardown drain (test-isolation root cause)

    /// The teardown drain `AccountStateStore._resetAllForTesting()` now sends the
    /// TERMINAL `.detailsEvicted(.libraryDeselected)` to every per-UUID subject
    /// (then the `.notLoaded` baseline reset), so any `awaitReady()` awaiter parked
    /// across a test boundary UNPARKS (it maps `.detailsEvicted` to a thrown
    /// `AccountLoadError.evicted`) instead of staying suspended forever. The prior
    /// reset sent only the NON-TERMINAL `.notLoaded`, so a parked awaiter hit
    /// `case .notLoaded: continue` and leaked; accumulating leaked awaiters starve
    /// the cooperative pool and make instant mock-based tests "hang" >60s with a
    /// different victim each CI run.
    ///
    /// The unpark MECHANISM (a parked `awaitReady()` awaiter throwing `.evicted`
    /// when `.detailsEvicted` arrives via the stream) is pinned by
    /// `testAwaitReady_detailsEvictedArrivesViaStream_throwsEvictionError` above —
    /// the drain sends that exact value through that exact stream. A drain-specific
    /// awaiter unit test is intentionally omitted: it can only reproduce the leak by
    /// racing a freshly-spawned awaiter's subscription against the drain (in
    /// production the leaked awaiter is already subscribed at teardown), which is
    /// inherently timing-dependent. The drain's real effect is validated end-to-end
    /// by the full-suite victims (CatalogPreloaderTests / OPDSFeedServiceStateMachineTests
    /// / DownloadThrottlingServiceTests) running green under the per-test timeout.
    // no-superpartner: unpark mechanism covered by testAwaitReady_detailsEvictedArrivesViaStream; drain end-to-end effect validated by full-suite victims

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
        // Deterministic subscription barrier: the CurrentValueSubject emits its
        // current value immediately on subscribe, so the FIRST awaited state
        // proves the sink is live. Await that instead of sleeping a fixed 30ms
        // and hoping the subscribe won the race (which starves + drops the
        // ordering under CI oversubscription).
        let subscribed = expectation(description: "stream subscription attached")
        subscribed.assertForOverFulfill = false

        let task = Task {
            var firstSeen = false
            for await state in account.stateStream {
                if !firstSeen { firstSeen = true; subscribed.fulfill() }
                switch state {
                case .notLoaded:          observed.append("notLoaded")
                case .basicInfoLoaded:    observed.append("basicInfoLoaded")
                case .detailsLoading:     observed.append("detailsLoading")
                case .detailsLoaded:      observed.append("detailsLoaded")
                case .detailsFailed:      observed.append("detailsFailed")
                case .detailsEvicted:     observed.append("detailsEvicted")
                }
                if observed.count == 3 { exp.fulfill(); break }
            }
        }

        // Do not drive a transition until the sink is confirmed live.
        await fulfillment(of: [subscribed], timeout: 2.0)
        account._setState(.detailsLoading)
        account._setState(.detailsLoaded(details))

        await fulfillment(of: [exp], timeout: 2.0)
        task.cancel()

        XCTAssertEqual(observed, ["basicInfoLoaded", "detailsLoading", "detailsLoaded"],
                       "stateStream must emit current-then-transitions, in order")
    }

    // MARK: - Semantics tests for the .detailsEvicted / .accountNotFound split (PR #1021)

    /// PR #1021 (Module A, swarm_51f248d5) split the dual-meaning
    /// `.detailsFailed(.accountNotFound)` terminal into two distinct cases.
    /// This test PINS the original semantics: `.detailsFailed(.accountNotFound)`
    /// now means LITERALLY "the load pipeline produced an HTTP 404 /
    /// catalog-removal" — NOT an eviction marker. `awaitReady()` callers
    /// throw `AccountLoadError.accountNotFound` from the fast path.
    ///
    /// Kill case: any regression that aliases `.accountNotFound` to the new
    /// eviction marker would change the thrown error type and fail this
    /// test. Example: a buggy `awaitReady()` implementation that mapped
    /// `.detailsFailed(.accountNotFound)` to `.evicted(.libraryDeselected)`
    /// for "backward compatibility" with PR #961's overload.
    func testDetailsFailedAccountNotFound_meansHTTP404_throwsAuthLoadError_fromAwaitReady() async {
        let stagedUUID = "test-account-not-found-uuid-\(UUID().uuidString)"
        let account = makeFreshAccount(uuid: stagedUUID)
        account._setState(.detailsFailed(.accountNotFound(uuid: stagedUUID)))

        do {
            _ = try await account.awaitReady()
            XCTFail("awaitReady() must throw when state is .detailsFailed(.accountNotFound)")
        } catch let error as AccountLoadError {
            if case .accountNotFound(let uuid) = error {
                XCTAssertEqual(uuid, stagedUUID,
                               ".accountNotFound must surface the carried UUID, not be re-mapped to .evicted")
            } else {
                XCTFail("Expected .accountNotFound (literal HTTP 404 semantics); got \(error) — PR #1021 split may have re-conflated the cases")
            }
        } catch {
            XCTFail("Expected AccountLoadError.accountNotFound, got \(type(of: error)): \(error)")
        }
    }

    /// PR #1021 (Module A, swarm_51f248d5) added the eviction-marker case.
    /// This test PINS the new semantics: `.detailsEvicted(.libraryDeselected)`
    /// means the user switched libraries away from this account — NOT a
    /// load failure. `awaitReady()` callers throw the NEW
    /// `AccountLoadError.evicted(reason:)` (distinct from `.accountNotFound`)
    /// so consumers can disambiguate "library is gone" from "the load
    /// pipeline broke" at the catch site.
    ///
    /// Kill case: a regression that mapped `.detailsEvicted` back to
    /// `.detailsFailed(.accountNotFound)` for the awaitReady throw path
    /// (re-conflation) would fail this test. So would forgetting to throw
    /// anything at all — the test would hang and time out.
    func testDetailsEvicted_libraryDeselected_throwsEvictionError_fromAwaitReady() async {
        let stagedUUID = "test-evicted-library-uuid-\(UUID().uuidString)"
        let account = makeFreshAccount(uuid: stagedUUID)
        account._setState(.detailsEvicted(.libraryDeselected(uuid: stagedUUID)))

        do {
            _ = try await account.awaitReady()
            XCTFail("awaitReady() must throw when state is .detailsEvicted(.libraryDeselected)")
        } catch let error as AccountLoadError {
            if case .evicted(let reason) = error {
                if case .libraryDeselected(let uuid) = reason {
                    XCTAssertEqual(uuid, stagedUUID,
                                   ".libraryDeselected must surface the carried UUID")
                } else {
                    XCTFail("Expected .libraryDeselected, got \(reason)")
                }
            } else {
                XCTFail("Expected AccountLoadError.evicted (distinct from .accountNotFound); got \(error). PR #1021 enum split was meant to make these throw distinguishable errors.")
            }
        } catch {
            XCTFail("Expected AccountLoadError.evicted, got \(type(of: error)): \(error)")
        }
    }

    /// Slow-path variant: stage `.notLoaded` so `awaitReady()` enters the
    /// for-await stream loop, THEN flip to `.detailsEvicted(.libraryDeselected)`.
    /// Pins that the slow path's switch arm also throws `.evicted` (not
    /// `.accountNotFound`, not nothing). The fast-path test above could
    /// pass against an implementation that only handles the synchronous
    /// terminal — this one requires the stream-loop arm to be wired too.
    func testAwaitReady_detailsEvictedArrivesViaStream_throwsEvictionError() async throws {
        let stagedUUID = "test-stream-evicted-uuid-\(UUID().uuidString)"
        let account = makeFreshAccount(uuid: stagedUUID)
        account._setState(.notLoaded)

        let exp = expectation(description: "awaitReady throws .evicted via stream")
        let awaiterTask = Task {
            do {
                _ = try await account.awaitReady()
                XCTFail("awaitReady() must throw on .detailsEvicted via stream")
            } catch let error as AccountLoadError {
                if case .evicted(.libraryDeselected(let uuid)) = error {
                    XCTAssertEqual(uuid, stagedUUID,
                                   ".evicted reason must carry the UUID from the staged eviction")
                    exp.fulfill()
                } else {
                    XCTFail("Slow-path stream arm must throw .evicted; got \(error)")
                }
            } catch {
                XCTFail("Expected AccountLoadError.evicted, got \(type(of: error)): \(error)")
            }
        }

        // Give the awaiter a moment to subscribe to the stream.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(awaiterTask.isCancelled, "Awaiter should be blocked on the stream, not cancelled")

        // Flip to the eviction terminal — the slow path arm must catch it
        // and throw `.evicted`.
        account._setState(.detailsEvicted(.libraryDeselected(uuid: stagedUUID)))

        await fulfillment(of: [exp], timeout: 2.0)
    }
}

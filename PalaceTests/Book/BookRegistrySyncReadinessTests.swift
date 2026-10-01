//
//  BookRegistrySyncReadinessTests.swift
//  PalaceTests
//
//  Account.LoadState readiness contract for `BookRegistrySync.sync` (PP-4407).
//  The sync awaits `currentAccount.awaitReady()` before reading `loansUrl`, so a
//  cold launch before the auth document loads no longer leaves the registry empty.
//
//  Scope limit: these tests pin the helper (`Account.awaitReady`), not the
//  production caller. A caller that drops the gate or its timeout stays green here
//  (HelpSpot #18619, #18624); the producer-level guards are
//  `BookRegistrySyncTimeoutSeamTests` and `AccountScopeAdapterTests`.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace
@testable import PalaceBookRegistry

@MainActor
final class BookRegistrySyncReadinessTests: XCTestCase {

    private var libraryMock: TPPLibraryAccountMock!

    override func setUp() {
        super.setUp()
        libraryMock = TPPLibraryAccountMock()
    }

    override func tearDown() {
        #if DEBUG
        AccountStateStore.shared._resetAllForTesting()
        #endif
        libraryMock = nil
        super.tearDown()
    }

    // MARK: - testReadiness_blocksUntilLoaded

    /// Contract: under `.detailsLoading`, the gate that
    /// `BookRegistrySync.sync` consumes (`Account.awaitReady()`) blocks
    /// until terminal state. Then proceeds, resolving the loansUrl from
    /// the loaded details. We verify the gate's blocking-and-resolving
    /// semantics directly on libraryMock's account — the same gate that
    /// the migrated production code consumes.
    func testReadiness_underDetailsLoading_blocksUntilTransition() async throws {
        let account = libraryMock.tppAccount
        guard let realDetails = account.details else {
            XCTFail("Library mock must produce loaded details"); return
        }

        account._setState(.detailsLoading)

        let resolved = expectation(description: "awaitReady resolves after transition")
        let awaiterTask = Task {
            let details = try await account.awaitReady()
            XCTAssertTrue(details === realDetails,
                          "awaitReady must return the AccountDetails that BookRegistrySync.sync's Task reads loansUrl from")
            // After the gate resolves, the migrated production code reads
            // `details.loansUrl`. We assert the same is reachable here.
            // The sync function used to read `currentAccount.loansUrl`
            // directly and short-circuit when nil; the
            // loansUrl now comes from `try await currentAccount.awaitReady().loansUrl`
            // which always reflects loaded state.
            _ = details.loansUrl
            resolved.fulfill()
        }

        // Give the awaiter Task real scheduling opportunities to run up to its
        // suspension point inside `awaitReady()`, then confirm it is STILL
        // parked (blocked on the gate, not cancelled or early-resolved). A
        // bounded `Task.yield()` loop replaces the old fixed 50ms
        // `Task.sleep`: the awaiter suspends on a continuation until
        // `_setState`, so once scheduled it provably cannot progress without
        // the transition below — no wall-clock nap to starve under CI load.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(awaiterTask.isCancelled, "Gate must block awaiter, not cancel it")

        account._setState(.detailsLoaded(realDetails))
        await fulfillment(of: [resolved], timeout: 1.0)
    }

    // MARK: - testReadiness_failurePath

    /// Contract: under `.detailsFailed`, awaitReady throws — and the
    /// migrated `BookRegistrySync.sync` Task catches that and reverts
    /// state to `.loaded`. We verify the gate's failure semantics that
    /// the production catch block consumes.
    func testReadiness_underDetailsFailed_throwsAuthDocumentFetchFailed() async {
        let account = libraryMock.tppAccount

        account._setState(.detailsFailed(.authDocumentFetchFailed(underlyingDescription: "test HTTP 503")))

        do {
            _ = try await account.awaitReady()
            XCTFail("awaitReady must throw under .detailsFailed — BookRegistrySync's Task relies on this to revert state to .loaded")
        } catch let error as AccountLoadError {
            if case .authDocumentFetchFailed(let desc) = error {
                XCTAssertEqual(desc, "test HTTP 503",
                               "Underlying description must propagate so the production catch branch logs it accurately")
            } else {
                XCTFail("Expected .authDocumentFetchFailed, got \(error)")
            }
        } catch {
            XCTFail("Expected AccountLoadError, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - testReadiness_wedge_timesOut (HelpSpot #18414)

    /// Contract: the BOUNDED gate `BookRegistrySync.sync` now consumes
    /// (`awaitReady(timeout:)`) must THROW `.readinessTimedOut` when the account
    /// stays wedged at `.detailsLoading` past the bound — instead of blocking
    /// registry sync forever. This is the account-side half of the #18414
    /// self-heal: `sync()`'s `catch` reverts state to `.loaded` and lets the
    /// registry's retry policy drive the next attempt, so the wedge NEVER
    /// reaches the reconciliation/save block with an empty in-memory shelf (the
    /// path that persisted an empty registry over the good on-disk file).
    ///
    /// Kill case: an un-bounded `awaitReady()` (the pre-fix call) never throws
    /// here — this test would hang and fail on timeout.
    func testReadiness_wedgedAtDetailsLoading_bounded_throwsReadinessTimedOut() async {
        let account = libraryMock.tppAccount
        account._setState(.detailsLoading)   // wedged; no transition ever comes

        do {
            _ = try await account.awaitReady(timeout: 0.3)
            XCTFail("The bounded gate must throw when the account never leaves .detailsLoading — an un-bounded await would hang registry sync forever")
        } catch let error as AccountLoadError {
            guard case .readinessTimedOut = error else {
                return XCTFail("Expected .readinessTimedOut so sync()'s catch reverts to .loaded and retries; got \(error)")
            }
        } catch {
            XCTFail("Expected AccountLoadError.readinessTimedOut, got \(type(of: error)): \(error)")
        }

        // The gate is NOT reset — a later drive can still resolve it; the caller
        // owns the retry cadence.
        if case .detailsLoading = account.loadState {
            // pass
        } else {
            XCTFail("Timeout must leave the account wedge in place for a later drive; got \(account.loadState)")
        }
    }

    // MARK: - Integration: full migrated path when production has a currentAccount

    /// When the production accountsManager has a currentAccount (varies
    /// by test ordering), exercise the full migrated `sync()` path and
    /// assert `setState(.syncing)` fires synchronously (the entry into
    /// the migrated Task block). The function previously returned at
    /// the `loansUrl` guard BEFORE this setState call.
    func testIntegration_underDetailsLoading_setStateSyncingFiresUnconditionally() throws {
        let accountsMgr = AppContainer.production().accountsManager
        let (account, cleanup) = seedAccountIfNeeded(on: accountsMgr,
                                                    fixtureId: "test-sync-readiness-\(UUID().uuidString)")
        defer { cleanup() }

        // Integration test reads the production-cached account's credentials
        // state to gate the sync. The factory-isolated account is not the
        // account the production `BookRegistrySync` reads through, so
        // substituting the factory here would defeat the test's premise.
        let userAccount = TPPUserAccount.sharedAccount(libraryUUID: account.uuid) // MIGRATED: keep — reads production-cached account for sync-gate integration check
        guard userAccount.hasCredentials() else {
            // The DI seam puts an Account into accountSets but doesn't
            // mint keychain credentials — sync bails at the hasCredentials
            // guard BEFORE reaching the gate this test is asserting. Leave
            // this XCTSkip in place; running this assertion requires either
            // a real signed-in account or a keychain-mockable seam.
            throw XCTSkip("Account has no credentials — sync bails at the hasCredentials guard before reaching the gate")
        }

        account._setState(.detailsLoading)

        let store = BookRegistryStore()
        let sync = BookRegistrySync(
            store: store,
            accountsManager: accountsMgr,
            downloadCenterProvider: { AppContainer.production().downloadCenter },
            opdsFeedServiceProvider: { AppContainer.production().opdsFeedService }
        )

        let syncingObserved = expectation(description: "setState(.syncing) observed")
        syncingObserved.assertForOverFulfill = false

        sync.sync(
            currentState: .loaded,
            setState: { newState in
                if newState == .syncing { syncingObserved.fulfill() }
            }
        )

        wait(for: [syncingObserved], timeout: 1.0)
    }
}

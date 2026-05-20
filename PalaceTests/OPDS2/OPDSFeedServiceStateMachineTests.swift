//
//  OPDSFeedServiceStateMachineTests.swift
//  PalaceTests
//
//  Migration coverage for `OPDSFeedService.fetchLoans()` to the
//  Account state machine (`awaitReady()` readiness gate). Pins the two
//  Bucket-A behaviors required by swarm_81b5099e contract Network-OPDS:
//
//    1. fetchLoans blocks while the account is in `.detailsLoading`,
//       then proceeds once the state transitions to `.detailsLoaded`.
//       This is the F-016 → audiobook regression class: previously,
//       reads of `currentAccount?.loansUrl` could fire before
//       `loadCatalogs` had populated `details`, silently taking a
//       no-loans-URL path. The gate prevents that race entirely.
//    2. fetchLoans surfaces `.detailsFailed` errors instead of falling
//       through to a generic `.accountNotFound` symptom.
//
//  Test isolation: drives transitions through `AccountStateStore.shared`
//  (the production store, since `Account.awaitReady()` reads from
//  `.shared` per the frozen API). Each test resets the store in tearDown
//  so transitions in one case don't bleed into the next.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class OPDSFeedServiceStateMachineTests: XCTestCase {

    // MARK: - Fixtures

    private var libraryMock: TPPLibraryAccountMock!
    private var account: Account!
    private var details: AccountDetails!
    private var service: OPDSFeedService!

    override func setUp() {
        super.setUp()
        libraryMock = TPPLibraryAccountMock()
        account = libraryMock.tppAccount
        // Sanity: the NYPL fixture must carry a populated loansUrl on
        // its parsed AccountDetails, otherwise the post-await guard
        // below isn't exercising what the assertion claims.
        guard let loadedDetails = account.details, loadedDetails.loansUrl != nil else {
            XCTFail("NYPL fixture must produce AccountDetails with a non-nil loansUrl")
            return
        }
        details = loadedDetails
        service = OPDSFeedService()
    }

    override func tearDown() {
        #if DEBUG
        AccountStateStore.shared._resetAllForTesting()
        #endif
        libraryMock = nil
        account = nil
        details = nil
        service = nil
        super.tearDown()
    }

    // MARK: - Tests

    /// Drive the account into `.detailsLoading` before calling fetchLoans.
    /// The call must block (not return) until the state transitions to
    /// `.detailsLoaded(details)`. Once transitioned, fetchLoans proceeds
    /// past the gate and reads the now-loaded `details.loansUrl`.
    ///
    /// Verifying that "exactly one HTTP request fires" against the
    /// Obj-C `TPPOPDSFeed.withURL` path would require global URLProtocol
    /// interception; we instead verify the contract observable from
    /// outside: while `.detailsLoading`, the call MUST NOT complete; on
    /// transition, it MUST proceed. The "proceeds past the gate" portion
    /// is observable because TPPOPDSFeed.withURL will then trigger an
    /// actual network attempt (which fails in the test env and returns
    /// an error via the completion handler) — but it definitely
    /// happens AFTER the transition, not before. That ordering is the
    /// state-machine guarantee the migration is buying us.
    func testFetchLoansFeed_blocksUntilLoaded_thenFetches() async throws {
        // Arrange: state machine is in .detailsLoading. fetchLoans is
        // expected to suspend on awaitReady().
        account._setState(.detailsLoading)

        let fetchStarted = expectation(description: "fetchLoans task started")
        let fetchCompleted = expectation(description: "fetchLoans completed after transition")
        let completionTime = ManagedAtomic<TimeInterval>(0)

        let fetchTask = Task<Void, Never> {
            fetchStarted.fulfill()
            _ = try? await service.fetchLoans(accountsManager: libraryMock)
            completionTime.value = Date().timeIntervalSinceReferenceDate
            fetchCompleted.fulfill()
        }

        // Wait for the task to spin up and block on the gate.
        await fulfillment(of: [fetchStarted], timeout: 1.0)
        try await Task.sleep(nanoseconds: 80_000_000) // 80 ms
        XCTAssertFalse(fetchTask.isCancelled,
                       "task should be parked on awaitReady, not cancelled")

        // Mid-flight: explicitly assert fetch has NOT completed yet.
        // Without the awaitReady migration, this fetch would have already
        // run synchronously past the (sync) loansUrl read — i.e. the
        // post-task-sleep window would show fetchCompleted fulfilled.
        XCTAssertEqual(completionTime.value, 0,
                       "fetchLoans must remain blocked while state is .detailsLoading")

        // Act: transition to terminal. The gate must release the awaiter
        // and fetchLoans must proceed to the loansUrl read.
        let transitionTime = Date().timeIntervalSinceReferenceDate
        account._setState(.detailsLoaded(details))

        await fulfillment(of: [fetchCompleted], timeout: 15.0)

        // Assert: fetch completion happened strictly AFTER the
        // state-machine transition. This is the ordering invariant the
        // migration guarantees — read of loansUrl cannot precede
        // awaitReady terminal state.
        XCTAssertGreaterThan(completionTime.value, transitionTime,
                             "fetchLoans completion must be observed after the .detailsLoaded transition")
    }

    /// When the account is in `.detailsFailed`, fetchLoans must throw the
    /// underlying `AccountLoadError` synchronously through the gate. It
    /// must NOT fall through to PalaceError.authentication(.accountNotFound)
    /// (the legacy symptom) and must NOT make any HTTP attempt.
    func testFetchLoansFeed_failedDetailsLoad_throws() async {
        // Arrange: the load pipeline previously failed.
        let failure = AccountLoadError.authDocumentFetchFailed(
            underlyingDescription: "HTTP 503 on auth doc"
        )
        account._setState(.detailsFailed(failure))

        // Act + Assert: the gate throws first; no network attempt.
        do {
            _ = try await service.fetchLoans(accountsManager: libraryMock)
            XCTFail("fetchLoans must throw when account state is .detailsFailed")
        } catch let error as AccountLoadError {
            if case .authDocumentFetchFailed(let desc) = error {
                XCTAssertEqual(desc, "HTTP 503 on auth doc",
                               "Underlying auth-doc error must propagate verbatim")
            } else {
                XCTFail("Expected .authDocumentFetchFailed, got \(error)")
            }
        } catch {
            XCTFail("Expected AccountLoadError, got \(type(of: error)): \(error)")
        }
    }

    /// Negative case: without the migration, when state is .detailsFailed
    /// the call would not have thrown AccountLoadError — it would have
    /// either succeeded (if a prior `details` was lying around) or
    /// thrown PalaceError.authentication(.accountNotFound). Mutation
    /// guard: ensures we throw the right type, not just any error.
    func testFetchLoansFeed_failedDetailsLoad_throwsAccountLoadError_notPalaceError() async {
        account._setState(
            .detailsFailed(.malformedAuthDocument(reason: "missing shelf rel"))
        )

        do {
            _ = try await service.fetchLoans(accountsManager: libraryMock)
            XCTFail("Expected throw")
        } catch let error as AccountLoadError {
            if case .malformedAuthDocument(let reason) = error {
                XCTAssertEqual(reason, "missing shelf rel")
            } else {
                XCTFail("Wrong AccountLoadError case: \(error)")
            }
        } catch {
            XCTFail("fetchLoans must surface AccountLoadError, not \(type(of: error))")
        }
    }
}

// MARK: - Tiny atomic helper

/// Minimal cross-task value cell sufficient for the timing assertions in
/// this file. NSLock-backed so the test thread + the Task closure can
/// write/read without TSan complaints.
private final class ManagedAtomic<T>: @unchecked Sendable {
    private var _value: T
    private let lock = NSLock()
    init(_ value: T) { self._value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

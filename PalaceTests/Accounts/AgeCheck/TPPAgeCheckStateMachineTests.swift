//
//  TPPAgeCheckStateMachineTests.swift
//  PalaceTests
//
//  Bucket A migration tests for TPPAgeCheck.verifyCurrentAccountAgeRequirement
//  (swarm_81b5099e Phase 1). The legacy path read
//  `currentLibraryAccountProvider.currentAccount?.details` directly;
//  the migrated path awaits `currentAccount.awaitReady()` so age-check
//  cannot race the auth-doc fetch.
//
//  Tests drive the state machine on the mock provider's account
//  directly via `account._setState(...)`. The age-check serial queue is
//  preserved across the await boundary, so completion ordering matches
//  the legacy behavior exactly.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class TPPAgeCheckStateMachineTests: XCTestCase {

    private var ageCheckChoiceStorageMock: TPPAgeCheckChoiceStorageMock!
    private var userAccountProviderMock: TPPUserAccountProviderMock!
    private var libraryAccountProviderMock: TPPCurrentLibraryAccountProviderMock!
    private var ageCheck: TPPAgeCheck!

    /// Persisted across setUp/tearDown so the fixture's userAboveAgeLimit
    /// flag (UserDefaults-backed in AccountDetails) doesn't leak between
    /// tests.
    private var defaultUserAboveAgeLimit: Bool = false

    override func setUpWithError() throws {
        try super.setUpWithError()
        ageCheckChoiceStorageMock = TPPAgeCheckChoiceStorageMock()
        libraryAccountProviderMock = TPPCurrentLibraryAccountProviderMock()
        userAccountProviderMock = TPPUserAccountProviderMock()
        ageCheck = TPPAgeCheck(ageCheckChoiceStorage: ageCheckChoiceStorageMock)

        defaultUserAboveAgeLimit = libraryAccountProviderMock.currentAccount?.details?.userAboveAgeLimit ?? false
        libraryAccountProviderMock.currentAccount?.details?.userAboveAgeLimit = false
        ageCheckChoiceStorageMock.userPresentedAgeCheck = false
    }

    override func tearDownWithError() throws {
        libraryAccountProviderMock.currentAccount?.details?.userAboveAgeLimit = defaultUserAboveAgeLimit
        #if DEBUG
        AccountStateStore.shared._resetAllForTesting()
        #endif
        ageCheck = nil
        ageCheckChoiceStorageMock = nil
        libraryAccountProviderMock = nil
        userAccountProviderMock = nil
        try super.tearDownWithError()
    }

    /// Drive the state machine for the mock's current account.
    private func setLoadState(_ state: Account.LoadState) {
        libraryAccountProviderMock.currentAccount?._setState(state)
    }

    // MARK: - testAgeCheck_blocksUntilLoaded_thenVerifies
    //
    // Contract: while `.detailsLoading`, the age-check `Task` is
    // suspended on `awaitReady()` — the completion has NOT been called.
    // Once the state transitions to `.detailsLoaded`, the completion
    // fires with the verdict. The pre-existing fast paths (needsAuth,
    // userAboveAgeLimit) still work because the serial-queue body runs
    // unchanged after the await resolves.

    func testAgeCheck_blocksUntilLoaded_thenVerifies() {
        // Set details to loading — completion should be pending.
        setLoadState(.detailsLoading)
        guard let details = libraryAccountProviderMock.currentAccount?.details else {
            XCTFail("Fixture must have details to set userAboveAgeLimit"); return
        }
        details.userAboveAgeLimit = true  // Once loaded, the gate passes.

        let blockedExp = expectation(description: "completion is NOT called while loading")
        blockedExp.isInverted = true

        let resumedExp = expectation(description: "completion fires after transition to .detailsLoaded")

        var capturedResult: Bool?
        ageCheck.verifyCurrentAccountAgeRequirement(
            userAccountProvider: userAccountProviderMock,
            currentLibraryAccountProvider: libraryAccountProviderMock
        ) { aboveAgeLimit in
            if capturedResult == nil {
                capturedResult = aboveAgeLimit
                resumedExp.fulfill()
            } else {
                // Should not fire twice.
                XCTFail("completion fired more than once")
            }
            blockedExp.fulfill()
        }

        // Give the Task time to enter the await. The inverted blockedExp
        // ensures completion did NOT fire during this window.
        wait(for: [blockedExp], timeout: 0.2)
        XCTAssertNil(capturedResult, "completion must not fire while details are .detailsLoading")

        // Now transition to .detailsLoaded — completion should fire.
        setLoadState(.detailsLoaded(details))
        wait(for: [resumedExp], timeout: 2.0)

        XCTAssertEqual(capturedResult, true,
                       "Once details load, the userAboveAgeLimit fast-path completes with true")
    }

    // MARK: - testAgeCheck_failedDetailsLoad_completionFalse
    //
    // Contract: on `.detailsFailed`, the migration calls `completion?(false)`
    // — same path as the legacy `details == nil` branch. The migration
    // must NOT crash on `.detailsFailed`.

    func testAgeCheck_failedDetailsLoad_completionFalse() {
        setLoadState(.detailsFailed(.authDocumentFetchFailed(underlyingDescription: "HTTP 503")))

        let exp = expectation(description: "completion fires with false on .detailsFailed")
        var captured: Bool?
        ageCheck.verifyCurrentAccountAgeRequirement(
            userAccountProvider: userAccountProviderMock,
            currentLibraryAccountProvider: libraryAccountProviderMock
        ) { aboveAgeLimit in
            captured = aboveAgeLimit
            exp.fulfill()
        }

        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(captured, false,
                       ".detailsFailed must produce completion(false) — matches the legacy details == nil branch and does NOT crash")
    }

    // MARK: - Edge: nil current account still surfaces completion(false)
    //
    // The migration's guard for `nil` current account hops onto the
    // serial queue and fires completion(false). Pin it so a future
    // refactor that drops the nil-account branch regresses here.

    func testAgeCheck_nilCurrentAccount_completionFalse() {
        libraryAccountProviderMock.currentAccount = nil

        let exp = expectation(description: "completion fires with false when currentAccount is nil")
        var captured: Bool?
        ageCheck.verifyCurrentAccountAgeRequirement(
            userAccountProvider: userAccountProviderMock,
            currentLibraryAccountProvider: libraryAccountProviderMock
        ) { aboveAgeLimit in
            captured = aboveAgeLimit
            exp.fulfill()
        }

        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(captured, false,
                       "Nil currentAccount must produce completion(false) — matches the legacy guard")
    }
}

//
//  NotificationServiceStateMachineTests.swift
//  PalaceTests
//
//  Bucket A migration tests for NotificationService hold-notification
//  navigation (swarm_81b5099e Phase 1). Targets the
//  `decideHoldNavigation(currentAccount:)` testable seam extracted from
//  the `userNotificationCenter(_:didReceive:...)` delegate body — the
//  delegate itself is impossible to unit-test directly because
//  `UNNotificationResponse` has no public constructor.
//
//  The seam returns a `HoldNavigationOutcome` value; the delegate's
//  side-effecting `tabRouterHub.navigate(to: .holds)` is only called on
//  `.navigate`. Each test pins one outcome against an account in a
//  specific state-machine state. State is driven directly via
//  `account._setState(...)`.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class NotificationServiceStateMachineTests: XCTestCase {

    /// NYPL-fixture-backed mock: `supportsReservations == true` (the
    /// NYPL auth doc enables the reservations feature). Used for the
    /// `.navigate` happy-path test.
    private var nyplProviderMock: TPPLibraryAccountMock!
    /// SimplyE-fixture-backed mock: `supportsReservations == false`
    /// (the SimplyE auth doc disables the reservations feature). Used
    /// for the `.skipUnsupportedReservations` branch test.
    private var simplyeProviderMock: TPPCurrentLibraryAccountProviderMock!

    override func setUpWithError() throws {
        try super.setUpWithError()
        nyplProviderMock = TPPLibraryAccountMock()
        simplyeProviderMock = TPPCurrentLibraryAccountProviderMock()
    }

    override func tearDownWithError() throws {
        #if DEBUG
        AccountStateStore.shared._resetAllForTesting()
        #endif
        nyplProviderMock = nil
        simplyeProviderMock = nil
        try super.tearDownWithError()
    }

    // MARK: - testHoldNotification_supportsReservations_navigates
    //
    // Happy path: state is `.detailsLoaded`, and the loaded details
    // advertise `supportsReservations == true`. The seam returns
    // `.navigate`; the delegate then calls
    // `tabRouterHub.navigate(to: .holds)`. Uses the NYPL fixture which
    // enables reservations in its features.enabled list.

    func testHoldNotification_supportsReservations_navigates() async {
        let account = nyplProviderMock.tppAccount
        guard let details = account.details else {
            XCTFail("NYPL fixture must populate details"); return
        }
        XCTAssertTrue(details.supportsReservations,
                      "Sanity: NYPL fixture must advertise reservations in features.enabled")
        account._setState(.detailsLoaded(details))

        let outcome = await NotificationService.decideHoldNavigation(currentAccount: account)
        XCTAssertEqual(outcome, .navigate,
                       "When details are loaded AND supportsReservations is true, outcome must be .navigate")
    }

    // MARK: - testHoldNotification_doesNotSupportReservations_completes
    //
    // State is `.detailsLoaded` but the loaded details have
    // `supportsReservations == false`. The seam returns
    // `.skipUnsupportedReservations`; the delegate does NOT navigate, but
    // still calls `completionHandler()` (asserted indirectly by the
    // outcome enum being non-`.navigate`). Uses the SimplyE fixture
    // which has reservations in features.disabled.

    func testHoldNotification_doesNotSupportReservations_completes() async {
        guard let account = simplyeProviderMock.currentAccount,
              let details = account.details else {
            XCTFail("SimplyE fixture must have details"); return
        }
        XCTAssertFalse(details.supportsReservations,
                       "Sanity: SimplyE fixture must NOT advertise reservations (features.disabled)")
        account._setState(.detailsLoaded(details))

        let outcome = await NotificationService.decideHoldNavigation(currentAccount: account)
        XCTAssertEqual(outcome, .skipUnsupportedReservations,
                       "Loaded details with supportsReservations=false must skip — outcome cannot be .navigate")
    }

    // MARK: - testHoldNotification_detailsFailed_completes
    //
    // State is `.detailsFailed`. The seam awaits, `awaitReady()` throws
    // `AccountLoadError`, the seam returns `.skipDetailsFailed`. The
    // delegate does NOT navigate. This is the migration's failure path
    // — legacy code read `details?.supportsReservations` and got nil →
    // also skipped, but silently and without distinguishing "details
    // failed" from "details say no". The seam now distinguishes.

    func testHoldNotification_detailsFailed_completes() async {
        let account = nyplProviderMock.tppAccount
        account._setState(.detailsFailed(.authDocumentFetchFailed(underlyingDescription: "HTTP 503")))

        let outcome = await NotificationService.decideHoldNavigation(currentAccount: account)
        XCTAssertEqual(outcome, .skipDetailsFailed,
                       ".detailsFailed must produce .skipDetailsFailed — does NOT crash and is distinguishable from .skipUnsupportedReservations")
    }

    // MARK: - nil-account branch — pin separately so a refactor that
    // drops the nil guard regresses here.

    func testHoldNotification_nilCurrentAccount_skipsNoAccount() async {
        let outcome = await NotificationService.decideHoldNavigation(currentAccount: nil)
        XCTAssertEqual(outcome, .skipNoCurrentAccount,
                       "Nil current account must produce .skipNoCurrentAccount — distinct from .skipDetailsFailed and .skipUnsupportedReservations")
    }

    // MARK: - Blocking semantics — .detailsLoading must NOT resolve to a
    // skip immediately. The seam awaits until terminal state.

    func testHoldNotification_blocksUntilLoaded_thenNavigates() async {
        let account = nyplProviderMock.tppAccount
        guard let details = account.details else {
            XCTFail("NYPL fixture must populate details"); return
        }
        account._setState(.detailsLoading)

        // Launch the awaiter; it must be suspended on the stream.
        async let outcomeTask = NotificationService.decideHoldNavigation(currentAccount: account)

        // Give the await a moment to enter the stream — too short and
        // the test races; this is the same shape as
        // AccountStateMachineTests.testAwaitReady_blocksUntilTransition.
        try? await Task.sleep(nanoseconds: 30_000_000)

        // Now drive the transition; the awaiter should observe it and
        // resolve to .navigate (NYPL fixture enables reservations).
        account._setState(.detailsLoaded(details))

        let resolved = await outcomeTask
        XCTAssertEqual(resolved, .navigate,
                       "Hold navigation must block on .detailsLoading and resolve to .navigate once state transitions to .detailsLoaded(supports=true)")
    }
}

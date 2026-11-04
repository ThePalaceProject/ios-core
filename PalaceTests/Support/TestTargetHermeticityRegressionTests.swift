//  TestTargetHermeticityRegressionTests.swift
//
//  Pins three test-pollution mechanisms found in CI run 29802862487 (#1305):
//  1. PalaceTests compiled without `DEBUG`, so `#if DEBUG` blocks in test code
//     (the AppContainer reset, the loadCatalogs deferral pin) never ran.
//  2. `TPPBookRegistryMock.addBook` announced its registry change on the
//     caller's thread; a leftover `@MainActor` observer then tripped Swift 6's
//     isolation check and killed the runner.
//  3. `awaitCondition` re-evaluated its predicate after cancellation, possibly
//     after tearDown nil'd fixtures, crashing on a force-unwrap.

import XCTest
import Combine
@testable import Palace
@testable import PalaceBookRegistry

@MainActor
final class TestTargetHermeticityRegressionTests: XCTestCase {

    // MARK: - 1. DEBUG compilation condition (the dead-reset-layer pin)

    /// The singleton-reset layer is only real if the test target compiles with
    /// `DEBUG`: `PalaceTestSetup.registerBuiltInResetters()` wraps the
    /// `AppContainer._resetForTesting()` resetter body in `#if DEBUG`, and the
    /// bootstrap pin of `deferInitialLoadCatalogsForTesting` is `#if DEBUG`
    /// too. Without the condition both compile to no-ops and cross-test
    /// pollution accumulates for the whole runner process. This is NOT a
    /// tautology test — it pins a build setting
    /// (`SWIFT_ACTIVE_COMPILATION_CONDITIONS` on PalaceTests/Debug) that was
    /// in fact missing for months, and it fails the moment anyone drops it
    /// again.
    func testTestTarget_compilesWithDEBUG_soPerTestResetLayerIsActive() {
        var debugActive = false
        #if DEBUG
        debugActive = true
        #endif
        XCTAssertTrue(
            debugActive,
            "PalaceTests must define DEBUG in SWIFT_ACTIVE_COMPILATION_CONDITIONS (Debug config). " +
            "Without it, every #if DEBUG block in test-target code is dead — including the " +
            "registered AppContainer._resetForTesting resetter body in PalaceTestSetup, which " +
            "silently disables the per-test singleton reset + AccountsManager drain and " +
            "re-opens the systemic cross-test pollution documented in " +
            "docs/Testing/test-pollution-investigation-handoff.md."
        )
    }

    /// Behavioral companion to the canary above: the bootstrap MUST have
    /// pinned the catalog-load defer flag before any test runs. When the pin
    /// was dead (missing DEBUG), the first incidental `AppContainer.production()`
    /// fired `AccountsManager.init`'s background `loadCatalogs`, which wrote
    /// the 1142-account bundled catalog cache to `accounts_catalog_<hash>.json`
    /// on disk MID-SUITE — the exact mechanism behind
    /// `AccountsManagerLaunchSnapshotTests.testPreload_slimSnapshotButNoFullCache_doesNotHydrate`
    /// observing `.detailsFailed` ("a full cache appeared that the test
    /// deliberately did not seed"). Tests that need the background load flip
    /// the flag false and restore it in their own tearDown, so at the START of
    /// any test it must read `true`.
    func testBootstrap_deferInitialLoadCatalogs_isPinnedTrueAtTestStart() {
        XCTAssertTrue(
            AccountsManager.deferInitialLoadCatalogsForTesting,
            "PalaceTestSetup.bootstrap() must pin deferInitialLoadCatalogsForTesting = true " +
            "before any test runs (and flag-flipping tests must restore it in tearDown). " +
            "A false value here means the pin regressed and background loadCatalogs will " +
            "overwrite fixture catalog caches mid-suite."
        )
    }

    // MARK: - 2. Mock registry announces its change on main

    /// The production registry announces a change on the main queue. The mock
    /// must too: a background caller's synchronous send would run a live
    /// `@MainActor` subscriber off main, which Swift 6's executor check turns
    /// into a SIGTRAP that kills the test runner.
    func testMockRegistry_addBookFromBackgroundThread_announcesChangeOnMain() {
        let mock = TPPBookRegistryMock()
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)

        let delivered = expectation(description: "registry change delivered")
        let deliveredOnMain = LockIsolated<Bool?>(nil)
        let subscription = mock.registryDidChangePublisher.sink {
            deliveredOnMain.withValue { current in
                if current == nil { current = Thread.isMainThread }
            }
            delivered.fulfill()
        }
        defer { subscription.cancel() }

        DispatchQueue.global(qos: .userInitiated).async {
            mock.addBook(book, location: nil, state: .downloadNeeded,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
        }

        wait(for: [delivered], timeout: 5.0)
        XCTAssertEqual(
            deliveredOnMain.value, true,
            "TPPBookRegistryMock.addBook must announce the change on the MAIN queue " +
            "(the production registry's contract). Off-main delivery runs @MainActor " +
            "subscribers on the calling thread and crashes the runner under Swift 6."
        )
    }

    // MARK: - 3. awaitCondition never evaluates the predicate after returning

    /// On timeout, `awaitCondition` cancels its poll task and returns. The
    /// pre-fix loop shape evaluated the predicate ONE more time on the
    /// post-cancellation resumption — which can land after tearDown nil'd the
    /// test's implicitly-unwrapped fixtures, turning a timed-out wait into a
    /// force-unwrap fatalError that kills the runner (the
    /// AudiobookPlaytimesLifecycleTests retry-crash in CI run 29802862487).
    /// This pins the contract: once `awaitCondition` returns, the predicate is
    /// never touched again.
    func testAwaitCondition_onTimeout_predicateIsNeverEvaluatedAfterReturn() {
        let evaluations = LockIsolated<Int>(0)

        // The wait inside awaitCondition records an "Asynchronous wait failed"
        // failure on timeout — expected and intrinsic to this scenario.
        XCTExpectFailure("awaitCondition is driven to timeout by design here") {
            awaitCondition(timeout: 0.3, pollInterval: 0.02) {
                evaluations.withValue { $0 += 1 }
                return false
            }
        }

        let countAtReturn = evaluations.value
        XCTAssertGreaterThan(countAtReturn, 0,
                             "Sanity: the predicate must have been polled while waiting")

        // Give any leaked poll-task resumption every chance to run: the
        // cancelled Task.sleep resumption is enqueued on the main executor at
        // cancel(); these FIFO drains run strictly after it.
        drainMainQueue()
        drainMainQueue()

        XCTAssertEqual(
            evaluations.value, countAtReturn,
            "awaitCondition must NOT evaluate its predicate after returning — a post-return " +
            "evaluation runs against torn-down fixtures (sut = nil force-unwrap) and crashes " +
            "the entire test-runner process."
        )
    }
}

//
//  TestTargetHermeticityRegressionTests.swift
//  PalaceTests
//
//  Regression pins for the three systemic test-pollution mechanisms found in
//  CI run 29802862487 (PR #1305, fix/swift6-test-target-repair):
//
//  1. The PalaceTests target compiled WITHOUT the `DEBUG` condition, so every
//     `#if DEBUG` block in TEST-target code was silently dead — including the
//     body of the registered "AppContainer._resetForTesting" resetter in
//     `PalaceTestSetup.registerBuiltInResetters()` and the bootstrap pin of
//     `AccountsManager.deferInitialLoadCatalogsForTesting`. The per-test
//     AppContainer reset + live-manager drain therefore NEVER ran, which is
//     why months of individually-correct isolation fixes "did not converge"
//     (docs/Testing/test-pollution-investigation-handoff.md): they were all
//     wired behind a dead conditional at the test boundary.
//
//  2. `TPPBookRegistryMock.addBook` posted `.TPPBookRegistryDidChange` on the
//     CALLER's thread, violating the production registry's main-queue posting
//     contract. NotificationCenter invokes selector observers synchronously on
//     the posting thread, so a live `@MainActor` observer from an earlier test
//     (BookDetailViewModel.handleBookRegistryChange) tripped Swift 6's
//     executor-isolation precondition and killed the whole runner process.
//
//  3. `XCTestCase.awaitCondition` evaluated its predicate once more on the
//     leaked resumption AFTER cancellation, i.e. potentially after tearDown
//     nil'd the test's implicitly-unwrapped fixtures — a force-unwrap
//     fatalError that also killed the runner process (the retry-crash
//     signature).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

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

    // MARK: - 2. Mock registry posts its change notification on main

    /// Production contract: `.TPPBookRegistryDidChange` is ALWAYS posted on the
    /// main queue (BookRegistryStore `registry.didSet`, BookRegistrySync save/
    /// update paths). The mock must honor the same delivery-thread contract:
    /// posting on a background caller's thread makes NotificationCenter invoke
    /// any live `@MainActor` selector observer synchronously OFF main, which
    /// Swift 6's executor precondition converts into SIGTRAP process death
    /// (the `TPPBookRegistryMock.addBook` crash that killed three CI runner
    /// processes in run 29802862487).
    func testMockRegistry_addBookFromBackgroundThread_deliversChangeNotificationOnMain() {
        let mock = TPPBookRegistryMock()
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)

        let delivered = expectation(description: "registry-change notification delivered")
        let deliveredOnMain = LockIsolated<Bool?>(nil)
        let observer = NotificationCenter.default.addObserver(
            forName: .TPPBookRegistryDidChange,
            object: nil,
            queue: nil
        ) { _ in
            // Record only the FIRST delivery; addBook posts exactly once.
            deliveredOnMain.withValue { current in
                if current == nil { current = Thread.isMainThread }
            }
            delivered.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        DispatchQueue.global(qos: .userInitiated).async {
            mock.addBook(book, location: nil, state: .downloadNeeded,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
        }

        wait(for: [delivered], timeout: 5.0)
        XCTAssertEqual(
            deliveredOnMain.value, true,
            "TPPBookRegistryMock.addBook must post .TPPBookRegistryDidChange on the MAIN queue " +
            "(the production registry's contract). Off-main delivery invokes @MainActor selector " +
            "observers on the posting thread and crashes the runner under Swift 6."
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

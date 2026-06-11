//
//  RuntimeQuiescenceAuditor.swift
//  PalaceTests
//
//  Structural gate against the cross-test cooperative-pool / main-queue
//  starvation that has flaked the unit suite intermittently (WS-0 / M0,
//  3.2.0 release gate). Seven prior PRs (#1050/#1051/#1056/#1057/#1061 …)
//  point-fixed individual leaks; none added a gate that makes the root
//  cause structurally impossible to LAND silently. This is that gate.
//
//  The documented root cause
//  =========================
//  `AccountsManager.deferInitialLoadCatalogsForTesting` is a process-global
//  flag. While `true` (the test-safe default pinned by `PalaceTestSetup`),
//  every `AccountsManager.init` — including the one the post-test
//  `AppContainer._resetForTesting()` rebuilds after EACH test — SKIPS the
//  background `loadCatalogs` Task. While `false`, that init spawns a live
//  registry crawl (network + 1142-account bundled-snapshot write) on a
//  detached background Task.
//
//  If any test flips the flag to `false` and does NOT restore it, the flag
//  leaks forward: the NEXT test class's first incidental
//  `AppContainer.production()` read rebuilds the cached graph, whose fresh
//  `AccountsManager` now reads `false` and kicks off a crawl Task that
//  outlives the test, leaks past the boundary, and starves the shared
//  cooperative pool / main queue. The victim is whichever async test
//  happens to run while the pool is saturated — which is exactly why the
//  observed victim varies per run (CatalogPreloaderTests, OpenAccessAdapter,
//  the 1735s CatalogRepository outlier, …).
//
//  The invariant this gate enforces
//  ================================
//  **After every test (post-tearDown), `deferInitialLoadCatalogsForTesting`
//  MUST be `true`.** A test that legitimately needs the background load
//  (`AppContainerResetTests`, `TestAppContainerFactoryTests`) flips it
//  `false` for its scenario and restores it via `tearDown` / `defer`. Any
//  test that leaves it `false` is, by construction, the polluter — and this
//  auditor names it instead of letting a random downstream async test time
//  out anonymously.
//
//  Why pure functions
//  ==================
//  `deferFlagViolations(deferFlagLeftByTest:)` is deliberately a pure,
//  input→output function so the MetaTest (`RuntimeQuiescenceGateTests`) can
//  prove the auditor FAILS a synthetic polluter without staging a real
//  cross-test leak — the same self-test discipline
//  `AppContainerIsolationLintTests.testLintCatchesSyntheticViolation` uses.
//
//  Test-target-only. Production code MUST NOT reference this type.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
@testable import Palace

/// Post-test runtime-quiescence checks. Invoked globally by
/// `PalaceSingletonResetObserver.testCaseDidFinish(_:)` (covers ALL tests)
/// and per-test by `PalaceTestCase.tearDownWithError` (stronger, opt-in).
enum RuntimeQuiescenceAuditor {

    /// A single quiescence-invariant breach attributable to the just-finished
    /// test. `invariant` is the short rule name; `detail` is the actionable
    /// remediation surfaced in the failure message.
    struct Violation: Equatable {
        let invariant: String
        let detail: String
    }

    // MARK: - Pure detector (self-testable)

    /// HARD invariant: a test must leave
    /// `AccountsManager.deferInitialLoadCatalogsForTesting` at `true`.
    ///
    /// - Parameter deferFlagLeftByTest: the flag value the finishing test
    ///   left behind (captured BEFORE the post-test reset restores it).
    /// - Returns: a one-element violation list when the flag was left `false`
    ///   (the documented starvation root cause), else empty.
    ///
    /// Pure so the gate's self-test can prove it fires on a synthetic
    /// polluter (`deferFlagLeftByTest: false`) deterministically.
    static func deferFlagViolations(deferFlagLeftByTest: Bool) -> [Violation] {
        guard deferFlagLeftByTest == false else { return [] }
        return [
            Violation(
                invariant: "AccountsManager.deferInitialLoadCatalogsForTesting == true",
                detail:
                    "This test left the catalog-load defer flag FALSE. The next "
                    + "test class's first production() rebuild of the cached "
                    + "AppContainer graph will "
                    + "spawn a live registry-crawl Task that leaks past the test "
                    + "boundary and starves the cooperative pool / main queue "
                    + "(the intermittent async-test timeout flake). Restore the "
                    + "flag in tearDown — `AccountsManager."
                    + "deferInitialLoadCatalogsForTesting = true` — or wrap the "
                    + "scenario in `defer { ... = true }`."
            )
        ]
    }

    // MARK: - Live capture (wiring)

    /// Snapshot the live defer-flag value. Called by the observer at the TOP
    /// of `testCaseDidFinish` — BEFORE `invokeAll()` / `_resetForTesting()`
    /// restores it — so the captured value reflects what the test LEFT.
    ///
    /// Referenced WITHOUT an `#if DEBUG` guard on purpose: the PalaceTests
    /// target does NOT define `DEBUG` (its `SWIFT_ACTIVE_COMPILATION_CONDITIONS`
    /// is `LCP FEATURE_OVERDRIVE`), so a `#if DEBUG` here would compile to a
    /// constant `true` and silently make the whole gate inert — exactly the
    /// bug the synthetic-polluter wiring proof caught. The symbol exists
    /// because the `@testable`-imported Palace module IS built with `DEBUG`;
    /// every existing flag-flipping test (`AppContainerResetTests`,
    /// `TestAppContainerFactoryTests`) references it unconditionally for the
    /// same reason.
    static func captureDeferFlag() -> Bool {
        return AccountsManager.deferInitialLoadCatalogsForTesting
    }

    /// Convenience: capture live state and run every pure detector against it.
    /// Returns the full violation list for the finishing test.
    ///
    /// Used by `PalaceTestCase.tearDownWithError` (the deterministic,
    /// order-independent enforcement) and by the observer's diagnostic
    /// breadcrumb. There is deliberately NO process-wide accumulator + trailing
    /// "final gate" test: test execution order is RANDOMIZED in `Palace.xcscheme`
    /// (`testExecutionOrdering = "random"`), so no statically-named class is
    /// guaranteed to run last — a trailing gate would silently miss any polluter
    /// the shuffle placed after it. The per-test `tearDown` XCTFail is the only
    /// enforcement that holds under randomized order.
    static func auditLiveState() -> [Violation] {
        return deferFlagViolations(deferFlagLeftByTest: captureDeferFlag())
    }
}

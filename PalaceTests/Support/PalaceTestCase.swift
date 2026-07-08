//
//  PalaceTestCase.swift
//  PalaceTests
//
//  Opt-in base class that enforces runtime quiescence at the END of every
//  test method via a plain `tearDownWithError` assertion — the reliable,
//  in-lifecycle complement to the process-wide gate wired into
//  `PalaceSingletonResetObserver` (which covers ALL tests but records the
//  breach from `testCaseDidFinish`, one hop later).
//
//  Adopt this base in any new test, and especially in tests that touch the
//  catalog / accounts / AppContainer graph, so a quiescence regression fails
//  WITHIN the offending test's own lifecycle — the strongest, earliest,
//  least-ambiguous signal.
//
//  Contract — subclasses that override the lifecycle hooks MUST call
//  `super.setUpWithError()` / `super.tearDownWithError()` so the quiescence
//  assertion still runs.
//
//  Relationship to PalaceWiringTestCase
//  ====================================
//  `PalaceWiringTestCase` is the heavier base for AccountsManager
//  state-machine wiring tests (pre-test singleton reset, Combine-bag drain,
//  helper-minted-manager cancellation). `PalaceTestCase` is the lightweight
//  floor: no setup ceremony, just the post-test quiescence assertion. Tests
//  that need the wiring guarantees keep subclassing `PalaceWiringTestCase`;
//  everything else can adopt `PalaceTestCase` for the quiescence floor.
//
//  Test-target-only. swarm WS-0 / M0 (3.2.0 release gate).
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

/// Base XCTestCase that asserts runtime quiescence on tearDown. See header.
class PalaceTestCase: XCTestCase {

    override func tearDownWithError() throws {
        // Call super FIRST. `XCTestCase.tearDownWithError()` invokes the
        // subclass's `tearDown()` (where flag-flippers like
        // `AppContainerResetTests` restore the defer flag to `true`), so the
        // quiescence check MUST run AFTER super — otherwise a subclass that
        // correctly restores in `tearDown()` would false-fail because the
        // check ran before the restore. Verified by the WS-0 ordering proof.
        try super.tearDownWithError()
        assertRuntimeQuiescent()
    }

    /// Fail the current test if it left the suite non-quiescent (currently: the
    /// catalog-load defer flag left `false`, the documented cross-test
    /// starvation root cause). Runs inside the test's own tearDown, so the
    /// failure is attributed unambiguously and immediately — and, unlike the
    /// observer breadcrumb, it actually reddens the run (a real `XCTFail`).
    ///
    /// Exposed so a subclass that overrides `tearDown()` (the non-throwing
    /// variant) can still invoke the check explicitly after its own cleanup.
    func assertRuntimeQuiescent(
        file: StaticString = #file,
        line: UInt = #line
    ) {
        for violation in RuntimeQuiescenceAuditor.auditLiveState() {
            XCTFail(
                "Runtime-quiescence gate [\(violation.invariant)]: \(violation.detail)",
                file: file,
                line: line
            )
        }
    }
}

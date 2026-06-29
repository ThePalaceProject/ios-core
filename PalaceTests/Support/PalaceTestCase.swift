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

    /// Pre-test `NotificationCenter.default` observer count, captured in setUp.
    /// `nil` when the best-effort sample is unavailable (then the observer-leak
    /// check is skipped). Subclasses overriding `setUpWithError` MUST call super.
    private var preObserverCount: Int?

    override func setUpWithError() throws {
        try super.setUpWithError()
        preObserverCount = PalaceSingletonResetObserver.sampleObserverCount()
    }

    override func tearDownWithError() throws {
        // Call super FIRST. `XCTestCase.tearDownWithError()` invokes the
        // subclass's `tearDown()` (where flag-flippers like
        // `AppContainerResetTests` restore the defer flag to `true`), so the
        // quiescence check MUST run AFTER super — otherwise a subclass that
        // correctly restores in `tearDown()` would false-fail because the
        // check ran before the restore. Verified by the WS-0 ordering proof.
        try super.tearDownWithError()
        assertRuntimeQuiescent()
        warnOnObserverLeak()
    }

    /// WARN-ONLY observer-leak check (leaked-observer class). Emits a
    /// `[WS0-OBSERVER-DIAG]` breadcrumb if this test left net-new
    /// `NotificationCenter.default` observers — e.g. a leaked view-model whose
    /// Combine subscriptions stay alive (the AccountDetailViewModel cycle class,
    /// now fixed at root; this guards recurrence).
    ///
    /// PLATFORM LIMITATION (measured 2026-06-29, iOS 26 simruntime): the only
    /// way to count `NotificationCenter.default` observers is parsing its
    /// `debugDescription`, and on iOS 26 that string no longer exposes an
    /// `observers: <N>` line — `sampleObserverCount()` returns `nil`, so this
    /// check (and the pre-existing `PalaceSingletonResetObserver` net-adds
    /// runActivity, same source) is INERT on the platform we actually run. It is
    /// kept warn-only + nil-skipping (graceful, self-tested to skip — NOT a fake
    /// pass) so it lights up automatically if a future runtime restores the API;
    /// it is deliberately NOT promoted to a hard `XCTFail`, because an inert
    /// hard-gate is the exact theater the green-board contract forbids. The
    /// EFFECTIVE structural guard for this leak class is the platform-independent
    /// dealloc assertion in `AccountDetailViewModelLeakTests` (red→green proven),
    /// which does not depend on the observer count at all.
    private func warnOnObserverLeak() {
        guard let pre = preObserverCount,
              let post = PalaceSingletonResetObserver.sampleObserverCount() else { return }
        preObserverCount = nil
        for violation in RuntimeQuiescenceAuditor.observerLeakViolations(netObserverAdds: post - pre) {
            NSLog("[WS0-OBSERVER-DIAG] %@ left net observer adds (%d→%d) [%@] — see PalaceTestCase.warnOnObserverLeak (warn-only pending FP audit).",
                  self.name, pre, post, violation.invariant)
        }
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

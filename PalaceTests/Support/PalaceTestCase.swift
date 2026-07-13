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
        // Class-4 (accumulation pool-starvation) HARD gate — OPT-IN. Runs only
        // for classes that override `enforcesPoolResponsiveness` to `true`
        // (default `false`), so it cannot destabilize the ~7k-execution suite
        // before a zero-false-positive audit clears it. Every test still gets
        // the process-wide WARN-only `[WS0-POOL-DIAG]` breadcrumb from the
        // observer regardless of this flag.
        if enforcesPoolResponsiveness {
            assertRuntimeResponsive()
        }
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

    // MARK: - Pool-responsiveness gate-extension (WS-0 class 4, OPT-IN)

    /// Opt-in switch for the pool-responsiveness HARD gate. Default `false`.
    ///
    /// Off-by-default on purpose. The probe (`assertRuntimeResponsive`) carries a
    /// wall-clock deadline, and promoting a wall-clock probe to a suite-wide hard
    /// gate before a zero-false-positive audit is exactly the premature-hard-gate
    /// mistake the runtime-quiescence ADR warns against ("start warn-only, like
    /// the NotificationCenter audit, then promote"). The process-wide WARN-only
    /// `[WS0-POOL-DIAG]` diagnostic in `PalaceSingletonResetObserver` already
    /// covers EVERY test cheaply. A class that has proven its own teardown leaves
    /// the cooperative pool at rest overrides this to `true` — so that an
    /// accumulation leak it (or a predecessor) introduces surfaces as an
    /// ATTRIBUTED failure in its own tearDown, instead of a silent 120s/300s hang
    /// in a random downstream async victim.
    ///
    /// Overriding is the ENTIRE opt-in — no per-test boilerplate:
    /// ```swift
    /// final class MyAsyncPoolTests: PalaceTestCase {
    ///     override var enforcesPoolResponsiveness: Bool { true }
    /// }
    /// ```
    var enforcesPoolResponsiveness: Bool { false }

    /// Bounded check that the runtime is at rest — the class-4 (accumulation
    /// pool-starvation) gate extension. Two cheap probes run in sequence:
    ///
    /// 1. **Main-queue drain** (`drainMainQueue`) — proves the main queue still
    ///    flushes; a wedged main thread is its own hang class.
    /// 2. **Cooperative-pool probe** — schedules a high-priority detached `Task`
    ///    and waits, ON THE MAIN THREAD (via `XCTWaiter().wait` inside
    ///    `measureCooperativePoolProbe`), up to `budget` for it to run. Blocking
    ///    MAIN — not a pool worker — is load-bearing: a free pool thread can
    ///    still run the probe, so a timeout means the pool is genuinely saturated
    ///    by leaked blocking Tasks, not merely that main is busy.
    ///
    /// If the pool did not schedule the probe within `budget`, this fails the
    /// CURRENT test's tearDown, naming the resource (cooperative thread pool) and
    /// the remediation — converting a silent downstream hang into an attributed
    /// upstream failure in the test whose boundary first saw the pool saturated.
    ///
    /// SYMPTOM, not root: it detects "runtime not at rest," not "test X leaked
    /// Task Y." Under gradual accumulation it fires at whichever test's tearDown
    /// FIRST sees the pool saturated — often the last big leaker, not the first.
    /// It narrows the suspect window; pair with the seed-replay bisection
    /// (Deliverable B) to name the exact leaker.
    ///
    /// **Do NOT call from an `@MainActor async` test body** — the synchronous
    /// main-blocking wait deadlocks there (same caveat as `drainMainQueue` vs
    /// `drainMainQueueAsync`). Use `assertRuntimeResponsiveAsync` instead.
    ///
    /// - Parameters:
    ///   - budget: max seconds to wait for main-drain and for the pool to
    ///     schedule the probe. Default 5s — a hung pool is *indefinite*, while
    ///     legitimate background work finishes in <1s, so 5s cleanly separates
    ///     them while tolerating CI-runner load.
    ///   - probe: injection seam for the unit self-test — maps a budget to "did
    ///     the pool schedule the probe within it." Defaults to the real
    ///     cooperative-pool probe. The self-test passes a stub (`{ _ in false }`
    ///     / `{ _ in true }`) to prove the probe→detector→`XCTFail` wiring fires
    ///     AND does not false-positive, without staging a real leak.
    /// - Returns: the violations produced (also surfaced via `XCTFail`), so the
    ///   self-test can assert the message shape without capturing the failure.
    @discardableResult
    func assertRuntimeResponsive(
        budget: TimeInterval = 5.0,
        probe: ((TimeInterval) -> Bool)? = nil,
        file: StaticString = #file,
        line: UInt = #line
    ) -> [RuntimeQuiescenceAuditor.Violation] {
        // 1. Main-queue drain — reuses the sleep-free FIFO drain helper.
        drainMainQueue(timeout: budget)
        // 2. Cooperative-pool probe (real, unless a stub is injected for the
        //    self-test).
        let poolScheduledProbe = (probe ?? {
            PalaceSingletonResetObserver.measureCooperativePoolProbe(budget: $0).completed
        })(budget)
        let violations = RuntimeQuiescenceAuditor.poolResponsivenessViolations(
            probeCompleted: poolScheduledProbe
        )
        for v in violations {
            XCTFail(
                "Runtime-quiescence gate [\(v.invariant)]: \(v.detail)",
                file: file,
                line: line
            )
        }
        return violations
    }

    /// Async sibling of `assertRuntimeResponsive` for `@MainActor async` test
    /// bodies / async teardown, where the synchronous main-blocking wait would
    /// deadlock.
    ///
    /// `@MainActor` is load-bearing: the bounded poll's `Task.sleep` resumptions
    /// hop back to the MAIN actor (free, because we `await` rather than block
    /// it), so the poll itself can never be starved by the very cooperative-pool
    /// saturation it is trying to detect — the async analogue of the sync
    /// version's "block MAIN, not a pool worker" principle. The probe Task is
    /// `detached` (runs on the pool); if the pool is saturated it never flips the
    /// flag and we time out at `budget` → violation.
    ///
    /// - Returns: the violations produced (also surfaced via `XCTFail`).
    @MainActor
    @discardableResult
    func assertRuntimeResponsiveAsync(
        budget: TimeInterval = 5.0,
        file: StaticString = #file,
        line: UInt = #line
    ) async -> [RuntimeQuiescenceAuditor.Violation] {
        await drainMainQueueAsync(timeout: budget)
        let completed = await Self.pollCooperativePoolProbe(budget: budget)
        let violations = RuntimeQuiescenceAuditor.poolResponsivenessViolations(
            probeCompleted: completed
        )
        for v in violations {
            XCTFail(
                "Runtime-quiescence gate [\(v.invariant)]: \(v.detail)",
                file: file,
                line: line
            )
        }
        return violations
    }

    /// Detached-probe + bounded MAIN-actor poll behind `assertRuntimeResponsiveAsync`.
    /// Returns whether the cooperative pool scheduled the probe within `budget`.
    /// The `Task.sleep` resumes on the MAIN actor (this method is `@MainActor`),
    /// so the poll loop is never starved by the pool it measures.
    @MainActor
    private static func pollCooperativePoolProbe(budget: TimeInterval) async -> Bool {
        let flag = PoolProbeFlag()
        Task.detached(priority: .high) { flag.markScheduled() }
        let deadline = Date().addingTimeInterval(budget)
        while Date() < deadline {
            if flag.wasScheduled { return true }
            // 5ms; resumes on MAIN because this method is @MainActor.
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return flag.wasScheduled
    }
}

/// Thread-safe one-shot flag for the async cooperative-pool probe. `NSLock`-based
/// (no executor dependency) so reading/writing it can never itself be starved by
/// the cooperative pool the probe is measuring.
private final class PoolProbeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled = false
    func markScheduled() {
        lock.lock(); defer { lock.unlock() }
        scheduled = true
    }
    var wasScheduled: Bool {
        lock.lock(); defer { lock.unlock() }
        return scheduled
    }
}

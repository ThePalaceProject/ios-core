//
//  RuntimeQuiescenceGateTests.swift
//  PalaceTests
//
//  Self-test for the WS-0 / M0 runtime-quiescence gate. Proves the auditor
//  actually FAILS a synthetic polluter AND passes on clean state — without
//  this, a refactor that broke the detector would pass-by-default and the gate
//  would report green forever while catching nothing (the exact failure mode
//  `AppContainerIsolationLintTests.testLintCatchesSyntheticViolation` guards
//  against for the production() lint, and the inert-gate class the green-board
//  contract exists to prevent).
//
//  Subclasses `PalaceTestCase` on purpose: `testCaptureDeferFlag_reflectsLive…`
//  sets the defer flag `false` to prove `captureDeferFlag()` reads live state,
//  so per `RuntimeQuiescenceLintTests` this class MUST adopt the quiescence
//  base. It restores the flag via `defer` before tearDown, so the inherited
//  quiescence assert passes — i.e. this file also dogfoods the gate.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

@MainActor
final class RuntimeQuiescenceGateTests: PalaceTestCase {

    // MARK: - Detector proves it FIRES on a synthetic polluter

    /// The decisive self-test: a test that LEFT the defer flag `false`
    /// (synthetic polluter) MUST produce exactly one violation. If this ever
    /// returns empty, the gate is inert.
    func testDeferFlagViolations_flagLeftFalse_producesExactlyOneViolation() {
        let violations = RuntimeQuiescenceAuditor.deferFlagViolations(deferFlagLeftByTest: false)

        XCTAssertEqual(
            violations.count, 1,
            "A test that left deferInitialLoadCatalogsForTesting=false is the documented "
            + "polluter — the auditor MUST flag exactly one violation"
        )
        XCTAssertEqual(
            violations.first?.invariant,
            "AccountsManager.deferInitialLoadCatalogsForTesting == true",
            "The flagged invariant must name the defer-flag rule"
        )
    }

    /// The violation message must be ACTIONABLE — name the flag and the
    /// remediation — so the engineer who lands a polluter knows the fix from
    /// the failure line alone.
    func testDeferFlagViolations_message_isActionable() {
        let violation = RuntimeQuiescenceAuditor.deferFlagViolations(deferFlagLeftByTest: false).first
        let detail = violation?.detail ?? ""

        XCTAssertTrue(
            detail.contains("deferInitialLoadCatalogsForTesting"),
            "Remediation must name the flag to restore"
        )
        XCTAssertTrue(
            detail.contains("tearDown") || detail.contains("defer"),
            "Remediation must tell the engineer WHERE to restore the flag"
        )
    }

    // MARK: - Detector proves it does NOT false-positive on clean state

    /// Symmetric self-test: a quiescent test (flag left `true`) MUST produce
    /// no violations. A gate that fires on clean state would redden the whole
    /// board and train everyone to ignore it — the anti-pattern the
    /// green-board contract exists to prevent.
    func testDeferFlagViolations_flagLeftTrue_producesNoViolations() {
        let violations = RuntimeQuiescenceAuditor.deferFlagViolations(deferFlagLeftByTest: true)

        XCTAssertTrue(
            violations.isEmpty,
            "A quiescent test (defer flag left true) must NOT trip the gate"
        )
    }

    // MARK: - Live capture reads the real symbol

    /// Proves `captureDeferFlag()` reflects the LIVE flag value (not a
    /// hard-coded constant) so the tearDown gate audits real state. Flips the
    /// flag, captures, and restores via `defer` BEFORE tearDown so this test
    /// itself leaves the suite quiescent (and the inherited PalaceTestCase
    /// assert stays green).
    func testCaptureDeferFlag_reflectsLiveFlagValue() {
        // No `#if DEBUG` — the PalaceTests target does not define DEBUG, so a
        // guard here would compile the body out and make this a no-op test
        // (the inertness bug the wiring proof caught). The flag symbol is
        // reachable via `@testable import Palace`.
        let original = AccountsManager.deferInitialLoadCatalogsForTesting
        defer { AccountsManager.deferInitialLoadCatalogsForTesting = original }

        AccountsManager.deferInitialLoadCatalogsForTesting = false
        XCTAssertFalse(
            RuntimeQuiescenceAuditor.captureDeferFlag(),
            "captureDeferFlag() must read the live false value"
        )

        AccountsManager.deferInitialLoadCatalogsForTesting = true
        XCTAssertTrue(
            RuntimeQuiescenceAuditor.captureDeferFlag(),
            "captureDeferFlag() must read the live true value"
        )
    }

    // MARK: - Pool-responsiveness gate-extension (class 4) self-tests

    /// Pure detector: an incomplete probe (pool saturated) MUST produce exactly
    /// one violation; a completed probe MUST produce none. Proves the detector
    /// fires without staging a real leak.
    func testPoolResponsivenessViolations_bothDirections() {
        XCTAssertEqual(
            RuntimeQuiescenceAuditor.poolResponsivenessViolations(probeCompleted: false).count, 1,
            "A pool that did not schedule the probe (saturated) MUST flag one violation")
        XCTAssertTrue(
            RuntimeQuiescenceAuditor.poolResponsivenessViolations(probeCompleted: true).isEmpty,
            "A responsive pool MUST NOT flag a violation")
    }

    // MARK: - Observer-leak detector (leaked-observer class) self-tests

    /// Pure detector: net-new observers (>0) MUST flag exactly one violation;
    /// zero or negative MUST flag none. Proves the detector fires without
    /// staging a real leak — so promoting `warnOnObserverLeak` to a hard XCTFail
    /// (after the FP audit) is a one-line change with proven semantics.
    func testObserverLeakViolations_bothDirections() {
        XCTAssertEqual(
            RuntimeQuiescenceAuditor.observerLeakViolations(netObserverAdds: 1).count, 1,
            "A test that left net-new NotificationCenter observers MUST flag one violation")
        XCTAssertEqual(
            RuntimeQuiescenceAuditor.observerLeakViolations(netObserverAdds: 3).count, 1,
            "Any positive net-add count flags exactly one violation")
        XCTAssertTrue(
            RuntimeQuiescenceAuditor.observerLeakViolations(netObserverAdds: 0).isEmpty,
            "A balanced test (no net adds) MUST NOT trip the gate")
        XCTAssertTrue(
            RuntimeQuiescenceAuditor.observerLeakViolations(netObserverAdds: -2).isEmpty,
            "A test that NET-REMOVED observers MUST NOT trip the gate")
    }

    /// The violation message must name the remediation paths (injected center /
    /// remove in tearDown / break the retain cycle) so the failure is actionable.
    func testObserverLeakViolations_message_isActionable() {
        let detail = RuntimeQuiescenceAuditor.observerLeakViolations(netObserverAdds: 1).first?.detail ?? ""
        XCTAssertTrue(detail.contains("tearDown") || detail.contains("retain cycle"),
                      "Remediation must point at tearDown removal or the retain-cycle break")
    }

    /// NON-INERTNESS proof for the live observer-count sampling: a real
    /// `NotificationCenter.default` observer add must move the sampled count by
    /// +1. Without this, a `sampleObserverCount()` that always returned a
    /// constant (or nil) would make the observer-leak gate silently inert — the
    /// canonical inert-gate trap. If the runtime-private parse is unavailable on
    /// this host the sample is `nil` and the gate correctly SKIPS (no false
    /// fail), which this test records via XCTSkip rather than a fake pass.
    func testSampleObserverCount_reflectsLiveObserverAdd_orSkips() throws {
        guard let before = PalaceSingletonResetObserver.sampleObserverCount() else {
            throw XCTSkip("NotificationCenter observer count unavailable on this host — "
                          + "the warn/gate correctly skips (nil sample ⇒ no violation).")
        }
        let token = NotificationCenter.default.addObserver(
            forName: Notification.Name("WS0-observer-selftest"),
            object: nil, queue: nil
        ) { _ in }
        defer { NotificationCenter.default.removeObserver(token) }

        let after = PalaceSingletonResetObserver.sampleObserverCount()
        XCTAssertEqual(
            after.map { $0 - before }, 1,
            "sampleObserverCount() must reflect a live observer add (+1) — else the "
            + "observer-leak gate is inert. Got before=\(before), after=\(String(describing: after))."
        )
    }

    /// Live probe, clean pool: the high-priority probe Task schedules within
    /// budget. Confirms the probe is not a constant-false (which would make the
    /// gate-extension a permanent false-positive).
    func testCooperativePoolProbe_cleanPool_completesFast() {
        let probe = PalaceSingletonResetObserver.measureCooperativePoolProbe(budget: 2.0)
        XCTAssertTrue(probe.completed,
                      "On a clean cooperative pool the probe must complete within budget (latency=\(probe.latencyMs)ms)")
    }

    /// Live probe, RED-first: saturate the cooperative pool with
    /// `activeProcessorCount + 2` blocking Tasks → the high-priority probe must
    /// NOT schedule within budget (detector fires). Fully hermetic — every
    /// blocking Task is released AND drained before the test returns, so it
    /// leaks nothing into the next test (it must not become the very polluter
    /// it simulates).
    func testCooperativePoolProbe_saturatedPool_doesNotComplete_redFirst() {
        // HEAVILY over-saturate: spawn 8× the core count in blocking Tasks, far
        // more than any plausible cooperative-pool width. The pool is fixed-width
        // and does NOT spin up new threads for blocked ones (the pool-starvation
        // hazard), so we wait for only `cores` started-signals (waiting for `n`
        // would deadlock — queued Tasks can't start until a thread frees). The
        // surplus queued blockers immediately re-fill any thread that transiently
        // frees, so saturation is SUSTAINED for the whole probe window.
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let n = cores * 8
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        for _ in 0..<n {
            Task.detached(priority: .high) {
                started.signal()
                // Swift 6 bans DispatchSemaphore.wait() DIRECTLY in an async
                // context (it blocks a cooperative-pool thread — exactly the
                // anti-pattern this meta-test simulates). Route it through a
                // synchronous helper so the noasync call sits in a sync context
                // while still blocking the pool thread as intended.
                blockCooperativeThread(on: release)   // the simulated leak
                finished.signal()
            }
        }
        for _ in 0..<cores { started.wait() }   // at least `cores` threads occupied

        // Probe up to 5×; saturation is sustained (blockers held), so the probe
        // must time out at least once. Needing just ONE timeout makes this
        // robust to a transient thread-free blip during the saturation ramp —
        // not flaky (the earlier single-probe version raced on that ramp).
        var sawTimeout = false
        var lastLatencyMs = 0
        for _ in 0..<5 {
            let probe = PalaceSingletonResetObserver.measureCooperativePoolProbe(budget: 1.0)
            lastLatencyMs = probe.latencyMs
            if !probe.completed { sawTimeout = true; break }
        }

        // Release every blocker (running AND queued) and drain them fully so this
        // test leaks nothing — it must not become the polluter it simulates.
        for _ in 0..<n { release.signal() }
        for _ in 0..<n { finished.wait() }

        XCTAssertTrue(sawTimeout,
                      "Under sustained pool saturation by \(n) blocking Tasks, the probe must time out at least once across 5 attempts (last latency=\(lastLatencyMs)ms); the detector fires")
    }

    /// End-to-end of the pure path: with the flag at its restored `true`
    /// value, `auditLiveState()` returns no violations — the steady-state the
    /// whole suite must satisfy after every test.
    func testAuditLiveState_withFlagRestored_isQuiescent() {
        let original = AccountsManager.deferInitialLoadCatalogsForTesting
        defer { AccountsManager.deferInitialLoadCatalogsForTesting = original }
        AccountsManager.deferInitialLoadCatalogsForTesting = true

        XCTAssertTrue(
            RuntimeQuiescenceAuditor.auditLiveState().isEmpty,
            "With the defer flag at its test-safe true value, the live audit must be clean"
        )
    }
}

/// Synchronous wrapper so a `DispatchSemaphore.wait()` (marked `@available(*,
/// noasync)`) can be invoked from inside an async `Task` — the call sits in this
/// SYNC context, satisfying Swift 6, while still blocking the calling
/// (cooperative-pool) thread, which is the behavior RuntimeQuiescenceGateTests
/// deliberately exercises.
private func blockCooperativeThread(on semaphore: DispatchSemaphore) {
    semaphore.wait()
}

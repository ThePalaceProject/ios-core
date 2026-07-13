//
//  PoolResponsivenessProbeTests.swift
//  PalaceTests
//
//  Unit self-tests for the WS-0 class-4 pool-responsiveness GATE — the opt-in
//  `PalaceTestCase.assertRuntimeResponsive` seam that converts a silent
//  cross-test cooperative-pool hang into an ATTRIBUTED `tearDown` failure
//  (docs/architecture/runtime-quiescence-gate-backlog.md, Deliverable A).
//
//  These exercise the probe's OWN decision logic — probe → pure detector →
//  `XCTFail` — in isolation, via an injected responsiveness stub, so the wiring
//  is proven RED (a saturated pool trips the gate) AND GREEN (a responsive pool
//  does not) WITHOUT staging a real cross-test leak. That is the same
//  synthetic-input, both-directions self-test discipline `RuntimeQuiescenceGateTests`
//  applies to the defer-flag gate, and the green-board contract (#4) requires:
//  an inert gate satisfies "it compiles" AND "the suite is green," so the ONLY
//  trustworthy evidence is a run where a planted violation made it RED.
//
//  The live-pool probe itself (`measureCooperativePoolProbe` clean vs saturated)
//  is covered by `RuntimeQuiescenceGateTests`; this file covers the GATE layer
//  that decides + attributes on top of that probe.
//
//  Test-target-only. Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class PoolResponsivenessProbeTests: PalaceTestCase {

    // MARK: - Wiring: probe → detector → attributed XCTFail (RED)

    /// The decisive wiring proof: an injected "pool did NOT schedule the probe"
    /// stub MUST make `assertRuntimeResponsive` record exactly one attributed
    /// failure, whose message names the cooperative pool and the remediation. If
    /// this ever passes WITHOUT a recorded failure, the gate is inert (the exact
    /// fake-gate failure the WS-0 wall-failure documents).
    func testAssertRuntimeResponsive_saturatedStub_recordsAttributedFailure() {
        var captured: [RuntimeQuiescenceAuditor.Violation] = []

        XCTExpectFailure("A saturated-pool stub MUST trip the pool-responsiveness gate") {
            // Stub reports the pool never scheduled the probe within budget.
            captured = assertRuntimeResponsive(budget: 5.0, probe: { _ in false })
        }

        XCTAssertEqual(
            captured.count, 1,
            "A pool that did not schedule the probe must produce exactly one violation"
        )
        XCTAssertEqual(
            captured.first?.invariant,
            "cooperative pool at rest (probe schedules within budget)",
            "The violation must name the cooperative-pool invariant so the failure is self-explaining"
        )
        let detail = captured.first?.detail ?? ""
        XCTAssertTrue(
            detail.contains("cooperative"),
            "Remediation must name the saturated resource (the cooperative thread pool)"
        )
        XCTAssertTrue(
            detail.contains("tearDown") || detail.contains("cancel") || detail.contains("await"),
            "Remediation must tell the engineer HOW to fix the leak (cancel/await the leaked Tasks in tearDown)"
        )
    }

    // MARK: - Wiring: responsive pool does NOT false-positive (GREEN)

    /// Symmetric clean-path proof: an injected "pool scheduled the probe" stub
    /// MUST produce no violation and record no failure. A gate that fires on a
    /// healthy pool would redden the board and train everyone to ignore it — the
    /// anti-pattern the green-board contract exists to prevent.
    func testAssertRuntimeResponsive_healthyStub_recordsNoFailure() {
        let violations = assertRuntimeResponsive(budget: 5.0, probe: { _ in true })

        XCTAssertTrue(
            violations.isEmpty,
            "A responsive-pool stub must NOT trip the gate (no false positive)"
        )
    }

    // MARK: - The DEFAULT probe is the real cooperative-pool probe (not constant-false)

    /// Exercises the REAL default probe path (no stub) on a clean pool: the
    /// high-priority detached Task schedules well within budget, so there is no
    /// violation. This kills a mutation that hard-codes the default probe to
    /// `false` (which would make the gate a permanent false-positive) — the stub
    /// tests alone cannot catch that, because they replace the default.
    func testAssertRuntimeResponsive_realProbeOnCleanPool_isResponsive() {
        let violations = assertRuntimeResponsive(budget: 5.0)

        XCTAssertTrue(
            violations.isEmpty,
            "On a clean cooperative pool the real default probe must complete within budget → no violation"
        )
    }

    /// Async sibling exercised on a clean pool: `assertRuntimeResponsiveAsync`
    /// (the `@MainActor async` path for async test bodies) must also report the
    /// runtime responsive when the pool is at rest. Proves the async decision
    /// path is wired to the same pure detector and is not constant-failing.
    @MainActor
    func testAssertRuntimeResponsiveAsync_realProbeOnCleanPool_isResponsive() async {
        let violations = await assertRuntimeResponsiveAsync(budget: 5.0)

        XCTAssertTrue(
            violations.isEmpty,
            "On a clean cooperative pool the async probe must schedule within budget → no violation"
        )
    }

    // MARK: - Rollout safety: the hard gate is OFF by default

    /// The pool-responsiveness HARD gate must stay OFF by default so it cannot
    /// destabilize the ~7k-execution suite before a zero-false-positive audit
    /// promotes it. Opt-in is per-class via overriding
    /// `enforcesPoolResponsiveness`. This class does NOT override it, so it must
    /// read `false`. Kills a mutation that flips the base default to `true`
    /// (which would silently arm the wall-clock gate suite-wide).
    func testEnforcesPoolResponsiveness_isOffByDefault() {
        XCTAssertFalse(
            enforcesPoolResponsiveness,
            "The pool-responsiveness hard gate must be off-by-default; opt in per-class by "
            + "overriding enforcesPoolResponsiveness to true only after proving the class leaves the pool at rest"
        )
    }
}

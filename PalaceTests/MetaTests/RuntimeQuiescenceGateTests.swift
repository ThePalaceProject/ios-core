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

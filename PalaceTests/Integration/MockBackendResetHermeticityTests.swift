//
//  MockBackendResetHermeticityTests.swift
//  PalaceTests
//
//  Deterministic probe proving the finished-test observer clears two
//  process-global URLProtocol config stores between tests.
//
//  The hazard (PR #1119's abort class): a test that configures a
//  process-global URLProtocol store in setUp but aborts before its tearDown
//  leaks that config. For `MockBackendURLProtocol`, `canInit(with:)` is
//  gated on `activeScenario != nil`, so a leaked scenario intercepts EVERY
//  later request in the run — serving fixtures / canned 401s and corrupting
//  any network-dependent test that happens to run next. For
//  `ChaosURLProtocol`, a leaked fault `_plan` faults later requests.
//
//  Why this drives `SingletonResetRegistry.shared.invokeAll()` directly
//  rather than relying on a test_A→test_B ordering:
//  `PalaceSingletonResetObserver.testCaseDidFinish(_:)` clears leaks by
//  calling `SingletonResetRegistry.shared.invokeAll()` — that single call IS
//  the observer's reset behavior. The Palace scheme runs tests with
//  `testExecutionOrdering = "random"`, so a two-test alphabetical-ordering
//  probe would be flaky (test_B could run first and pass trivially).
//  Driving `invokeAll()` in-test exercises the exact production seam the
//  observer uses, order-independently.
//
//  Teeth: with the `MockBackendURLProtocol._resetForTesting` registration in
//  `PalaceTestSetup.registerBuiltInResetters()` commented out,
//  `testInvokeAll_clearsLeakedMockScenario` FAILS (invokeAll no longer
//  clears the scenario). Restored, it PASSES. Proven live.
//
//  NOT `#if DEBUG`-gated: the PalaceTests target does not define DEBUG
//  (compilation conditions are "LCP FEATURE_OVERDRIVE"), so a `#if DEBUG`
//  guard would compile this whole class away and it would silently run zero
//  tests. `MockScenario` / `MockBackendURLProtocol` are visible here
//  unconditionally via `@testable import Palace` (Palace is built in Debug
//  for the test bundle), exactly as `MockBackendTestHelper` references them.
//

import XCTest
@testable import Palace

final class MockBackendResetHermeticityTests: XCTestCase {

    /// Proves the registered MockBackend resetter clears a leaked
    /// process-global config when the finished-test observer fires
    /// `invokeAll()`. Drives the exact seam
    /// `PalaceSingletonResetObserver.testCaseDidFinish(_:)` uses.
    func testInvokeAll_clearsLeakedMockScenario() {
        // Simulate an aborted test that activated a scenario (plus the
        // sibling statics `activate(...)` sets) and never deactivated.
        let scenario = MockScenario(
            id: "leak_probe",
            displayName: "Leak Probe",
            description: "Deliberate leak to prove the observer's invokeAll() clears it.",
            routes: []
        )
        MockBackendURLProtocol.activeScenario = scenario
        MockBackendURLProtocol.scopedHost = "leaked.example.org"
        MockBackendURLProtocol.fixtureDirectoryPath = "/tmp/leaked-fixtures"

        XCTAssertNotNil(
            MockBackendURLProtocol.activeScenario,
            "Sanity: the scenario is set before the reset seam runs."
        )

        // The observer's reset behavior, verbatim.
        SingletonResetRegistry.shared.invokeAll()

        XCTAssertNil(
            MockBackendURLProtocol.activeScenario,
            "invokeAll() must clear a leaked activeScenario. If nil-check fails, the " +
            "SingletonResetRegistry registration for MockBackendURLProtocol is missing — " +
            "an aborted test leaks its mock scenario process-wide and intercepts every " +
            "later request."
        )
        XCTAssertNil(
            MockBackendURLProtocol.scopedHost,
            "invokeAll() must clear a leaked scopedHost."
        )
        XCTAssertNil(
            MockBackendURLProtocol.fixtureDirectoryPath,
            "invokeAll() must clear a leaked fixtureDirectoryPath."
        )
        XCTAssertEqual(
            MockBackendURLProtocol.fixtureBundle,
            Bundle.main,
            "invokeAll() must restore fixtureBundle to its .main default."
        )
    }

    /// Proves the registered ChaosURLProtocol resetter clears a leaked fault
    /// plan / request counter when `invokeAll()` fires. Drives one request
    /// through a chaos session to bump the process-global request counter,
    /// then asserts the reset seam zeroes it.
    func testInvokeAll_resetsLeakedChaosState() {
        // Leak: install a fault plan and drive one request so the
        // process-global counter is non-zero (observable proof of leaked state).
        ChaosURLProtocol.setPlan(ChaosURLProtocol.Plan(statusCode: 200))
        driveOneChaosRequest()

        XCTAssertGreaterThan(
            ChaosURLProtocol.currentRequestCount(), 0,
            "Sanity: the chaos request bumped the process-global counter."
        )

        // The observer's reset behavior, verbatim.
        SingletonResetRegistry.shared.invokeAll()

        XCTAssertEqual(
            ChaosURLProtocol.currentRequestCount(), 0,
            "invokeAll() must reset ChaosURLProtocol's process-global counter/plan. " +
            "If this fails, the SingletonResetRegistry registration for " +
            "ChaosURLProtocol.reset is missing — a leaked fault plan faults later requests."
        )
    }

    // MARK: - Helpers

    private func driveOneChaosRequest() {
        let session = ChaosHarness.chaosSession()
        let done = expectation(description: "chaos request completed")
        let task = session.dataTask(with: URL(string: "https://chaos.probe.invalid/x")!) { _, _, _ in
            done.fulfill()
        }
        task.resume()
        wait(for: [done], timeout: 5.0)
    }
}

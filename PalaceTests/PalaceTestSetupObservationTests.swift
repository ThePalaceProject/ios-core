import Foundation
import XCTest
@testable import Palace

/// Tests for `PalaceTestSetup.bootstrap()` and the
/// `PalaceSingletonResetObserver` it installs. The observer is itself a
/// process-wide hook on `XCTestObservationCenter.shared` — these tests
/// cannot uninstall it, so they instead reset the registry between
/// assertions and use a freshly-allocated observer for the
/// `testCaseDidFinish` direct-call assertions.
@MainActor
final class PalaceTestSetupObservationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Ensure the registry is empty before each assertion below — the
        // process-wide bootstrap registers 5 built-in resetters that would
        // otherwise pollute our `registeredNames()` snapshots and append to
        // any captured arrays. We restore those resetters in tearDown via
        // `PalaceTestSetup.bootstrap()` which is idempotent.
        SingletonResetRegistry.shared._removeAllForTests()
    }

    override func tearDown() {
        SingletonResetRegistry.shared._removeAllForTests()
        // Re-register the built-in resetters so the rest of the suite isn't
        // running without singleton hygiene.
        _ = PalaceTestSetup.bootstrap()
        super.tearDown()
    }

    // MARK: - 1. bootstrap() is idempotent — returns the same observer instance

    func testBootstrap_isIdempotent_returnsSameObserver() {
        let first = PalaceTestSetup.bootstrap()
        let second = PalaceTestSetup.bootstrap()
        XCTAssertTrue(
            first === second,
            "PalaceTestSetup.bootstrap() must return the same observer on repeat call (idempotence)"
        )
    }

    // MARK: - 2. testCaseDidFinish drives the registry in registration order

    func testTestCaseDidFinish_callsRegistryResettersInRegistrationOrder() {
        // The bootstrap-installed observer is on the shared center but we
        // can also exercise it directly — `testCaseDidFinish(_:)` is a plain
        // method call. We use a fresh local observer to keep the assertion
        // isolated from whatever the shared center is doing.
        let observer = PalaceSingletonResetObserver()
        var calls: [String] = []
        SingletonResetRegistry.shared.register("A") { calls.append("A") }
        SingletonResetRegistry.shared.register("B") { calls.append("B") }
        SingletonResetRegistry.shared.register("C") { calls.append("C") }

        // Drive the observer's hook with the current XCTestCase instance.
        // The observer ignores the argument's identity — it just sweeps the
        // registry — so passing `self` is fine.
        observer.testCaseDidFinish(self)

        XCTAssertEqual(
            calls, ["A", "B", "C"],
            "testCaseDidFinish must invoke registry resetters in registration order"
        )
    }

    // MARK: - 3. NotificationCenter observer-count audit fires on leaks

    /// Pins the audit behaviour: if a test leaks `N` observers, the audit
    /// must surface a delta of `N` via `XCTContext.runActivity` (visible in
    /// the test report). The audit is best-effort — if the `debugDescription`
    /// regex fails on this platform, the audit returns nil and the test is
    /// silently skipped here.
    func testTestCaseDidFinish_observerCountIncreases_recordsDelta() {
        let observer = PalaceSingletonResetObserver()
        observer.testCaseWillStart(self)

        // Add 3 dummy observers without removing them — this simulates a
        // test that leaked observers.
        final class DummyObserver {
            @objc func onNotification(_ note: Notification) {}
        }
        let dummies = [DummyObserver(), DummyObserver(), DummyObserver()]
        let leakName = Notification.Name("PalaceTestSetupObservationTests.leakProbe")
        for dummy in dummies {
            NotificationCenter.default.addObserver(
                dummy, selector: #selector(DummyObserver.onNotification(_:)),
                name: leakName, object: nil
            )
        }
        defer {
            // tearDown safety: remove the dummies so the registry-installed
            // observer doesn't keep firing this delta on EVERY subsequent
            // test in the suite.
            for dummy in dummies {
                NotificationCenter.default.removeObserver(dummy)
            }
        }

        // Drive the observer's `testCaseDidFinish`. If the debugDescription
        // parse worked, the observer caches the delta on itself for tests
        // to inspect; if the parse failed, the cached delta is nil and we
        // skip the assertion.
        observer.testCaseDidFinish(self)

        if let delta = observer.lastObservedDeltaForTesting {
            // The audit must surface a delta of AT LEAST 3 — the system may
            // also have added observers behind our back, so >= is correct.
            XCTAssertGreaterThanOrEqual(
                delta, 3,
                "Observer-count audit must capture the 3 leaked observers (saw delta=\(delta))"
            )
        } else {
            // On a platform where the regex parse failed, the audit is
            // silently skipped — the contract says "audit-only, never a
            // hard assertion." We log so the test signal is visible.
            NSLog("[PalaceTestSetupObservationTests] platform does not expose observer count; audit skipped")
        }
    }

    // MARK: - 4. Canary: AppContainer._resetForTesting yields a clean graph
    //
    // Owned by Module B (`Palace/AppInfrastructure/AppContainer.swift`)
    // and integrated here against Module B's `internal static func
    // _resetForTesting()` (DEBUG-only).

    @MainActor
    func testCanary_AppContainerResetForTesting_yieldsCleanGraph() {
        _ = PalaceTestSetup.bootstrap()
        let pre = AppContainer.production().accountsManager
        AppContainer._resetForTesting()
        let post = AppContainer.production().accountsManager
        XCTAssertFalse(
            pre === post,
            "AppContainer._resetForTesting must rebuild the cached graph"
        )
        // The new instance has `deferInitialLoadCatalogsForTesting = true`
        // set DURING the reset; the rebuilt graph then flips it back to
        // false. Either way, no async preload has run yet, so the accounts
        // array reflects only what `preloadAccountsFromDiskCacheSync()`
        // populated synchronously — which can be > 0 if a prior test wrote
        // to the on-disk catalog cache. The honest assertion is "the
        // rebuilt instance is observably different from the pre-instance,"
        // pinned by the identity assertion above.
    }
}

import XCTest
@testable import Palace

/// Tests for the `XCTestCase.testUserDefaults()` helper introduced by
/// swarm_47883816 Module D. These tests prove the helper actually
/// isolates state, does not leak into `.standard`, and registers a
/// working resetter into `SingletonResetRegistry.shared`.
///
/// The "SUT" here is the helper extension itself; the file name
/// (`XCTestCase+testUserDefaultsTests`) reflects that — the test
/// methods exercise `testUserDefaults()` directly.
@MainActor
final class XCTestCase_testUserDefaultsTests: XCTestCase {

    override func tearDown() {
        super.tearDown()
    }

    // MARK: - Isolation

    /// Two calls to `testUserDefaults()` inside the same test must
    /// produce two stores whose writes do NOT bleed into each other.
    func testTestUserDefaults_returnsIsolatedSuite() {
        let storeA = testUserDefaults()
        let storeB = testUserDefaults()

        // Arrange: write distinct values into each store under the same key.
        let key = "isolation-probe"
        storeA.set("value-a", forKey: key)
        storeB.set("value-b", forKey: key)

        // Assert: each store sees only its own write.
        XCTAssertEqual(storeA.string(forKey: key), "value-a",
                       "storeA must observe its own write under the shared key")
        XCTAssertEqual(storeB.string(forKey: key), "value-b",
                       "storeB must observe its own write — storeA's write must not bleed in")
    }

    // MARK: - No leak to `.standard`

    /// A write into a `testUserDefaults()` store must NOT be visible via
    /// `UserDefaults.standard`. This is the load-bearing isolation
    /// property — if it ever regresses, every test using the helper
    /// silently goes back to polluting `.standard`.
    func testTestUserDefaults_writesDoNotLeakToStandard() {
        let suiteKey = "leak-probe-\(UUID().uuidString)"
        // Belt-and-braces: ensure `.standard` does not already hold the
        // key before we start. Tests must own a fresh-state precondition.
        UserDefaults.standard.removeObject(forKey: suiteKey)

        // Act: write to the isolated store.
        let defaults = testUserDefaults()
        defaults.set("isolated-only", forKey: suiteKey)

        // Assert: `.standard` is still empty for this key.
        XCTAssertNil(
            UserDefaults.standard.string(forKey: suiteKey),
            "Writing to a testUserDefaults() store must NOT be visible via UserDefaults.standard"
        )

        // Sanity check: the isolated store DOES have the value.
        XCTAssertEqual(defaults.string(forKey: suiteKey), "isolated-only",
                       "Sanity: the isolated store must contain the written value")
    }

    // MARK: - Resetter wiring

    /// The helper must register a resetter with
    /// `SingletonResetRegistry.shared` that clears the suite. We can't
    /// observe the resetter firing at the end of *this* test (it runs
    /// in the observer after `testCaseDidFinish`), but we CAN drive the
    /// resetter directly and verify it wipes the suite.
    func testTestUserDefaults_resetterClearsSuiteOnTestEnd() {
        // Arrange: snapshot the registry names so we know which entry
        // the helper added.
        let beforeNames = Set(SingletonResetRegistry.shared.registeredNames())

        let defaults = testUserDefaults()
        defaults.set("survives-only-until-reset", forKey: "reset-probe")
        XCTAssertEqual(defaults.string(forKey: "reset-probe"), "survives-only-until-reset",
                       "Pre-reset: value must be present in the suite")

        let afterNames = Set(SingletonResetRegistry.shared.registeredNames())
        let added = afterNames.subtracting(beforeNames)

        // The helper must register exactly the resetters this test
        // call adds (one per `testUserDefaults()` invocation).
        XCTAssertEqual(added.count, 1,
                       "testUserDefaults() must register exactly one resetter per call. Added: \(added)")
        guard let addedName = added.first else {
            XCTFail("No resetter was registered")
            return
        }
        XCTAssertTrue(addedName.hasPrefix("testUserDefaults."),
                      "Resetter name must be namespaced under 'testUserDefaults.' — got '\(addedName)'")

        // Act: invoke the registry — this is what
        // `PalaceSingletonResetObserver.testCaseDidFinish` does at end of
        // every test. Driving it manually lets us see the effect.
        SingletonResetRegistry.shared.invokeAll()

        // Assert: the suite is empty.
        XCTAssertNil(
            defaults.string(forKey: "reset-probe"),
            "After resetter fires, the suite must be empty for the previously-set key"
        )
    }
}

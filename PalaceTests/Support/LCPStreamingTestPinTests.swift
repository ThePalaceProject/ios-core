import Foundation
import XCTest
@testable import Palace

/// Tests for the `PALACE_TEST_LCP_STREAMING` pin that `PalaceTestSetup`
/// applies to `lcp_audiobook_streaming_enabled` at bootstrap and after every
/// test. Production runs the flag ON; the default test run pins it OFF, and
/// CI's extra leg re-runs the flag consumers' suites with the pin ON.
final class LCPStreamingTestPinTests: XCTestCase {

    override func tearDownWithError() throws {
        // One test above writes the override on `.standard`; put it back.
        LCPStreamingTestPin.apply(LCPStreamingTestPin.selected, to: .standard)
        try super.tearDownWithError()
    }

    // MARK: - Parsing the environment value

    func testParse_WhenVariableAbsent_SelectsOff() {
        XCTAssertEqual(LCPStreamingTestPin.parse(nil), false)
    }

    func testParse_OnAndOff_SelectTheMatchingValue() {
        XCTAssertEqual(LCPStreamingTestPin.parse("on"), true)
        XCTAssertEqual(LCPStreamingTestPin.parse("off"), false)
    }

    func testParse_IgnoresCaseAndSurroundingWhitespace() {
        XCTAssertEqual(LCPStreamingTestPin.parse(" ON\n"), true)
        XCTAssertEqual(LCPStreamingTestPin.parse("Off"), false)
    }

    /// A misspelt value must not quietly run the suite OFF — that would make
    /// the ON leg report green while testing nothing new.
    func testParse_UnrecognisedValue_IsRejected() {
        for raw in ["", "true", "1", "yes", "enabled", "onn"] {
            XCTAssertNil(LCPStreamingTestPin.parse(raw), "'\(raw)' must be rejected, not read as off")
        }
    }

    // MARK: - Leaving the device as we found it
    //
    // On a simulator `.standard` for the test host IS the Palace app's own
    // container, so a pin left behind outlives the run and decides the flag
    // for whoever drives that device next.

    func testRestore_WhenThereWasNoOverride_RemovesTheKeyRatherThanWritingFalse() {
        let defaults = Self.testUserDefaults()
        let key = RemoteFeatureFlags.lcpAudiobookStreamingLocalOverrideKey
        let atLaunch = LCPStreamingTestPin.currentOverride(in: defaults)
        XCTAssertNil(atLaunch, "fixture precondition: no override to begin with")

        LCPStreamingTestPin.apply(true, to: defaults)
        XCTAssertNotNil(defaults.object(forKey: key), "precondition: the pin took effect")

        LCPStreamingTestPin.restore(atLaunch, to: defaults)

        XCTAssertNil(defaults.object(forKey: key),
                     "a device that had no override must end with none; writing false would "
                     + "pin the app to the download-first path after the run")
    }

    func testRestore_PutsBackAnOverrideTheDeviceAlreadyHad() {
        let defaults = Self.testUserDefaults()
        let key = RemoteFeatureFlags.lcpAudiobookStreamingLocalOverrideKey
        defaults.set(true, forKey: key)
        let atLaunch = LCPStreamingTestPin.currentOverride(in: defaults)

        LCPStreamingTestPin.apply(false, to: defaults)
        XCTAssertEqual(defaults.object(forKey: key) as? Bool, false, "precondition: the pin took effect")

        LCPStreamingTestPin.restore(atLaunch, to: defaults)

        XCTAssertEqual(defaults.object(forKey: key) as? Bool, true,
                       "the device's own override must survive the run")
    }

    /// `nil` and `false` are different device states, and reading the override
    /// must not collapse them — that collapse is what made a left-behind
    /// `false` look like a device that simply had no preference.
    func testCurrentOverride_DistinguishesAbsentFromFalse() {
        let defaults = Self.testUserDefaults()
        XCTAssertNil(LCPStreamingTestPin.currentOverride(in: defaults))

        LCPStreamingTestPin.apply(false, to: defaults)

        XCTAssertEqual(LCPStreamingTestPin.currentOverride(in: defaults), false,
                       "an explicit false must read as false, not as absent")
    }

    // MARK: - Applying the pin

    func testApply_On_MakesTheFlagReadOn_AndOffMakesItReadOffAgain() {
        let defaults = Self.testUserDefaults()
        let flags = RemoteFeatureFlags(defaults: defaults)

        LCPStreamingTestPin.apply(true, to: defaults)
        XCTAssertTrue(flags.isLCPAudiobookStreamingEnabled)

        LCPStreamingTestPin.apply(false, to: defaults)
        XCTAssertFalse(flags.isLCPAudiobookStreamingEnabled)
    }

    /// XCTest calls the installed observer's `testCaseWillStart` before every
    /// test, so each test starts at the selected value whatever a prior test
    /// left in `.standard` or in `SingletonResetRegistry`.
    func testObserverWillStart_RestoresTheSelectedPin_AfterAPriorTestFlippedIt() {
        let selected = LCPStreamingTestPin.selected
        UserDefaults.standard.set(!selected, forKey: RemoteFeatureFlags.lcpAudiobookStreamingLocalOverrideKey)
        XCTAssertEqual(RemoteFeatureFlags.shared.isLCPAudiobookStreamingEnabled, !selected, "precondition: flip took effect")

        PalaceSingletonResetObserver().testCaseWillStart(self)

        XCTAssertEqual(RemoteFeatureFlags.shared.isLCPAudiobookStreamingEnabled, selected)
    }

    // MARK: - ON-leg canary

    /// Runs only when the environment selects ON, i.e. in CI's ON leg. The
    /// workflow step checks this test's result is PASSED rather than SKIPPED,
    /// which is how it proves the variable reached the test host — if it had
    /// not, every test in the leg would silently run OFF.
    func testOnLegCanary_EnvironmentReachedTheHost_AndTheFlagReadsOn() throws {
        let raw = ProcessInfo.processInfo.environment[LCPStreamingTestPin.environmentKey]
        guard LCPStreamingTestPin.parse(raw) == true else {
            throw XCTSkip("\(LCPStreamingTestPin.environmentKey) does not select on; this canary runs in the ON leg only")
        }
        XCTAssertTrue(RemoteFeatureFlags.shared.isLCPAudiobookStreamingEnabled)
    }
}

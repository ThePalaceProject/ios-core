//
//  DeveloperSettingsViewModelTests.swift
//  PalaceTests
//
//  PP-4788: covers the SwiftUI Developer Settings view model that replaced
//  TPPDeveloperSettingsTableViewController. Two behavior surfaces matter:
//  (1) the feature-flag local overrides must write THROUGH to the same
//  UserDefaults keys RemoteFeatureFlags reads (a flip here must be
//  indistinguishable from the old UIKit screen), and (2) the engineering-tier
//  gating (`shouldShowEngineeringTools`) — ported verbatim from the retired VC,
//  so its test moves here too.
//

import XCTest
@testable import Palace

@MainActor
final class DeveloperSettingsEngineeringTierTests: XCTestCase {

    // Pure decision — no view-model construction, runs everywhere. Mirrors the
    // retired DeveloperSettingsTierTests, now pointed at the SwiftUI VM.

    func testEngineeringTools_noReceiptURL_isDeveloperBuild_shown() {
        // No App Store receipt at all → a dev build → tools shown.
        XCTAssertTrue(
            DeveloperSettingsViewModel.shouldShowEngineeringTools(receiptURL: nil, fileExists: { _ in false }),
            "A build with no receipt URL is a dev build and must show engineering tools")
    }

    func testEngineeringTools_sandboxReceipt_isTestFlight_shown() {
        let url = URL(fileURLWithPath: "/path/to/sandboxReceipt")
        XCTAssertTrue(
            DeveloperSettingsViewModel.shouldShowEngineeringTools(receiptURL: url, fileExists: { _ in true }),
            "A TestFlight build (sandboxReceipt) must show engineering tools")
    }

    func testEngineeringTools_realAppStoreReceipt_hidden() {
        // "receipt" named AND the file exists → real App Store install → hidden.
        let url = URL(fileURLWithPath: "/path/to/receipt")
        XCTAssertFalse(
            DeveloperSettingsViewModel.shouldShowEngineeringTools(receiptURL: url, fileExists: { _ in true }),
            "A production App Store install must HIDE engineering tools")
    }

    func testEngineeringTools_receiptNameButMissingFile_isDevSim_shown() {
        // DEBUG/sim reports a "receipt"-named URL whose file does NOT exist — the
        // name check alone wrongly hid the tools (caught via simdrive 2026-06-08).
        let url = URL(fileURLWithPath: "/path/to/receipt")
        XCTAssertTrue(
            DeveloperSettingsViewModel.shouldShowEngineeringTools(receiptURL: url, fileExists: { _ in false }),
            "A 'receipt'-named URL whose file is absent is a dev/sim build — tools must show")
    }
}

@MainActor
final class DeveloperSettingsViewModelOverrideTests: XCTestCase {

    private var suiteName: String!
    private var testDefaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // `makeViewModel()` builds against a TEST container, not `.production()`,
        // but `AccountsManager` can still round-trip TPPKeychain — skip on CI
        // hosts where SecItem returns -34018, same gate the sibling VM tests use.
        // The feature-flag write-through is exercised where these DO run (local,
        // where mutation is measured).
        try KeychainAvailability.skipIfUnavailable()
        suiteName = "test.DeveloperSettings.\(ProcessInfo.processInfo.globallyUniqueString)"
        testDefaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        testDefaults?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// Builds the VM against a TEST container, never `AppContainer.production()`.
    ///
    /// The init defaults four dependencies to `.production()` and `featureFlags`
    /// to `.shared`. Taking those defaults constructs a real `AccountsManager`,
    /// which starts the background `loadCatalogs` Task whenever
    /// `deferInitialLoadCatalogsForTesting` is false — and
    /// `AppContainerResetTests` sets it to false on purpose to exercise the
    /// un-deferred path. Full-suite, that background fetch raced this class and
    /// hung `AppContainerResetTests` for the full 120s timeout (CI run
    /// 35355866267). `makeTestAppContainer()` pins the flag before building the
    /// manager, so this class no longer contributes that race.
    ///
    /// Seeding from a test-scoped `RemoteFeatureFlags` also stops the `@Published`
    /// mirrors being initialised from `UserDefaults.standard` while the assertions
    /// read `testDefaults` — the write and the read now address one store.
    private func makeViewModel() -> DeveloperSettingsViewModel {
        let container = makeTestAppContainer()
        return DeveloperSettingsViewModel(
            settings: container.settings,
            accountsManager: container.accountsManager,
            bookRegistry: container.bookRegistry,
            debugSettings: container.debugSettings,
            featureFlags: RemoteFeatureFlags(defaults: testDefaults),
            overrideDefaults: testDefaults
        )
    }

    // Each feature-flag toggle must WRITE THROUGH to the RemoteFeatureFlags
    // local-override key in the injected store — the exact key the app reads.

    func testTriageBotToggle_writesThroughToLocalOverrideKey() {
        let vm = makeViewModel()
        let start = testDefaults.object(forKey: RemoteFeatureFlags.triageBotLocalOverrideKey) as? Bool
        vm.triageBotEnabled = !(vm.triageBotEnabled)
        XCTAssertEqual(
            testDefaults.object(forKey: RemoteFeatureFlags.triageBotLocalOverrideKey) as? Bool,
            vm.triageBotEnabled,
            "Flipping triageBotEnabled must write through to its local-override key")
        XCTAssertNotEqual(testDefaults.object(forKey: RemoteFeatureFlags.triageBotLocalOverrideKey) as? Bool, start)
    }

    func testInAppPlaybackNavToggle_writesThroughToLocalOverrideKey() {
        let vm = makeViewModel()
        vm.inAppPlaybackNavEnabled = true
        XCTAssertEqual(
            testDefaults.object(forKey: RemoteFeatureFlags.inAppPlaybackNavLocalOverrideKey) as? Bool, true,
            "Enabling In-App Playback Navigation must persist to its local-override key")
        vm.inAppPlaybackNavEnabled = false
        XCTAssertEqual(
            testDefaults.object(forKey: RemoteFeatureFlags.inAppPlaybackNavLocalOverrideKey) as? Bool, false,
            "Disabling it must persist false — the override is a real write, not a one-way set")
    }

    func testAppRatingForceEligibleToggle_writesThroughToLocalOverrideKey() {
        let vm = makeViewModel()
        vm.appRatingForceEligible = true
        XCTAssertEqual(
            testDefaults.object(forKey: RemoteFeatureFlags.appRatingForceEligibleLocalOverrideKey) as? Bool, true,
            "Force Rating Prompt Eligible must persist to its local-override key")
    }

    // PP-2677: side loading shipped in 3.3.0 with NO writer for its local
    // override outside tests, so the Settings section it gates was unreachable
    // in any build. These pin the toggle that makes it reachable.

    func testSideLoadingToggle_writesThroughToLocalOverrideKey() {
        let vm = makeViewModel()
        vm.sideLoadingEnabled = true
        XCTAssertEqual(
            testDefaults.object(forKey: RemoteFeatureFlags.sideLoadingLocalOverrideKey) as? Bool, true,
            "Enabling Side Loading must persist to its local-override key")
        vm.sideLoadingEnabled = false
        XCTAssertEqual(
            testDefaults.object(forKey: RemoteFeatureFlags.sideLoadingLocalOverrideKey) as? Bool, false,
            "Disabling it must persist false — QA must be able to turn the lane back OFF")
    }

    /// The write-through is only useful if the key it writes is the one
    /// `isSideLoadingEnabled` reads. Asserting the toggle alone would pass even
    /// if the VM wrote to a key nothing consults — the original defect's shape.
    func testSideLoadingToggle_isTheKeyTheFlagReaderConsults() {
        let vm = makeViewModel()
        let flags = RemoteFeatureFlags(defaults: testDefaults)

        vm.sideLoadingEnabled = true
        XCTAssertTrue(flags.isSideLoadingEnabled,
                      "Toggling ON must make isSideLoadingEnabled report true — the override outranks the remote flag")

        vm.sideLoadingEnabled = false
        XCTAssertFalse(flags.isSideLoadingEnabled,
                       "Toggling OFF must win over a remote-config true, not merely fall through to it")
    }
}

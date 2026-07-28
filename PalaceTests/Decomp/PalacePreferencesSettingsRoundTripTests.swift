//
//  PalacePreferencesSettingsRoundTripTests.swift
//  PalaceTests
//
//  PRE-WAVE gate tests for the god-class decomposition campaign — Wave 1a
//  (`PalacePreferences`). See docs/architecture/god-class-decomposition-plan.md
//  §4 Wave 1a and §3b cycles 5/6.
//
//  Purpose: pin TODAY's persistence contract of `TPPSettings` — the
//  `UserDefaults`-backed key-value preferences store — BEFORE it is lifted
//  into the new Layer-0 leaf package `PalacePreferences`. The move is a pure
//  relocation, so the risk it introduces is silent WIRE-FORMAT drift: a
//  renamed key constant, a changed default, or an in-memory cache slipped in
//  during the port would make every already-installed patron silently lose a
//  persisted preference. These tests lock the exact `UserDefaults` key strings,
//  the unset defaults, and the cross-instance persistence so any such drift
//  fails loudly.
//
//  Isolation: every test drives a fresh, per-test `UserDefaults(suiteName:)`
//  injected through `TPPSettings.init(defaults:)`. NONE of these tests touch
//  `.standard` — they cannot pollute the shared domain or any sibling test.
//  The suite is torn down with `removePersistentDomain` in `tearDown`.
//
//  Scope note: the passthrough accessors (e.g. `downloadOnlyOnWiFi`,
//  `appRatingOptedOut`) are NOT fluff-tested with a bare get-after-set — that
//  would exercise `UserDefaults`, not `TPPSettings`. Instead we pin the
//  set-typed-API / read-RAW-key mapping, which is the real portable contract
//  and which a key-rename mutation fails. Accessors with genuine logic
//  (`appRatingCrashFreeLastSession` default-true, `appRatingLastPromptDate`
//  nil-clear) get dedicated behavior tests.
//
//  Excluded by design: `TPPSettings+SE.settingsAccountIdsList` reads/writes
//  `UserDefaults.standard` directly (bypassing the injected `defaults`) AND
//  reaches `AppContainer.production()`, so it is NOT isolatable here and moves
//  to PalaceAccounts territory (the AccountsManager constant "stays behind" per
//  the plan). It is intentionally uncovered by this pack.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalacePreferences
@testable import Palace

@MainActor
final class PalacePreferencesSettingsRoundTripTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var settings: TPPSettings!

    override func setUp() {
        super.setUp()
        suiteName = "PalacePreferencesDecompTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        // Guarantee a clean slate even if the (random) suite name collided.
        defaults.removePersistentDomain(forName: suiteName)
        settings = TPPSettings(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        settings = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - appRatingCrashFreeLastSession — genuine default-true logic

    /// When no session has recorded a value, the accessor must assume the
    /// patron is crash-free (returns `true`) — the store special-cases the
    /// absent key rather than falling through to `UserDefaults.bool`'s `false`.
    /// Mutant killed: replacing the `== nil ? true : …` ternary (or flipping
    /// the default to `false`) makes an un-primed store report a crash.
    func testCrashFreeLastSession_defaultsToTrueWhenKeyAbsent() {
        XCTAssertNil(defaults.object(forKey: "TPPAppRatingCrashFreeLastSession"),
                     "Precondition: fresh suite has no stored crash-free value")
        XCTAssertTrue(settings.appRatingCrashFreeLastSession,
                      "Absent crash-free key must read as true (assume crash-free)")
    }

    /// A stored `false` must survive and be distinguishable from the absent
    /// default. Round-tripping false → true proves the accessor reflects the
    /// STORED value, not a constant. Mutant killed: an accessor hardcoded to
    /// `true` (or reading the wrong key) fails the `false` leg.
    func testCrashFreeLastSession_reflectsStoredFalseThenTrue() {
        settings.appRatingCrashFreeLastSession = false
        XCTAssertFalse(settings.appRatingCrashFreeLastSession,
                       "Stored false must read back false, not the absent-default true")
        XCTAssertEqual(defaults.object(forKey: "TPPAppRatingCrashFreeLastSession") as? Bool, false,
                       "Value must persist under the stable wire key")

        settings.appRatingCrashFreeLastSession = true
        XCTAssertTrue(settings.appRatingCrashFreeLastSession,
                      "Stored true must read back true")
    }

    // MARK: - appRatingLastPromptDate — nil-clear vs. store logic

    /// Setting a date persists it (under the stable key); setting nil must
    /// REMOVE it so the getter reads nil again. Mutant killed: dropping the
    /// `removeObject` nil-branch (leaving the stale date) fails the clear leg.
    func testLastPromptDate_roundTripsThenClearsToNil() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        settings.appRatingLastPromptDate = date

        let stored = settings.appRatingLastPromptDate
        XCTAssertNotNil(stored, "Set date must round-trip back out")
        XCTAssertEqual(stored!.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001,
                       "Persisted date must equal what was set")
        XCTAssertNotNil(defaults.object(forKey: "TPPAppRatingLastPromptDate") as? Date,
                        "Date must persist under the stable wire key")

        settings.appRatingLastPromptDate = nil
        XCTAssertNil(settings.appRatingLastPromptDate,
                     "Setting nil must clear the stored date")
        XCTAssertNil(defaults.object(forKey: "TPPAppRatingLastPromptDate"),
                     "Nil-set must REMOVE the key, not leave a stale value")
    }

    // MARK: - Feed URL accessors — persistence + stable wire key

    /// `customMainFeedURL` (custom catalog override) must persist a URL under
    /// its exact legacy key and read the same URL back. The notification/guard
    /// behavior of the setter is covered by `TPPSettingsTests`; here we pin the
    /// PERSISTENCE the package move must preserve. Mutant killed: a renamed key
    /// constant leaves the raw read nil.
    func testCustomMainFeedURL_persistsUnderStableKeyAndRoundTrips() {
        let url = URL(string: "https://catalog.example.org/custom-feed")!
        settings.customMainFeedURL = url

        XCTAssertEqual(settings.customMainFeedURL, url,
                       "customMainFeedURL must round-trip the set URL")
        XCTAssertEqual(defaults.url(forKey: "NYPLSettingsCustomMainFeedURL"), url,
                       "customMainFeedURL must persist under the legacy key 'NYPLSettingsCustomMainFeedURL'")
    }

    /// `accountMainFeedURL` is the `NYPLFeedURLProvider` protocol property that
    /// drives catalog fetches. Same wire-key + round-trip contract.
    func testAccountMainFeedURL_persistsUnderStableKeyAndRoundTrips() {
        let url = URL(string: "https://catalog.example.org/account-feed")!
        settings.accountMainFeedURL = url

        XCTAssertEqual(settings.accountMainFeedURL, url,
                       "accountMainFeedURL must round-trip the set URL")
        XCTAssertEqual(defaults.url(forKey: "NYPLSettingsAccountMainFeedURL"), url,
                       "accountMainFeedURL must persist under the legacy key 'NYPLSettingsAccountMainFeedURL'")
    }

    /// `useBetaLibraries` gates whether beta libraries appear in the registry;
    /// its persisted flag must land under the legacy key so a beta-opted patron
    /// keeps that state across the move.
    func testUseBetaLibraries_persistsUnderStableKey() {
        XCTAssertFalse(settings.useBetaLibraries, "Precondition: defaults to false when unset")
        settings.useBetaLibraries = true

        XCTAssertTrue(settings.useBetaLibraries, "useBetaLibraries must round-trip true")
        XCTAssertEqual(defaults.object(forKey: "NYPLUseBetaLibrariesKey") as? Bool, true,
                       "useBetaLibraries must persist under the legacy key 'NYPLUseBetaLibrariesKey'")
    }

    // MARK: - Wire-format key contract for the passthrough prefs

    /// The single most important guard for a persistence relocation: every
    /// stored preference must keep reading/writing its EXACT current
    /// `UserDefaults` key string. We drive each typed accessor with a
    /// non-default value, then read the RAW key literal (hardcoded here, NOT
    /// referenced from the SUT's constants — so a constant rename is caught,
    /// not moved-in-lockstep). Any single key drift fails this test.
    func testStoredPrefs_persistUnderExactWireKeys() {
        settings.userHasAcceptedEULA = true
        settings.userPresentedAgeCheck = true
        settings.enterLCPPassphraseManually = true
        settings.downloadOnlyOnWiFi = true
        settings.appVersion = "9.9.9-decomp"
        settings.customLibraryRegistryServer = "https://registry.example.org"
        settings.appRatingSessionCount = 7
        settings.appRatingBooksCompleted = 3
        settings.appRatingPromptDisplayCount = 2
        settings.appRatingDismissalCount = 1
        settings.appRatingOptedOut = true

        // Bool prefs → exact key + exact value.
        XCTAssertEqual(defaults.object(forKey: "NYPLSettingsUserAcceptedEULA") as? Bool, true,
                       "userHasAcceptedEULA key drift")
        XCTAssertEqual(defaults.object(forKey: "NYPLUserPresentedAgeCheckKey") as? Bool, true,
                       "userPresentedAgeCheck key drift")
        XCTAssertEqual(defaults.object(forKey: "TPPSettingsEnterLCPPassphraseManually") as? Bool, true,
                       "enterLCPPassphraseManually key drift")
        XCTAssertEqual(defaults.object(forKey: "TPPSettingsDownloadOnlyOnWiFi") as? Bool, true,
                       "downloadOnlyOnWiFi key drift")
        XCTAssertEqual(defaults.object(forKey: "TPPAppRatingOptedOut") as? Bool, true,
                       "appRatingOptedOut key drift")

        // String prefs.
        XCTAssertEqual(defaults.string(forKey: "NYPLSettingsVersionKey"), "9.9.9-decomp",
                       "appVersion key drift")
        XCTAssertEqual(defaults.string(forKey: "TPPSettingsCustomLibraryRegistryKey"),
                       "https://registry.example.org",
                       "customLibraryRegistryServer key drift")

        // Int prefs.
        XCTAssertEqual(defaults.integer(forKey: "TPPAppRatingSessionCount"), 7,
                       "appRatingSessionCount key drift")
        XCTAssertEqual(defaults.integer(forKey: "TPPAppRatingBooksCompleted"), 3,
                       "appRatingBooksCompleted key drift")
        XCTAssertEqual(defaults.integer(forKey: "TPPAppRatingPromptDisplayCount"), 2,
                       "appRatingPromptDisplayCount key drift")
        XCTAssertEqual(defaults.integer(forKey: "TPPAppRatingDismissalCount"), 1,
                       "appRatingDismissalCount key drift")
    }

    // MARK: - Unset defaults

    /// The "never written" contract: a fresh store returns the canonical
    /// empty/zero/false/nil values callers rely on before a patron has touched
    /// any setting. Distinct from the crash-free special-case (which is true).
    /// Mutant killed: a default value swapped in during the port (e.g. Int
    /// default 1, Bool default true) fails here.
    func testUnsetDefaults_areEmptyZeroFalseNil() {
        XCTAssertNil(settings.customMainFeedURL, "customMainFeedURL defaults nil")
        XCTAssertNil(settings.accountMainFeedURL, "accountMainFeedURL defaults nil")
        XCTAssertNil(settings.appVersion, "appVersion defaults nil")
        XCTAssertNil(settings.customLibraryRegistryServer, "customLibraryRegistryServer defaults nil")
        XCTAssertNil(settings.appRatingLastPromptDate, "appRatingLastPromptDate defaults nil")
        XCTAssertFalse(settings.useBetaLibraries, "useBetaLibraries defaults false")
        XCTAssertFalse(settings.userHasAcceptedEULA, "userHasAcceptedEULA defaults false")
        XCTAssertFalse(settings.userPresentedAgeCheck, "userPresentedAgeCheck defaults false")
        XCTAssertFalse(settings.enterLCPPassphraseManually, "enterLCPPassphraseManually defaults false")
        XCTAssertFalse(settings.downloadOnlyOnWiFi, "downloadOnlyOnWiFi defaults false")
        XCTAssertFalse(settings.appRatingOptedOut, "appRatingOptedOut defaults false")
        XCTAssertEqual(settings.appRatingSessionCount, 0, "appRatingSessionCount defaults 0")
        XCTAssertEqual(settings.appRatingBooksCompleted, 0, "appRatingBooksCompleted defaults 0")
        XCTAssertEqual(settings.appRatingPromptDisplayCount, 0, "appRatingPromptDisplayCount defaults 0")
        XCTAssertEqual(settings.appRatingDismissalCount, 0, "appRatingDismissalCount defaults 0")
    }

    // MARK: - Persistence across reads / instances

    /// The store is a THIN wrapper over `UserDefaults`, not an in-memory cache:
    /// a value written through one `TPPSettings` instance must be visible to a
    /// SECOND instance built over the same backing suite. This pins "persistence
    /// across reads" and kills any mutant that starts caching writes in memory
    /// instead of committing them to `defaults`.
    func testWrites_arePersisted_andVisibleToASecondInstance() {
        let url = URL(string: "https://catalog.example.org/persisted")!
        settings.customMainFeedURL = url
        settings.appRatingSessionCount = 42
        settings.appRatingCrashFreeLastSession = false

        let reopened = TPPSettings(defaults: UserDefaults(suiteName: suiteName)!)
        XCTAssertEqual(reopened.customMainFeedURL, url,
                       "URL written by instance A must be readable by instance B")
        XCTAssertEqual(reopened.appRatingSessionCount, 42,
                       "Int written by instance A must be readable by instance B")
        XCTAssertFalse(reopened.appRatingCrashFreeLastSession,
                       "Stored false must survive re-instantiation (not revert to default true)")
    }
}

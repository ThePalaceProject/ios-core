//
//  AdobeConnectorGenerationTests.swift
//

import XCTest
@testable import Palace

/// Pins the per-library marker that records which DRM connector performed a
/// device activation (PP-5251).
///
/// Why a marker and not the licensor: `removeAll()` clears every other credential
/// key but never `_licensor`, whose only writer is `setLicensor`. `hasLicensor()`
/// is therefore true forever after a first sign-in and cannot stand for
/// "an activation exists".
final class AdobeConnectorGenerationTests: XCTestCase {

    /// Pins the accessor pair only. `write()` is write-through, so this read is
    /// answered from the in-memory cache and would pass even if the value could
    /// not be stored. `testRefreshFromKeychainPicksUpAnotherInstancesGeneration`
    /// is what proves an `NSNumber` survives the keychain.
    func testGenerationIsReadableAfterWriting() {
        let account: TPPUserAccount = TPPUserAccountTestFactory.makeIsolated()
        XCTAssertNil(account.adobeActivationConnectorGeneration,
                     "a fresh library has no recorded activation generation")

        account.setAdobeActivation(userID: "user", deviceID: "device",
                                   generation: AdobeConnectorGeneration.current)

        XCTAssertEqual(account.adobeActivationConnectorGeneration,
                       AdobeConnectorGeneration.current)
    }

    /// The defect class this exists to prevent. A marker that survives sign-out
    /// reports "activated under this connector" for a device that is no longer
    /// activated at all, so the migration would skip a patron who needs it.
    func testSignOutClearsTheGeneration() {
        let account: TPPUserAccount = TPPUserAccountTestFactory.makeIsolated()
        account.setAdobeActivation(userID: "user", deviceID: "device",
                                   generation: AdobeConnectorGeneration.current)
        XCTAssertNotNil(account.adobeActivationConnectorGeneration)

        account.removeAll()

        XCTAssertNil(account.adobeActivationConnectorGeneration,
                     "removeAll() must clear the generation; _licensor is the "
                     + "counter-example that made this test necessary")
    }

    /// Two libraries must not share a marker: a patron can be activated under one
    /// connector for one library and a different one for another.
    func testGenerationIsScopedPerLibrary() {
        let a: TPPUserAccount = TPPUserAccountTestFactory.makeIsolated()
        let b: TPPUserAccount = TPPUserAccountTestFactory.makeIsolated()

        a.setAdobeActivation(userID: "user", deviceID: "device",
                             generation: AdobeConnectorGeneration.current)

        XCTAssertEqual(a.adobeActivationConnectorGeneration, AdobeConnectorGeneration.current)
        XCTAssertNil(b.adobeActivationConnectorGeneration)
    }

    /// The constant is hand-assigned, so a test ties it to something checkable.
    /// `libhobbes-iOS.a` carries `hobbes.build`: 118378 and 187526 on the two
    /// Adobe-era drops, 187639 on Wipro 2.0. When a future drop moves that number
    /// this fails and forces a decision rather than silently mis-targeting the
    /// migration.
    func testBuildNumbersMapToTheExpectedGenerations() {
        XCTAssertEqual(AdobeConnectorGeneration.generation(forConnectorBuild: "118378"), 1,
                       "the connector that shipped from 2021 to 2025 is generation 1")
        XCTAssertEqual(AdobeConnectorGeneration.generation(forConnectorBuild: "187526"), 1,
                       "the later Adobe-era drop is the same generation: same service")
        XCTAssertEqual(AdobeConnectorGeneration.generation(forConnectorBuild: "187639"), 2,
                       "Wipro 2.0 is generation 2")
    }

    /// An unknown build must not silently resolve to a generation: that is how a
    /// new vendor drop would quietly inherit "already migrated".
    func testAnUnknownBuildHasNoGeneration() {
        XCTAssertNil(AdobeConnectorGeneration.generation(forConnectorBuild: "999999"))
        XCTAssertNil(AdobeConnectorGeneration.generation(forConnectorBuild: ""))
    }

    /// The marker is one of the keys `invalidateAllKeychainCaches()` drops. A key
    /// left off that list serves a stale cached value after the keychain changes
    /// under it, which for this marker means reporting "activated under this
    /// connector" for an activation that has since been replaced.
    func testRefreshFromKeychainPicksUpAnotherInstancesGeneration() {
        let libraryUUID = "test-uuid-\(UUID().uuidString)"
        let writer: TPPUserAccount = TPPUserAccountTestFactory.makeIsolated(libraryUUID: libraryUUID)
        let reader: TPPUserAccount = TPPUserAccountTestFactory.makeIsolated(libraryUUID: libraryUUID)

        // Prime the reader's cache with the absent value before the writer acts.
        XCTAssertNil(reader.adobeActivationConnectorGeneration)
        writer.setAdobeActivation(userID: "user", deviceID: "device",
                                  generation: AdobeConnectorGeneration.current)

        _ = reader.refreshCredentialsFromKeychain()

        XCTAssertEqual(reader.adobeActivationConnectorGeneration,
                       AdobeConnectorGeneration.current,
                       "refreshCredentialsFromKeychain must drop this key's cache "
                       + "along with the rest")
    }

    /// The two setters this replaced each posted `notifyAccountDidChange()`, so
    /// an activation notified twice. The atomic write must still notify, or
    /// observers stop learning that an activation landed.
    ///
    /// Asserts ONLY the notification. An earlier version also checked the three
    /// stored fields, so it failed both when the notification was dropped and
    /// when the generation write was — a test that fails for two unrelated
    /// reasons identifies neither.
    func testRecordingAnActivationNotifiesObservers() {
        let account: TPPUserAccount = TPPUserAccountTestFactory.makeIsolated()
        let expectation = expectation(
            forNotification: .TPPUserAccountDidChange, object: nil, handler: nil
        )

        account.setAdobeActivation(userID: "user", deviceID: "device",
                                   generation: AdobeConnectorGeneration.current)

        wait(for: [expectation], timeout: 2.0)
    }

    /// The storage half: all three fields of the activation record persist.
    ///
    /// `AdobeActivationGenerationGateTests` cannot cover this — those tests
    /// drive a double that implements `setAdobeActivation` itself, so they pin
    /// that the call site PASSES a generation, not that this type keeps one.
    /// Stripping the generation write left them green.
    func testRecordingAnActivationStoresAllThreeFields() {
        let account: TPPUserAccount = TPPUserAccountTestFactory.makeIsolated()

        account.setAdobeActivation(userID: "user", deviceID: "device",
                                   generation: AdobeConnectorGeneration.current)

        XCTAssertEqual(account.userID, "user")
        XCTAssertEqual(account.deviceID, "device")
        XCTAssertEqual(account.adobeActivationConnectorGeneration,
                       AdobeConnectorGeneration.current)
    }

    /// And they survive the keychain, not just the write-through cache. A second
    /// instance on the same library reads through `refreshCredentialsFromKeychain`,
    /// which is the only read that proves persistence.
    func testTheActivationRecordSurvivesTheKeychain() {
        let libraryUUID = "test-uuid-\(UUID().uuidString)"
        let writer: TPPUserAccount = TPPUserAccountTestFactory.makeIsolated(libraryUUID: libraryUUID)
        let reader: TPPUserAccount = TPPUserAccountTestFactory.makeIsolated(libraryUUID: libraryUUID)

        XCTAssertNil(reader.adobeActivationConnectorGeneration)
        writer.setAdobeActivation(userID: "user", deviceID: "device",
                                  generation: AdobeConnectorGeneration.current)

        _ = reader.refreshCredentialsFromKeychain()

        XCTAssertEqual(reader.userID, "user")
        XCTAssertEqual(reader.deviceID, "device")
        XCTAssertEqual(reader.adobeActivationConnectorGeneration,
                       AdobeConnectorGeneration.current)
    }

    // MARK: - The re-activation policy, every cell

    /// `needsReactivation` decides whether a patron's device gets re-activated,
    /// so the whole table is walked rather than the three cells the gate happens
    /// to reach. `current` is injected because the shipped constant is 1 today
    /// and the Wipro cases are the ones that matter most.
    func testNeedsReactivation_EveryCombination() {
        // recorded, current, expected
        let cases: [(Int?, Int, Bool, String)] = [
            (nil, 1, false, "an existing install on an unchanged connector keeps the fast path"),
            (nil, 2, true,  "an existing install must migrate once Wipro ships"),
            (1,   1, false, "activated under the current connector"),
            (1,   2, true,  "activated under the Adobe-era connector, now on Wipro"),
            (2,   2, false, "activated under Wipro, still on Wipro"),
            (2,   1, true,  "a downgrade: recorded ahead of current must be redone"),
            (0,   1, true,  "a generation older than any that shipped must be redone")
        ]
        for (recorded, current, expected, why) in cases {
            XCTAssertEqual(
                AdobeConnectorGeneration.needsReactivation(recorded: recorded, current: current),
                expected,
                "recorded=\(recorded.map(String.init) ?? "nil") current=\(current): \(why)"
            )
        }
    }

    /// The backfill constant is load-bearing: it is what keeps every existing
    /// patron on the fast path while the connector is unchanged.
    func testAbsentMarkerIsBackfilledToThePreMarkerGeneration() {
        XCTAssertEqual(AdobeConnectorGeneration.preMarker, 1,
                       "every connector that has shipped (118378, 187526) is generation 1")
        XCTAssertFalse(
            AdobeConnectorGeneration.needsReactivation(recorded: nil,
                                                       current: AdobeConnectorGeneration.preMarker),
            "an unmarked activation must not be redone while the connector is unchanged"
        )
    }

#if FEATURE_DRM_CONNECTOR
    /// The keystone. `current` is hand-assigned, so without this a connector
    /// swap that nobody paired with a constant bump would leave every migration
    /// decision reading the wrong generation, and nothing would say so.
    func testCurrentGenerationDescribesTheLinkedConnector() {
        let build = AdobeConnectorBuild.current

        XCTAssertFalse(build.isEmpty,
                       "the SDK registered no hobbes.build, so the generation "
                       + "constant has nothing to be validated against")
        XCTAssertEqual(AdobeConnectorGeneration.generation(forConnectorBuild: build),
                       AdobeConnectorGeneration.current,
                       "linked connector build \(build) does not map to "
                       + "AdobeConnectorGeneration.current "
                       + "(\(AdobeConnectorGeneration.current)); a connector swap "
                       + "has to move the constant and the table together")
    }
#endif
}

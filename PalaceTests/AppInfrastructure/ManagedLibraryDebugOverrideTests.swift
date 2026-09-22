//
//  ManagedLibraryDebugOverrideTests.swift
//  PalaceTests
//
//  PP-5070 — the Testing-screen stand-in for an MDM.
//
//  The load-bearing assertions here are not about the happy path. They are that
//  the override writes the key production reads (so the screen tests the real
//  thing), and that it refuses to delete a configuration a real MDM supplied
//  (so using the screen on a managed device cannot un-configure it).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

private final class RegistryStub: ManagedLibraryRegistryReading {
    var registryHasLoaded = true
    var accounts: [Account] = []
    func managedLibraryAccount(uuid: String) -> Account? { accounts.first { $0.uuid == uuid } }
    func managedLibraryAccounts() -> [Account] { accounts }
}

final class ManagedLibraryDebugOverrideTests: XCTestCase {

    private let lowerId = "urn:uuid:681710a7-d1c2-4649-a29d-4fbd08e8861e"
    private let lowerCatalog = "https://il.thepalaceproject.org/00351977/"

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ManagedLibraryDebugOverrideTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func account(id: String, catalog: String) -> Account {
        Account(
            publication: OPDS2Publication(
                links: [OPDS2Link(href: catalog, rel: "http://opds-spec.org/catalog")],
                metadata: OPDS2Publication.Metadata(id: id, title: "Fixture \(id)"),
                images: nil
            ),
            imageCache: MockImageCache()
        )
    }

    // MARK: - It writes the key production reads

    func testWrite_LandsUnderTheAppleManagedConfigurationKey_NotAPrivateDebugKey() {
        // This is the whole point of the design. A private debug key would make
        // the Testing screen exercise a branch production never takes, leaving
        // the actual MDM read path unverified on device.
        ManagedLibraryDebugOverride.write(raw: lowerId, defaults: defaults)

        let dict = defaults.dictionary(forKey: "com.apple.configuration.managed")
        XCTAssertEqual(dict?["defaultLibraryId"] as? String, lowerId)
    }

    func testWrite_IsReadBackByTheProductionParser() {
        ManagedLibraryDebugOverride.write(raw: lowerId, defaults: defaults)

        XCTAssertEqual(
            ManagedAppConfiguration.libraryPreconfiguration(defaults: defaults)?.libraryId,
            lowerId
        )
    }

    func testWrite_RoutesAURLToTheCatalogKeyAndAnIdentifierToTheIdKey() {
        ManagedLibraryDebugOverride.write(raw: lowerCatalog, defaults: defaults)
        var dict = defaults.dictionary(forKey: ManagedAppConfiguration.userDefaultsKey)
        XCTAssertEqual(dict?["defaultLibraryCatalogUrl"] as? String, lowerCatalog)
        XCTAssertNil(dict?["defaultLibraryId"])

        ManagedLibraryDebugOverride.clear(defaults: defaults)
        ManagedLibraryDebugOverride.write(raw: lowerId, defaults: defaults)
        dict = defaults.dictionary(forKey: ManagedAppConfiguration.userDefaultsKey)
        XCTAssertEqual(dict?["defaultLibraryId"] as? String, lowerId)
        XCTAssertNil(dict?["defaultLibraryCatalogUrl"])
    }

    func testWrite_AcceptsTheSpellingsTheSpecificationAccepts() {
        // The screen exists to try what an administrator will type.
        let outcome = ManagedLibraryDebugOverride.write(
            raw: "  681710A7-D1C2-4649-A29D-4FBD08E8861E ",
            defaults: defaults
        )
        XCTAssertEqual(outcome, .written(
            ManagedLibraryPreconfiguration(libraryId: lowerId, catalogURL: nil)
        ))
    }

    // MARK: - It rejects what an MDM payload would reject

    func testWrite_RejectsANonUUIDRatherThanStoringSomethingUnresolvable() {
        let outcome = ManagedLibraryDebugOverride.write(raw: "North Shore Lower", defaults: defaults)
        guard case .rejected(let reason) = outcome else {
            return XCTFail("expected rejection, got \(outcome)")
        }
        XCTAssertNil(defaults.dictionary(forKey: ManagedAppConfiguration.userDefaultsKey))
        // The reason must describe what the tester actually typed. Telling
        // someone who mistyped a UUID that it is "not an https URL" sends them
        // looking for a problem they do not have.
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("UUID"), "got: \(reason)")
    }

    func testWrite_RejectsCleartextHTTP() {
        let outcome = ManagedLibraryDebugOverride.write(
            raw: "http://il.thepalaceproject.org/00351977/",
            defaults: defaults
        )
        guard case .rejected(let reason) = outcome else {
            return XCTFail("expected rejection, got \(outcome)")
        }
        XCTAssertNil(defaults.dictionary(forKey: ManagedAppConfiguration.userDefaultsKey))
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("https"), "got: \(reason)")
    }

    func testWrite_RejectsEmptyInput() {
        let outcome = ManagedLibraryDebugOverride.write(raw: "   \n", defaults: defaults)
        guard case .rejected = outcome else { return XCTFail("expected rejection, got \(outcome)") }
    }

    // MARK: - It does not damage a really-managed device

    func testWrite_RefusesToOverwriteAnExternallySuppliedConfiguration() {
        // An MDM wrote this; there is no debug-authored marker.
        defaults.set(["defaultLibraryId": lowerId],
                     forKey: ManagedAppConfiguration.userDefaultsKey)

        let outcome = ManagedLibraryDebugOverride.write(
            raw: "urn:uuid:700116df-9251-4028-b49f-ceeb69f8ce07",
            defaults: defaults
        )

        XCTAssertEqual(outcome, .refusedExternal)
        XCTAssertEqual(
            (defaults.dictionary(forKey: ManagedAppConfiguration.userDefaultsKey)?["defaultLibraryId"]) as? String,
            lowerId,
            "the MDM's value must survive untouched"
        )
    }

    func testClear_RefusesToDeleteAnExternallySuppliedConfiguration() {
        // Deleting this would silently un-configure a school's device.
        defaults.set(["defaultLibraryId": lowerId],
                     forKey: ManagedAppConfiguration.userDefaultsKey)

        XCTAssertFalse(ManagedLibraryDebugOverride.clear(defaults: defaults))
        XCTAssertNotNil(defaults.dictionary(forKey: ManagedAppConfiguration.userDefaultsKey))
    }

    func testClear_RemovesAConfigurationThisTypeWrote() {
        ManagedLibraryDebugOverride.write(raw: lowerId, defaults: defaults)

        XCTAssertTrue(ManagedLibraryDebugOverride.clear(defaults: defaults))
        XCTAssertNil(defaults.dictionary(forKey: ManagedAppConfiguration.userDefaultsKey))
        XCTAssertFalse(defaults.bool(forKey: ManagedLibraryDebugOverride.debugAuthoredMarkerKey))
    }

    func testProvenance_DistinguishesAbsentFromDebugAuthoredFromExternal() {
        XCTAssertEqual(ManagedLibraryDebugOverride.provenance(defaults: defaults), .absent)

        ManagedLibraryDebugOverride.write(raw: lowerId, defaults: defaults)
        XCTAssertEqual(ManagedLibraryDebugOverride.provenance(defaults: defaults), .debugAuthored)

        ManagedLibraryDebugOverride.clear(defaults: defaults)
        defaults.set(["defaultLibraryId": lowerId],
                     forKey: ManagedAppConfiguration.userDefaultsKey)
        XCTAssertEqual(ManagedLibraryDebugOverride.provenance(defaults: defaults), .external)
    }

    // MARK: - Forget makes the screen usable more than once

    func testForget_LetsTheSameValueApplyAgain() {
        let registry = RegistryStub()
        registry.accounts = [account(id: lowerId, catalog: lowerCatalog)]
        var selected: [String] = []
        let sut = ManagedLibraryPreconfigurator(
            defaults: defaults,
            registry: registry,
            dependencies: ManagedLibraryApplyDependencies(
                addedLibraryIds: { [] },
                setAddedLibraryIds: { _ in },
                setMainFeedURL: { _ in },
                selectLibrary: { selected.append($0.uuid) },
                loadAuthenticationDocument: { _ in },
                announceLibraryChanged: { }
            )
        )

        ManagedLibraryDebugOverride.write(raw: lowerId, defaults: defaults)
        XCTAssertEqual(sut.applyIfNeeded(), .apply(uuid: lowerId))
        XCTAssertEqual(sut.applyIfNeeded(), .alreadyApplied, "second attempt is a no-op by design")

        ManagedLibraryDebugOverride.forgetAppliedFingerprint(defaults: defaults)

        XCTAssertEqual(sut.applyIfNeeded(), .apply(uuid: lowerId))
        XCTAssertEqual(selected, [lowerId, lowerId], "the library was selected both times")
    }

    // MARK: - inspect() is a diagnostic, not an action

    func testInspect_ReportsTheDecisionWithoutApplyingIt() {
        // A read-out that selected a library as a side effect of being read
        // would make the screen lie about the state it is describing.
        let registry = RegistryStub()
        registry.accounts = [account(id: lowerId, catalog: lowerCatalog)]
        var selectCount = 0
        let sut = ManagedLibraryPreconfigurator(
            defaults: defaults,
            registry: registry,
            dependencies: ManagedLibraryApplyDependencies(
                addedLibraryIds: { [] },
                setAddedLibraryIds: { _ in },
                setMainFeedURL: { _ in },
                selectLibrary: { _ in selectCount += 1 },
                loadAuthenticationDocument: { _ in },
                announceLibraryChanged: { }
            )
        )
        ManagedLibraryDebugOverride.write(raw: lowerId, defaults: defaults)

        XCTAssertEqual(sut.inspect(), .apply(uuid: lowerId))
        XCTAssertEqual(sut.inspect(), .apply(uuid: lowerId), "still pending — inspect changed nothing")
        XCTAssertEqual(selectCount, 0)
        XCTAssertNil(sut.appliedFingerprint)
    }

    func testInspect_OnAnUnmanagedInstall_ReportsNoConfiguration() {
        let sut = ManagedLibraryPreconfigurator(
            defaults: defaults,
            registry: RegistryStub(),
            dependencies: ManagedLibraryApplyDependencies(
                addedLibraryIds: { [] },
                setAddedLibraryIds: { _ in },
                setMainFeedURL: { _ in },
                selectLibrary: { _ in },
                loadAuthenticationDocument: { _ in },
                announceLibraryChanged: { }
            )
        )
        XCTAssertEqual(sut.inspect(), .noConfiguration)
        XCTAssertNil(sut.currentConfiguration)
    }

    // MARK: - The read-out says what the app will do

    func testDescribe_NamesTheLibraryItWillSelect() {
        XCTAssertTrue(
            ManagedLibraryDebugOverride.describe(.apply(uuid: lowerId)).contains(lowerId)
        )
    }

    func testDescribe_PointsAtTheWayOutOfAlreadyApplied() {
        // A tester who sees "already applied" needs to know Forget exists, or
        // they will reinstall the app instead.
        XCTAssertTrue(
            ManagedLibraryDebugOverride.describe(.alreadyApplied)
                .localizedCaseInsensitiveContains("forget")
        )
    }

    func testDescribe_DistinguishesNotFoundFromStillWaiting() {
        // These two look identical on screen if described loosely, and they call
        // for opposite responses: fix the identifier, versus wait.
        XCTAssertNotEqual(
            ManagedLibraryDebugOverride.describe(.unresolved),
            ManagedLibraryDebugOverride.describe(.registryNotLoaded)
        )
    }
}

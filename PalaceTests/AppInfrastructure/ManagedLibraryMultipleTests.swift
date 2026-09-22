//
//  ManagedLibraryMultipleTests.swift
//  PalaceTests
//
//  PP-5070 — configuring more than one library, and the warnings that stop a
//  half-usable payload from failing in silence.
//
//  The two rules worth pinning are asymmetric on purpose:
//    · an ADDITIONAL library the registry has never heard of is dropped, and
//      the device is still pointed at the right catalog;
//    · a SELECTED library the registry has never heard of is `.unresolved`,
//      and nothing is configured at all.
//  Getting that backwards either strands a device on no library, or lands a
//  Middle School device in a catalog nobody chose.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

private final class MultiRegistryStub: ManagedLibraryRegistryReading {
    var registryHasLoaded = true
    var accounts: [Account] = []
    func managedLibraryAccount(uuid: String) -> Account? { accounts.first { $0.uuid == uuid } }
    func managedLibraryAccounts() -> [Account] { accounts }
}

private final class MultiRecorder {
    var addedIds: [String] = []
    var selected: [String] = []
    var listWrites = 0

    var dependencies: ManagedLibraryApplyDependencies {
        ManagedLibraryApplyDependencies(
            addedLibraryIds: { [unowned self] in addedIds },
            setAddedLibraryIds: { [unowned self] in addedIds = $0; listWrites += 1 },
            setMainFeedURL: { _ in },
            selectLibrary: { [unowned self] in selected.append($0.uuid) },
            loadAuthenticationDocument: { _ in },
            announceLibraryChanged: { }
        )
    }
}

final class ManagedLibraryMultipleTests: XCTestCase {

    private let lower  = "urn:uuid:681710a7-d1c2-4649-a29d-4fbd08e8861e"
    private let middle = "urn:uuid:700116df-9251-4028-b49f-ceeb69f8ce07"
    private let upper  = "urn:uuid:511def8d-0319-41bb-89e2-4902c017c810"
    private let absent = "urn:uuid:00000000-0000-0000-0000-000000000000"

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ManagedLibraryMultipleTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func account(_ id: String) -> Account {
        Account(
            publication: OPDS2Publication(
                links: [OPDS2Link(href: "https://il.thepalaceproject.org/\(id.suffix(6))/",
                                  rel: "http://opds-spec.org/catalog")],
                metadata: OPDS2Publication.Metadata(id: id, title: "Fixture \(id.suffix(6))"),
                images: nil
            ),
            imageCache: MockImageCache()
        )
    }

    private func makeSUT(
        registry: MultiRegistryStub, recorder: MultiRecorder
    ) -> ManagedLibraryPreconfigurator {
        ManagedLibraryPreconfigurator(
            defaults: defaults, registry: registry, dependencies: recorder.dependencies
        )
    }

    // MARK: - Parsing a list

    func testParse_AddsTheListWithoutChangingWhichLibraryIsSelected() {
        let parsed = ManagedAppConfiguration.libraryPreconfiguration(managedDictionary: [
            "defaultLibraryId": lower,
            "additionalLibraryIds": [middle, upper]
        ])
        XCTAssertEqual(parsed?.libraryId, lower)
        XCTAssertEqual(parsed?.additionalLibraryIds, [middle, upper])
    }

    func testParse_AcceptsASingleStringWhereAnArrayWasExpected() {
        // An administrator adding exactly one extra library will write one.
        let parsed = ManagedAppConfiguration.libraryPreconfiguration(managedDictionary: [
            "defaultLibraryId": lower,
            "additionalLibraryIds": middle
        ])
        XCTAssertEqual(parsed?.additionalLibraryIds, [middle])
    }

    func testParse_NormalizesEveryEntry_NotJustTheSelectedOne() {
        let parsed = ManagedAppConfiguration.libraryPreconfiguration(managedDictionary: [
            "defaultLibraryId": lower,
            "additionalLibraryIds": [" 700116DF-9251-4028-B49F-CEEB69F8CE07 ",
                                     "URN:UUID:511DEF8D-0319-41BB-89E2-4902C017C810"]
        ])
        XCTAssertEqual(parsed?.additionalLibraryIds, [middle, upper])
    }

    func testParse_DropsADuplicateOfTheSelectedLibrary() {
        // Listing the selected library again is common and harmless; it must
        // not produce a doubled entry in the user's library list.
        let parsed = ManagedAppConfiguration.libraryPreconfiguration(managedDictionary: [
            "defaultLibraryId": lower,
            "additionalLibraryIds": [lower, middle]
        ])
        XCTAssertEqual(parsed?.additionalLibraryIds, [middle])
    }

    func testParse_DeduplicatesRepeatsWithinTheList() {
        let parsed = ManagedAppConfiguration.libraryPreconfiguration(managedDictionary: [
            "defaultLibraryId": lower,
            "additionalLibraryIds": [middle, middle, upper]
        ])
        XCTAssertEqual(parsed?.additionalLibraryIds, [middle, upper])
    }

    func testFingerprint_ChangesWhenOnlyTheAdditionalListChanges() {
        // Otherwise adding a library to an existing configuration would sit
        // inert behind `.alreadyApplied` forever.
        let one = ManagedLibraryPreconfiguration(libraryId: lower, catalogURL: nil,
                                                 additionalLibraryIds: [middle])
        let two = ManagedLibraryPreconfiguration(libraryId: lower, catalogURL: nil,
                                                 additionalLibraryIds: [middle, upper])
        XCTAssertNotEqual(one.fingerprint, two.fingerprint)
    }

    // MARK: - Warnings: the silent-ignore fix

    func testParse_AnArrayUnderTheSelectorKey_IsReportedNotIgnored() {
        // Before this, an array here parsed as an ABSENT key: the payload
        // configured nothing and said nothing about why.
        let result = ManagedAppConfiguration.parse(managedDictionary: [
            "defaultLibraryId": [lower, middle]
        ])
        XCTAssertNil(result.configuration)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(
            result.warnings[0].contains("additionalLibraryIds"),
            "the warning should point at the key that does take a list — got: \(result.warnings[0])"
        )
    }

    func testParse_AnUnusableSelector_NamesTheValueItRejected() {
        let result = ManagedAppConfiguration.parse(managedDictionary: [
            "defaultLibraryId": "North Shore Lower"
        ])
        XCTAssertNil(result.configuration)
        XCTAssertTrue(result.warnings.contains { $0.contains("North Shore Lower") })
    }

    func testParse_ADroppedListEntry_IsReportedIndividually() {
        // A list silently shortened is how a device ends up missing one
        // division's library with nothing to show for it.
        let result = ManagedAppConfiguration.parse(managedDictionary: [
            "defaultLibraryId": lower,
            "additionalLibraryIds": [middle, "not-a-uuid"]
        ])
        XCTAssertEqual(result.configuration?.additionalLibraryIds, [middle])
        XCTAssertTrue(result.warnings.contains { $0.contains("not-a-uuid") })
    }

    func testParse_ListWithNoSelector_IsIncompleteAndSaysSo() {
        let result = ManagedAppConfiguration.parse(managedDictionary: [
            "additionalLibraryIds": [middle, upper]
        ])
        XCTAssertNil(result.configuration, "a configuration must name a library to select")
        XCTAssertTrue(result.warnings.contains { $0.contains("defaultLibraryId") })
    }

    func testParse_AValidSingleLibrary_WarnsAboutNothing() {
        // The clean path must stay silent, or the warnings become noise nobody
        // reads.
        let result = ManagedAppConfiguration.parse(managedDictionary: ["defaultLibraryId": lower])
        XCTAssertEqual(result.warnings, [])
        XCTAssertEqual(result.configuration?.libraryId, lower)
    }

    func testParse_AnUnmanagedInstall_WarnsAboutNothing() {
        XCTAssertEqual(ManagedAppConfiguration.parse(defaults: defaults), .none)
    }

    // MARK: - Applying a list

    func testApply_AddsEveryResolvedLibraryButSelectsOnlyTheNamedOne() {
        let registry = MultiRegistryStub()
        registry.accounts = [account(lower), account(middle), account(upper)]
        let recorder = MultiRecorder()
        defaults.set(["defaultLibraryId": middle, "additionalLibraryIds": [lower, upper]],
                     forKey: ManagedAppConfiguration.userDefaultsKey)

        XCTAssertEqual(makeSUT(registry: registry, recorder: recorder).applyIfNeeded(),
                       .apply(uuid: middle))
        XCTAssertEqual(recorder.selected, [middle], "exactly one library becomes current")
        XCTAssertEqual(Set(recorder.addedIds), Set([middle, lower, upper]))
    }

    func testApply_WritesTheLibraryListExactlyOnce() {
        // The contract-snapshot order must not grow a write per extra library.
        let registry = MultiRegistryStub()
        registry.accounts = [account(lower), account(middle), account(upper)]
        let recorder = MultiRecorder()
        defaults.set(["defaultLibraryId": lower, "additionalLibraryIds": [middle, upper]],
                     forKey: ManagedAppConfiguration.userDefaultsKey)

        _ = makeSUT(registry: registry, recorder: recorder).applyIfNeeded()
        XCTAssertEqual(recorder.listWrites, 1)
    }

    func testApply_PreservesLibrariesTheUserAlreadyHad() {
        let registry = MultiRegistryStub()
        registry.accounts = [account(lower), account(middle)]
        let recorder = MultiRecorder()
        recorder.addedIds = ["urn:uuid:56906f26-2c9a-4ae9-bd02-552557720b99"]
        defaults.set(["defaultLibraryId": lower, "additionalLibraryIds": [middle]],
                     forKey: ManagedAppConfiguration.userDefaultsKey)

        _ = makeSUT(registry: registry, recorder: recorder).applyIfNeeded()
        XCTAssertEqual(recorder.addedIds.first, "urn:uuid:56906f26-2c9a-4ae9-bd02-552557720b99")
        XCTAssertEqual(recorder.addedIds.count, 3)
    }

    func testApply_WhenNothingChanges_SkipsTheListWriteEntirely() {
        let registry = MultiRegistryStub()
        registry.accounts = [account(lower), account(middle)]
        let recorder = MultiRecorder()
        recorder.addedIds = [lower, middle]
        defaults.set(["defaultLibraryId": lower, "additionalLibraryIds": [middle]],
                     forKey: ManagedAppConfiguration.userDefaultsKey)

        _ = makeSUT(registry: registry, recorder: recorder).applyIfNeeded()
        XCTAssertEqual(recorder.listWrites, 0)
        XCTAssertEqual(recorder.selected, [lower], "but the library is still selected")
    }

    // MARK: - The asymmetry

    func testApply_AnUnresolvableADDITION_IsDroppedAndTheSelectionStillHappens() {
        let registry = MultiRegistryStub()
        registry.accounts = [account(lower), account(middle)]
        let recorder = MultiRecorder()
        defaults.set(["defaultLibraryId": lower, "additionalLibraryIds": [middle, absent]],
                     forKey: ManagedAppConfiguration.userDefaultsKey)

        XCTAssertEqual(makeSUT(registry: registry, recorder: recorder).applyIfNeeded(),
                       .apply(uuid: lower))
        XCTAssertEqual(recorder.selected, [lower])
        XCTAssertEqual(Set(recorder.addedIds), Set([lower, middle]))
        XCTAssertFalse(recorder.addedIds.contains(absent))
    }

    func testApply_AnUnresolvableSELECTION_ConfiguresNothingAtAll() {
        // Not even the additions, which DO resolve: half-configuring a device
        // into a catalog nobody chose is worse than leaving it to the picker.
        let registry = MultiRegistryStub()
        registry.accounts = [account(middle), account(upper)]
        let recorder = MultiRecorder()
        defaults.set(["defaultLibraryId": absent, "additionalLibraryIds": [middle, upper]],
                     forKey: ManagedAppConfiguration.userDefaultsKey)

        XCTAssertEqual(makeSUT(registry: registry, recorder: recorder).applyIfNeeded(), .unresolved)
        XCTAssertEqual(recorder.selected, [])
        XCTAssertEqual(recorder.addedIds, [])
        XCTAssertNil(defaults.string(forKey: ManagedLibraryPreconfigurator.appliedFingerprintKey))
    }

    func testResolveAdditional_ReportsWhatItCouldNotFind() {
        let registry = MultiRegistryStub()
        registry.accounts = [account(middle)]
        let result = ManagedLibraryPreconfigurator.resolveAdditional(
            configuration: ManagedLibraryPreconfiguration(
                libraryId: lower, catalogURL: nil, additionalLibraryIds: [middle, absent]
            ),
            registry: registry
        )
        XCTAssertEqual(result.resolved.map(\.uuid), [middle])
        XCTAssertEqual(result.missing, [absent])
    }

    // MARK: - The Testing screen's one text field

    func testSplitEntries_TakesCommasNewlinesAndSpaces() {
        XCTAssertEqual(
            ManagedLibraryDebugOverride.splitEntries("\(lower), \(middle)\n\(upper)"),
            [lower, middle, upper]
        )
    }

    func testSplitEntries_IgnoresStraySeparatorsAndBlankLines() {
        XCTAssertEqual(
            ManagedLibraryDebugOverride.splitEntries("  ,,\n \(lower) ,\n\n \(middle),  "),
            [lower, middle]
        )
    }

    func testDebugWrite_FirstEntryIsSelectedAndTheRestAreAdded() {
        let outcome = ManagedLibraryDebugOverride.write(
            raw: "\(upper), \(lower), \(middle)", defaults: defaults
        )
        guard case .written(let parsed, _) = outcome else {
            return XCTFail("expected a write, got \(outcome)")
        }
        XCTAssertEqual(parsed.libraryId, upper)
        XCTAssertEqual(parsed.additionalLibraryIds, [lower, middle])
    }

    func testDebugWrite_ProducesThePayloadShapeAnMDMWouldSend() {
        // The screen is only worth having if what it writes is what an
        // administrator's plist writes.
        _ = ManagedLibraryDebugOverride.write(raw: "\(lower) \(middle)", defaults: defaults)
        let dict = defaults.dictionary(forKey: ManagedAppConfiguration.userDefaultsKey)
        XCTAssertEqual(dict?["defaultLibraryId"] as? String, lower)
        XCTAssertEqual(dict?["additionalLibraryIds"] as? [String], [middle])
    }

    func testDebugWrite_OmitsTheAdditionalKeyWhenOnlyOneLibraryIsGiven() {
        _ = ManagedLibraryDebugOverride.write(raw: lower, defaults: defaults)
        let dict = defaults.dictionary(forKey: ManagedAppConfiguration.userDefaultsKey)
        XCTAssertNil(dict?["additionalLibraryIds"])
    }

    func testDebugWrite_SurfacesADroppedEntryRatherThanShorteningInSilence() {
        let outcome = ManagedLibraryDebugOverride.write(
            raw: "\(lower), nonsense", defaults: defaults
        )
        guard case .written(let parsed, let warnings) = outcome else {
            return XCTFail("expected a write, got \(outcome)")
        }
        XCTAssertEqual(parsed.additionalLibraryIds, [])
        XCTAssertTrue(warnings.contains { $0.contains("nonsense") })
    }
}

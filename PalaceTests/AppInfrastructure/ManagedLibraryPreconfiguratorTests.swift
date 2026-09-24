//
//  ManagedLibraryPreconfiguratorTests.swift
//  PalaceTests
//
//  PP-5070 — the decision is a finite table over four inputs, so it is asserted
//  as a table rather than as scenarios. The four questions the ticket asks about
//  re-application (app update / student removal / MDM change / re-image) are
//  cells in it, not separate features.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

// MARK: - Test doubles

/// Registry double: answers only what the preconfigurator asks, and records
/// whether it was asked at all so "did not even look" is assertable.
private final class RegistryDouble: ManagedLibraryRegistryReading {
    var registryHasLoaded: Bool
    var accountsByUUID: [String: Account]
    var allAccounts: [Account]
    private(set) var uuidLookups: [String] = []
    private(set) var listingCount = 0

    init(loaded: Bool, accounts: [Account] = []) {
        self.registryHasLoaded = loaded
        self.allAccounts = accounts
        self.accountsByUUID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.uuid, $0) })
    }

    func managedLibraryAccount(uuid: String) -> Account? {
        uuidLookups.append(uuid)
        return accountsByUUID[uuid]
    }

    func managedLibraryAccounts() -> [Account] {
        listingCount += 1
        return allAccounts
    }
}

/// Records the apply side effects in order, with their arguments.
private final class ApplyRecorder {
    enum Event: Equatable, CustomStringConvertible {
        case readAddedIds
        case setAddedIds([String])
        case setMainFeed(String)
        case selectLibrary(String)
        case loadAuthDoc(String)
        case announce

        var description: String {
            switch self {
            case .readAddedIds: return "readAddedIds"
            case .setAddedIds(let ids): return "setAddedIds(\(ids))"
            case .setMainFeed(let url): return "setMainFeed(\(url))"
            case .selectLibrary(let uuid): return "selectLibrary(\(uuid))"
            case .loadAuthDoc(let uuid): return "loadAuthDoc(\(uuid))"
            case .announce: return "announce"
            }
        }
    }

    var events: [Event] = []
    var existingIds: [String] = []

    var dependencies: ManagedLibraryApplyDependencies {
        ManagedLibraryApplyDependencies(
            addedLibraryIds: { [unowned self] in
                events.append(.readAddedIds)
                return existingIds
            },
            setAddedLibraryIds: { [unowned self] in
                events.append(.setAddedIds($0))
                existingIds = $0
            },
            setMainFeedURL: { [unowned self] in events.append(.setMainFeed($0.absoluteString)) },
            selectLibrary: { [unowned self] in events.append(.selectLibrary($0.uuid)) },
            loadAuthenticationDocument: { [unowned self] in events.append(.loadAuthDoc($0.uuid)) },
            announceLibraryChanged: { [unowned self] in events.append(.announce) }
        )
    }
}

final class ManagedLibraryPreconfiguratorTests: XCTestCase {

    // The three real North Shore Country Day divisions, so the fixtures carry
    // the actual near-identical shape that motivated the ticket.
    private let lowerId = "urn:uuid:681710a7-d1c2-4649-a29d-4fbd08e8861e"
    private let middleId = "urn:uuid:700116df-9251-4028-b49f-ceeb69f8ce07"
    private let lowerCatalog = "https://il.thepalaceproject.org/00351977/"
    private let middleCatalog = "https://il.thepalaceproject.org/00351977b/"

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ManagedLibraryPreconfiguratorTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func account(id: String, title: String, catalog: String) -> Account {
        Account(
            publication: OPDS2Publication(
                links: [OPDS2Link(href: catalog, rel: "http://opds-spec.org/catalog")],
                metadata: OPDS2Publication.Metadata(id: id, title: title),
                images: nil
            ),
            imageCache: MockImageCache()
        )
    }

    private func configuration(id: String? = nil, catalog: String? = nil) -> ManagedLibraryPreconfiguration {
        ManagedLibraryPreconfiguration(
            libraryId: id,
            catalogURL: catalog.flatMap { URL(string: $0) }
        )
    }

    // MARK: - The decision table
    //
    // configuration │ fingerprint seen │ registry loaded │ resolves │ decision
    // ──────────────┼──────────────────┼─────────────────┼──────────┼──────────────────
    //  absent       │        —         │        —        │    —     │ noConfiguration
    //  present      │      same        │        —        │    —     │ alreadyApplied
    //  present      │      none        │      false      │    —     │ registryNotLoaded
    //  present      │   different      │      false      │    —     │ registryNotLoaded
    //  present      │      none        │      true       │   nil    │ unresolved
    //  present      │   different      │      true       │   nil    │ unresolved
    //  present      │      none        │      true       │  uuid    │ apply
    //  present      │   different      │      true       │  uuid    │ apply

    func testDecide_NoConfiguration_RegardlessOfEveryOtherInput() {
        for seen in [nil, "id=x|url=", "id=y|url="] {
            for loaded in [true, false] {
                XCTAssertEqual(
                    ManagedLibraryPreconfigurator.decide(
                        configuration: nil,
                        lastAppliedFingerprint: seen,
                        registryHasLoaded: loaded,
                        resolvedUUID: { "urn:uuid:anything" }
                    ),
                    .noConfiguration,
                    "seen=\(seen ?? "nil") loaded=\(loaded)"
                )
            }
        }
    }

    func testDecide_SameFingerprint_IsAlreadyApplied_EvenWhenItWouldResolve() {
        let config = configuration(id: lowerId)
        XCTAssertEqual(
            ManagedLibraryPreconfigurator.decide(
                configuration: config,
                lastAppliedFingerprint: config.fingerprint,
                registryHasLoaded: true,
                resolvedUUID: { self.lowerId }
            ),
            .alreadyApplied
        )
    }

    func testDecide_SameFingerprint_ShortCircuitsBeforeTheRegistryIsEvenConsulted() {
        // Ordering matters: this is the cell that stops the app re-asking on
        // every one of the up-to-eight catalog-load notifications per launch.
        let config = configuration(id: lowerId)
        var resolverCalls = 0
        _ = ManagedLibraryPreconfigurator.decide(
            configuration: config,
            lastAppliedFingerprint: config.fingerprint,
            registryHasLoaded: true,
            resolvedUUID: { resolverCalls += 1; return self.lowerId }
        )
        XCTAssertEqual(resolverCalls, 0)
    }

    func testDecide_RegistryNotLoaded_IsDeferredNotUnresolved() {
        // Reporting `.unresolved` here would be a false negative: the library
        // may be perfectly resolvable one notification later.
        for seen in [nil, "id=other|url="] {
            XCTAssertEqual(
                ManagedLibraryPreconfigurator.decide(
                    configuration: configuration(id: lowerId),
                    lastAppliedFingerprint: seen,
                    registryHasLoaded: false,
                    resolvedUUID: { self.lowerId }
                ),
                .registryNotLoaded,
                "seen=\(seen ?? "nil")"
            )
        }
    }

    func testDecide_RegistryNotLoaded_DoesNotConsultTheRegistry() {
        var resolverCalls = 0
        _ = ManagedLibraryPreconfigurator.decide(
            configuration: configuration(id: lowerId),
            lastAppliedFingerprint: nil,
            registryHasLoaded: false,
            resolvedUUID: { resolverCalls += 1; return nil }
        )
        XCTAssertEqual(resolverCalls, 0)
    }

    func testDecide_LoadedButUnresolvable_IsUnresolved() {
        for seen in [nil, "id=other|url="] {
            XCTAssertEqual(
                ManagedLibraryPreconfigurator.decide(
                    configuration: configuration(id: lowerId),
                    lastAppliedFingerprint: seen,
                    registryHasLoaded: true,
                    resolvedUUID: { nil }
                ),
                .unresolved,
                "seen=\(seen ?? "nil")"
            )
        }
    }

    func testDecide_LoadedAndResolvable_Applies_WhetherNeverSeenOrChanged() {
        for seen in [nil, "id=other|url="] {
            XCTAssertEqual(
                ManagedLibraryPreconfigurator.decide(
                    configuration: configuration(id: lowerId),
                    lastAppliedFingerprint: seen,
                    registryHasLoaded: true,
                    resolvedUUID: { self.lowerId }
                ),
                .apply(uuid: lowerId),
                "seen=\(seen ?? "nil")"
            )
        }
    }

    // MARK: - Resolution

    func testResolve_ByIdentifier_PicksTheNamedDivisionNotASibling() {
        let registry = RegistryDouble(loaded: true, accounts: [
            account(id: lowerId, title: "North Shore Country Day Lower School Library", catalog: lowerCatalog),
            account(id: middleId, title: "North Shore Country Day Middle School Library", catalog: middleCatalog)
        ])
        let resolved = ManagedLibraryPreconfigurator.resolve(
            configuration: configuration(id: middleId),
            registry: registry
        )
        XCTAssertEqual(resolved?.uuid, middleId)
    }

    func testResolve_ByCatalogURL_PicksTheNamedDivisionNotASibling() {
        let registry = RegistryDouble(loaded: true, accounts: [
            account(id: lowerId, title: "Lower", catalog: lowerCatalog),
            account(id: middleId, title: "Middle", catalog: middleCatalog)
        ])
        let resolved = ManagedLibraryPreconfigurator.resolve(
            configuration: configuration(catalog: middleCatalog),
            registry: registry
        )
        XCTAssertEqual(resolved?.uuid, middleId)
    }

    func testResolve_WhenIdentifierIsWrong_DoesNotSilentlyFallBackToTheSuppliedURL() {
        // An administrator who supplied both and mistyped the identifier must
        // get a failure, not a device quietly pointed at the URL's library —
        // otherwise a Middle School device lands in the Lower School catalog
        // and nothing reports it.
        let registry = RegistryDouble(loaded: true, accounts: [
            account(id: lowerId, title: "Lower", catalog: lowerCatalog)
        ])
        let resolved = ManagedLibraryPreconfigurator.resolve(
            configuration: ManagedLibraryPreconfiguration(
                libraryId: "urn:uuid:00000000-0000-0000-0000-000000000000",
                catalogURL: URL(string: lowerCatalog)
            ),
            registry: registry
        )
        XCTAssertNil(resolved)
        XCTAssertEqual(registry.listingCount, 0, "must not walk the registry after an identifier miss")
    }

    func testResolve_WithNeitherUsableField_IsNil() {
        let registry = RegistryDouble(loaded: true, accounts: [
            account(id: lowerId, title: "Lower", catalog: lowerCatalog)
        ])
        XCTAssertNil(
            ManagedLibraryPreconfigurator.resolve(configuration: configuration(), registry: registry)
        )
    }

    // MARK: - Apply: the side effects, in order

    private func makeSUT(
        managed: [String: Any]?,
        registry: RegistryDouble,
        recorder: ApplyRecorder
    ) -> ManagedLibraryPreconfigurator {
        if let managed {
            defaults.set(managed, forKey: ManagedAppConfiguration.userDefaultsKey)
        }
        return ManagedLibraryPreconfigurator(
            defaults: defaults,
            registry: registry,
            dependencies: recorder.dependencies
        )
    }

    func testApply_PerformsThePickersSideEffectsInThePickersOrder() {
        let registry = RegistryDouble(loaded: true, accounts: [
            account(id: lowerId, title: "Lower", catalog: lowerCatalog)
        ])
        let recorder = ApplyRecorder()
        let sut = makeSUT(managed: ["defaultLibraryId": lowerId], registry: registry, recorder: recorder)

        XCTAssertEqual(sut.applyIfNeeded(), .apply(uuid: lowerId))
        XCTAssertEqual(recorder.events, [
            .readAddedIds,
            .setAddedIds([lowerId]),
            .setMainFeed(lowerCatalog),
            .selectLibrary(lowerId),
            .loadAuthDoc(lowerId),
            .announce
        ])
    }

    func testApply_WhenLibraryAlreadyInTheAddedList_DoesNotDuplicateIt() {
        let registry = RegistryDouble(loaded: true, accounts: [
            account(id: lowerId, title: "Lower", catalog: lowerCatalog)
        ])
        let recorder = ApplyRecorder()
        recorder.existingIds = ["urn:uuid:56906f26-2c9a-4ae9-bd02-552557720b99", lowerId]
        let sut = makeSUT(managed: ["defaultLibraryId": lowerId], registry: registry, recorder: recorder)

        _ = sut.applyIfNeeded()

        XCTAssertFalse(
            recorder.events.contains { if case .setAddedIds = $0 { return true } else { return false } },
            "list write is skipped when the library is already present"
        )
        XCTAssertTrue(recorder.events.contains(.selectLibrary(lowerId)), "but the library is still selected")
    }

    func testApply_WritesTheFingerprintOnlyAfterTheLibraryIsActuallyCurrent() {
        let registry = RegistryDouble(loaded: true, accounts: [
            account(id: lowerId, title: "Lower", catalog: lowerCatalog)
        ])
        let recorder = ApplyRecorder()
        let sut = makeSUT(managed: ["defaultLibraryId": lowerId], registry: registry, recorder: recorder)

        XCTAssertNil(defaults.string(forKey: ManagedLibraryPreconfigurator.appliedFingerprintKey))
        _ = sut.applyIfNeeded()
        XCTAssertEqual(
            defaults.string(forKey: ManagedLibraryPreconfigurator.appliedFingerprintKey),
            configuration(id: lowerId).fingerprint
        )
    }

    func testApply_WhenUnresolved_WritesNoFingerprintSoALaterLaunchRetries() {
        // The library may be missing only because this launch's registry was
        // stale. Marking it done would make the failure permanent.
        let registry = RegistryDouble(loaded: true, accounts: [])
        let recorder = ApplyRecorder()
        let sut = makeSUT(managed: ["defaultLibraryId": lowerId], registry: registry, recorder: recorder)

        XCTAssertEqual(sut.applyIfNeeded(), .unresolved)
        XCTAssertNil(defaults.string(forKey: ManagedLibraryPreconfigurator.appliedFingerprintKey))
        XCTAssertEqual(recorder.events, [])
    }

    func testApply_WhenRegistryNotLoaded_TouchesNothingAndRetriesLater() {
        let registry = RegistryDouble(loaded: false, accounts: [
            account(id: lowerId, title: "Lower", catalog: lowerCatalog)
        ])
        let recorder = ApplyRecorder()
        let sut = makeSUT(managed: ["defaultLibraryId": lowerId], registry: registry, recorder: recorder)

        XCTAssertEqual(sut.applyIfNeeded(), .registryNotLoaded)
        XCTAssertEqual(recorder.events, [])
        XCTAssertNil(defaults.string(forKey: ManagedLibraryPreconfigurator.appliedFingerprintKey))

        // …and once the registry lands, the same instance applies.
        registry.registryHasLoaded = true
        XCTAssertEqual(sut.applyIfNeeded(), .apply(uuid: lowerId))
        XCTAssertTrue(recorder.events.contains(.selectLibrary(lowerId)))
    }

    // MARK: - The four re-application questions from the ticket

    func testSecondLaunch_WithAnUnchangedConfiguration_DoesNotReapply() {
        // "On app update" — and on every ordinary relaunch.
        let registry = RegistryDouble(loaded: true, accounts: [
            account(id: lowerId, title: "Lower", catalog: lowerCatalog)
        ])
        let recorder = ApplyRecorder()
        let sut = makeSUT(managed: ["defaultLibraryId": lowerId], registry: registry, recorder: recorder)

        XCTAssertEqual(sut.applyIfNeeded(), .apply(uuid: lowerId))
        recorder.events = []
        XCTAssertEqual(sut.applyIfNeeded(), .alreadyApplied)
        XCTAssertEqual(recorder.events, [])
    }

    func testStudentWhoRemovesTheConfiguredLibrary_IsNotOverriddenOnNextLaunch() {
        let registry = RegistryDouble(loaded: true, accounts: [
            account(id: lowerId, title: "Lower", catalog: lowerCatalog)
        ])
        let recorder = ApplyRecorder()
        let sut = makeSUT(managed: ["defaultLibraryId": lowerId], registry: registry, recorder: recorder)
        _ = sut.applyIfNeeded()

        // Student removes it in Settings.
        recorder.existingIds = []
        recorder.events = []

        XCTAssertEqual(sut.applyIfNeeded(), .alreadyApplied)
        XCTAssertEqual(recorder.events, [], "the app does not fight the user")
    }

    func testMDMThatChangesTheConfiguredLibrary_RepointsTheDevice() {
        let registry = RegistryDouble(loaded: true, accounts: [
            account(id: lowerId, title: "Lower", catalog: lowerCatalog),
            account(id: middleId, title: "Middle", catalog: middleCatalog)
        ])
        let recorder = ApplyRecorder()
        let sut = makeSUT(managed: ["defaultLibraryId": lowerId], registry: registry, recorder: recorder)
        XCTAssertEqual(sut.applyIfNeeded(), .apply(uuid: lowerId))

        // Administrator moves the device from the Lower to the Middle group.
        defaults.set(["defaultLibraryId": middleId], forKey: ManagedAppConfiguration.userDefaultsKey)
        recorder.events = []

        XCTAssertEqual(sut.applyIfNeeded(), .apply(uuid: middleId))
        XCTAssertEqual(recorder.events.last, .announce)
        XCTAssertTrue(recorder.events.contains(.selectLibrary(middleId)))
        XCTAssertTrue(recorder.events.contains(.setMainFeed(middleCatalog)))
    }

    func testReimagedDevice_WithWipedDefaults_AppliesAgain() {
        let registry = RegistryDouble(loaded: true, accounts: [
            account(id: lowerId, title: "Lower", catalog: lowerCatalog)
        ])
        let recorder = ApplyRecorder()
        let sut = makeSUT(managed: ["defaultLibraryId": lowerId], registry: registry, recorder: recorder)
        _ = sut.applyIfNeeded()

        // Re-image: the app container, and with it the fingerprint, is gone.
        // The MDM pushes the configuration again to the fresh install.
        defaults.removeObject(forKey: ManagedLibraryPreconfigurator.appliedFingerprintKey)
        recorder.existingIds = []
        recorder.events = []

        XCTAssertEqual(sut.applyIfNeeded(), .apply(uuid: lowerId))
        XCTAssertTrue(recorder.events.contains(.selectLibrary(lowerId)))
    }

    // MARK: - Unmanaged install

    func testUnmanagedInstall_IsUntouched() {
        let registry = RegistryDouble(loaded: true, accounts: [
            account(id: lowerId, title: "Lower", catalog: lowerCatalog)
        ])
        let recorder = ApplyRecorder()
        let sut = makeSUT(managed: nil, registry: registry, recorder: recorder)

        XCTAssertEqual(sut.applyIfNeeded(), .noConfiguration)
        XCTAssertEqual(recorder.events, [])
        XCTAssertEqual(registry.uuidLookups, [])
    }
}

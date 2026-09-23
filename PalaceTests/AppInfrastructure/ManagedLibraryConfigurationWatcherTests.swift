//
//  ManagedLibraryConfigurationWatcherTests.swift
//  PalaceTests
//
//  PP-5070 — a configuration that arrives AFTER the launch decision.
//
//  Apple does not promise the managed configuration is present before an app's
//  first launch. If it is not, the old behaviour showed the library picker and
//  never reconsidered — failing on exactly the launch this feature exists to
//  improve. These tests pin that a late configuration is honoured, and that an
//  unmanaged install pays nothing for the privilege.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

private final class WatcherRegistryStub: ManagedLibraryRegistryReading {
    var registryHasLoaded = true
    var accounts: [Account] = []
    private(set) var lookups = 0
    private(set) var listings = 0
    func managedLibraryAccount(uuid: String) -> Account? {
        lookups += 1
        return accounts.first { $0.uuid == uuid }
    }
    func managedLibraryAccounts() -> [Account] {
        listings += 1
        return accounts
    }
}

final class ManagedLibraryConfigurationWatcherTests: XCTestCase {

    private let lower  = "urn:uuid:681710a7-d1c2-4649-a29d-4fbd08e8861e"
    private let middle = "urn:uuid:700116df-9251-4028-b49f-ceeb69f8ce07"

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var registry: WatcherRegistryStub!
    private var selected: [String] = []

    override func setUp() {
        super.setUp()
        suiteName = "ManagedLibraryConfigurationWatcherTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        registry = WatcherRegistryStub()
        selected = []
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        registry = nil
        suiteName = nil
        super.tearDown()
    }

    private func account(_ id: String) -> Account {
        Account(
            publication: OPDS2Publication(
                links: [OPDS2Link(href: "https://il.thepalaceproject.org/\(id.suffix(6))/",
                                  rel: "http://opds-spec.org/catalog")],
                metadata: OPDS2Publication.Metadata(id: id, title: "Fixture"),
                images: nil
            ),
            imageCache: MockImageCache()
        )
    }

    private func makeWatcher() -> ManagedLibraryConfigurationWatcher {
        let preconfigurator = ManagedLibraryPreconfigurator(
            defaults: defaults,
            registry: registry,
            dependencies: ManagedLibraryApplyDependencies(
                addedLibraryIds: { [] },
                setAddedLibraryIds: { _ in },
                setMainFeedURL: { _ in },
                selectLibrary: { [unowned self] in selected.append($0.uuid) },
                loadAuthenticationDocument: { _ in },
                announceLibraryChanged: { }
            )
        )
        return ManagedLibraryConfigurationWatcher(
            defaults: defaults,
            preconfigurator: preconfigurator
        )
    }

    private func setConfiguration(_ id: String?) {
        if let id {
            defaults.set(["defaultLibraryId": id], forKey: ManagedAppConfiguration.userDefaultsKey)
        } else {
            defaults.removeObject(forKey: ManagedAppConfiguration.userDefaultsKey)
        }
    }

    // MARK: - The case this exists for

    func testConfigurationArrivingAfterLaunch_IsHonoured() {
        // The app started with nothing configured — the picker would already be
        // on screen — and the MDM's configuration lands a moment later.
        registry.accounts = [account(lower)]
        let watcher = makeWatcher()
        XCTAssertNil(ManagedAppConfiguration.libraryPreconfiguration(defaults: defaults))

        setConfiguration(lower)
        var applied: [ManagedLibraryDecision] = []
        watcher.reevaluate { applied.append($0) }

        XCTAssertEqual(applied, [.apply(uuid: lower)])
        XCTAssertEqual(selected, [lower])
    }

    func testCallerIsToldOnlyWhenALibraryActuallyBecameCurrent() {
        // The caller uses this to take the picker away. Firing when nothing was
        // applied would dismiss a picker the patron still needs.
        registry.accounts = []   // nothing resolves
        let watcher = makeWatcher()

        setConfiguration(lower)
        var applied: [ManagedLibraryDecision] = []
        watcher.reevaluate { applied.append($0) }

        XCTAssertEqual(applied, [], "unresolved must not dismiss the picker")
        XCTAssertEqual(selected, [])
    }

    func testAnMDMChangingTheConfiguration_RepointsTheDevice() {
        // Moving a device between division groups mid-year.
        registry.accounts = [account(lower), account(middle)]
        let watcher = makeWatcher()
        setConfiguration(lower)
        watcher.reevaluate { _ in }
        XCTAssertEqual(selected, [lower])

        setConfiguration(middle)
        watcher.reevaluate { _ in }

        XCTAssertEqual(selected, [lower, middle])
    }

    // MARK: - What an unmanaged install pays

    func testUnrelatedDefaultsWrites_DoNothingAtAll() {
        // `UserDefaults.didChangeNotification` fires on every defaults write the
        // app makes, which is constantly. An unmanaged install must not walk the
        // account registry each time.
        let watcher = makeWatcher()

        for i in 0..<25 {
            defaults.set(i, forKey: "SomeUnrelatedKey")
            watcher.reevaluate { _ in XCTFail("nothing was configured") }
        }

        XCTAssertEqual(registry.lookups, 0)
        XCTAssertEqual(registry.listings, 0)
        XCTAssertEqual(selected, [])
    }

    func testAnUnchangedConfiguration_IsNotReapplied() {
        registry.accounts = [account(lower)]
        let watcher = makeWatcher()
        setConfiguration(lower)
        watcher.reevaluate { _ in }
        let lookupsAfterFirst = registry.lookups

        for _ in 0..<10 {
            defaults.set(UUID().uuidString, forKey: "Noise")
            watcher.reevaluate { _ in XCTFail("fingerprint did not move") }
        }

        XCTAssertEqual(registry.lookups, lookupsAfterFirst, "no further registry work")
        XCTAssertEqual(selected, [lower], "selected exactly once")
    }

    func testAConfigurationPresentBeforeTheWatcherStarts_IsNotReappliedByIt() {
        // The launch path already handled it. The watcher exists for what
        // arrives later, and must not double-apply what was there all along.
        registry.accounts = [account(lower)]
        setConfiguration(lower)
        let watcher = makeWatcher()

        watcher.reevaluate { _ in XCTFail("already handled at launch") }

        XCTAssertEqual(selected, [])
    }

    // MARK: - Removal

    func testTheMDMRemovingTheConfiguration_LeavesTheLibraryAlone() {
        // A student may be mid-book. Apple removes a managed app and its data
        // outright when management ends, so there is nothing for us to tidy —
        // and silently deselecting a library would be the worse surprise.
        registry.accounts = [account(lower)]
        let watcher = makeWatcher()
        setConfiguration(lower)
        watcher.reevaluate { _ in }
        XCTAssertEqual(selected, [lower])

        setConfiguration(nil)
        var applied: [ManagedLibraryDecision] = []
        watcher.reevaluate { applied.append($0) }

        XCTAssertEqual(applied, [], "removal is not an apply")
        XCTAssertEqual(selected, [lower], "the library stays selected")
    }

    func testAConfigurationRemovedThenRestored_IsNoticedAgain() {
        registry.accounts = [account(lower), account(middle)]
        let watcher = makeWatcher()
        setConfiguration(lower)
        watcher.reevaluate { _ in }

        setConfiguration(nil)
        watcher.reevaluate { _ in }

        setConfiguration(middle)
        watcher.reevaluate { _ in }

        XCTAssertEqual(selected, [lower, middle])
    }

    // MARK: - Observer hygiene

    func testStartingTwice_DoesNotStackObservers() {
        registry.accounts = [account(lower)]
        let center = NotificationCenter()
        let preconfigurator = ManagedLibraryPreconfigurator(
            defaults: defaults,
            registry: registry,
            dependencies: ManagedLibraryApplyDependencies(
                addedLibraryIds: { [] },
                setAddedLibraryIds: { _ in },
                setMainFeedURL: { _ in },
                selectLibrary: { [unowned self] in selected.append($0.uuid) },
                loadAuthenticationDocument: { _ in },
                announceLibraryChanged: { }
            )
        )
        let watcher = ManagedLibraryConfigurationWatcher(
            defaults: defaults, preconfigurator: preconfigurator, notificationCenter: center
        )
        var applyCount = 0
        watcher.start { _ in applyCount += 1 }
        watcher.start { _ in applyCount += 1 }

        setConfiguration(lower)
        center.post(name: UserDefaults.didChangeNotification, object: defaults)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        XCTAssertEqual(applyCount, 1, "a second start must not stack a second observer")
        watcher.stop()
    }

    func testStopping_EndsTheWatch() {
        registry.accounts = [account(lower)]
        let center = NotificationCenter()
        let preconfigurator = ManagedLibraryPreconfigurator(
            defaults: defaults,
            registry: registry,
            dependencies: ManagedLibraryApplyDependencies(
                addedLibraryIds: { [] },
                setAddedLibraryIds: { _ in },
                setMainFeedURL: { _ in },
                selectLibrary: { [unowned self] in selected.append($0.uuid) },
                loadAuthenticationDocument: { _ in },
                announceLibraryChanged: { }
            )
        )
        let watcher = ManagedLibraryConfigurationWatcher(
            defaults: defaults, preconfigurator: preconfigurator, notificationCenter: center
        )
        watcher.start { _ in XCTFail("watch was stopped") }
        watcher.stop()

        setConfiguration(lower)
        center.post(name: UserDefaults.didChangeNotification, object: defaults)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        XCTAssertEqual(selected, [])
    }
}

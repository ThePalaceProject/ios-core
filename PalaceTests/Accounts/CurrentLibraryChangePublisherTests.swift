//
//  CurrentLibraryChangePublisherTests.swift
//  PalaceTests
//
//  Pins how `AccountsManager.currentLibraryChangePublisher` announces a library
//  selection or a reload request, and on which thread listeners receive it.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
import PalaceCatalog
import PalacePreferences
@testable import Palace

@MainActor
final class CurrentLibraryChangePublisherTests: PalaceWiringTestCase {

    /// Assigning `currentAccount` emits exactly one `.selected`, before the
    /// assignment returns, so listeners act on the switch in the same turn.
    func testSettingCurrentAccount_EmitsSelectedBeforeAssignmentReturns() {
        let manager = makeFreshAccountsManager(defaults: Self.testUserDefaults())
        var received: [CurrentLibraryChange] = []
        manager.currentLibraryChangePublisher
            .sink { received.append($0) }
            .store(in: &cancellables)

        manager.currentAccount = Self.makeAccount(uuid: "urn:uuid:clc-select-\(UUID().uuidString)")

        XCTAssertEqual(received, [.selected])
    }

    /// A reload request emits `.refreshRequested` and leaves the current
    /// library unchanged.
    func testRequestCurrentLibraryRefresh_EmitsRefreshRequestedWithoutChangingLibrary() {
        let uuid = "urn:uuid:clc-refresh-\(UUID().uuidString)"
        let defaults = Self.testUserDefaults()
        defaults.set(uuid, forKey: currentAccountIdentifierKey)
        let manager = makeFreshAccountsManager(defaults: defaults)
        var received: [CurrentLibraryChange] = []
        manager.currentLibraryChangePublisher
            .sink { received.append($0) }
            .store(in: &cancellables)

        manager.requestCurrentLibraryRefresh()

        XCTAssertEqual(received, [.refreshRequested])
        XCTAssertEqual(manager.currentAccountId, uuid)
    }

    /// Each manager announces only its own changes. Tests build their own
    /// managers, so a change on one must not reach another's listeners.
    func testChangeOnOneManager_IsNotDeliveredToAnotherManagersListeners() {
        let first = makeFreshAccountsManager(defaults: Self.testUserDefaults())
        let second = makeFreshAccountsManager(defaults: Self.testUserDefaults())
        var secondReceived: [CurrentLibraryChange] = []
        second.currentLibraryChangePublisher
            .sink { secondReceived.append($0) }
            .store(in: &cancellables)

        first.requestCurrentLibraryRefresh()
        first.currentAccount = Self.makeAccount(uuid: "urn:uuid:clc-iso-\(UUID().uuidString)")

        XCTAssertEqual(secondReceived, [])
    }

    /// A catalog load that applies its feed asks the manager's listeners to
    /// reload, so screens pick up the refreshed library list and details.
    func testCatalogLoadThatApplies_EmitsRefreshRequested() async throws {
        let manager = makeFreshAccountsManager(defaults: Self.testUserDefaults())
        var received: [CurrentLibraryChange] = []
        manager.currentLibraryChangePublisher
            .sink { received.append($0) }
            .store(in: &cancellables)
        let uuids = ["urn:uuid:clc-load-a-\(UUID().uuidString)", "urn:uuid:clc-load-b-\(UUID().uuidString)"]
        let feed = try XCTUnwrap(LibraryCatalogMerger.serializeAsCatalogsFeed(
            publications: uuids.map {
                OPDS2Publication(links: [], metadata: .init(id: $0, title: "Library"), images: nil)
            },
            metadata: OPDS2CatalogsFeed.Metadata(adobe_vendor_id: "ThePalaceProject", title: "Libraries", numberOfItems: 2)
        ))

        // With no current library the loader's DispatchGroup is empty, so its
        // main-queue completion is queued before the call returns; one drain joins it.
        var completed = false
        manager.loadAccountSetsAndAuthDoc(fromCatalogData: feed, key: "clc-\(UUID().uuidString)") { _ in
            completed = true
        }
        await drainMainQueueAsync()

        XCTAssertTrue(completed, "premise: the load must have completed")
        XCTAssertEqual(received, [.refreshRequested])
        uuids.forEach { AccountStateStore.shared.reset(for: $0) }
    }

    /// Switching library from Settings selects it, then asks listeners to
    /// reload before the authentication document has loaded.
    func testSettingsLibrarySwitch_AnnouncesSelectionThenRefresh() {
        let manager = makeFreshAccountsManager(defaults: Self.testUserDefaults())
        let environment = ProductionLibrariesSectionEnvironment(
            accountsManager: manager,
            settings: TPPSettings(defaults: Self.testUserDefaults()),
            tokenDeleter: { _ in },
            queuedActionRemover: { _ in }
        )
        var received: [CurrentLibraryChange] = []
        manager.currentLibraryChangePublisher
            .sink { received.append($0) }
            .store(in: &cancellables)

        environment.switchToAccount(Self.makeAccount(uuid: "urn:uuid:clc-settings-\(UUID().uuidString)")) {}

        XCTAssertEqual(received, [.selected, .refreshRequested])
    }

    /// Applying a managed library configuration announces through the
    /// container's accounts manager.
    func testManagedLibraryAnnouncement_RequestsRefreshOnContainerManager() {
        let container = makeTestAppContainer()
        var received: [CurrentLibraryChange] = []
        container.accountsManager.currentLibraryChangePublisher
            .sink { received.append($0) }
            .store(in: &cancellables)

        ManagedLibraryApplyDependencies.production(appContainer: container).announceLibraryChanged()

        XCTAssertEqual(received, [.refreshRequested])
    }

    /// Every subscriber gets each change; the registry, Holds and the catalog
    /// all listen at once.
    func testEverySubscriber_ReceivesEachChange() {
        let broadcaster = CurrentLibraryChangeBroadcaster()
        var first: [CurrentLibraryChange] = []
        var second: [CurrentLibraryChange] = []
        broadcaster.publisher.sink { first.append($0) }.store(in: &cancellables)
        broadcaster.publisher.sink { second.append($0) }.store(in: &cancellables)

        broadcaster.send(.selected)
        broadcaster.send(.refreshRequested)

        XCTAssertEqual(first, [.selected, .refreshRequested])
        XCTAssertEqual(second, [.selected, .refreshRequested])
    }

    /// A send from a background thread reaches listeners on the main thread,
    /// because most listeners update main-actor UI state.
    func testSendFromBackgroundThread_DeliversOnMainThread() async {
        let broadcaster = CurrentLibraryChangeBroadcaster()
        var deliveredOnMain: [Bool] = []
        broadcaster.publisher
            .sink { _ in deliveredOnMain.append(Thread.isMainThread) }
            .store(in: &cancellables)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue(label: "clc.offmain").async {
                broadcaster.send(.refreshRequested)
                cont.resume()
            }
        }
        await drainMainQueueAsync()

        XCTAssertEqual(deliveredOnMain, [true])
    }

    private static func makeAccount(uuid: String) -> Account {
        let metadata = OPDS2Publication.Metadata(id: uuid, title: "Current library \(uuid.suffix(6))")
        let publication = OPDS2Publication(links: [], metadata: metadata, images: nil)
        return Account(publication: publication, imageCache: MockImageCache())
    }
}

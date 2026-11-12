//
//  AccountScopedResetTests.swift
//  PalaceTests
//
//  A library switch tells per-account services to reset before its cleanup
//  runs, leaves process-lifetime services such as audiobook playback alone,
//  and every stored service has a recorded decision (PP-5545).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import XCTest
import PalaceCatalog
import PalaceBookModel
@testable import Palace

@MainActor
final class AccountScopedResetTests: XCTestCase {

    private var touchedAccountUUIDs: [String] = []
    private var cancellables = Set<AnyCancellable>()

    override func tearDown() {
        cancellables.removeAll()
        touchedAccountUUIDs.forEach { AccountStateStore.shared.reset(for: $0) }
        touchedAccountUUIDs = []
        super.tearDown()
    }

    // MARK: - Event order

    /// `.willSwitch` comes before the switch cancels requests, `.selected` after.
    func testRealSwitch_SendsWillSwitchBeforeCleanupAndSelectedAfter() async {
        let log = SwitchLog()
        let executor = CleanupObservingExecutor(cachingStrategy: .ephemeral)
        executor.onCancel = { log.entries.append("cleanup") }
        let container = makeTestAppContainer(bookRegistry: TPPBookRegistryMock(), networkExecutor: executor)
        let (prior, next) = seedSwitch(in: container)
        container.accountsManager.accountSwitchPublisher
            .sink { log.entries.append(Self.describe($0)) }
            .store(in: &cancellables)

        container.accountsManager.currentAccount = Self.makeAccount(uuid: next)
        await awaitConditionAsync { !container.accountsManager.isAccountSwitching }

        XCTAssertEqual(log.entries, ["willSwitch(\(prior)→\(next))", "cleanup", "selected"])
    }

    /// Selecting the first library, or the one already current, is not a switch.
    func testSelectionThatIsNotASwitch_SendsNoWillSwitch() {
        let container = makeTestAppContainer(bookRegistry: TPPBookRegistryMock())
        let uuid = "urn:uuid:scoped-only-\(UUID().uuidString)"
        touchedAccountUUIDs = [uuid]
        var events: [String] = []
        container.accountsManager.accountSwitchPublisher
            .sink { events.append(Self.describe($0)) }
            .store(in: &cancellables)

        container.accountsManager.currentAccount = Self.makeAccount(uuid: uuid)
        container.accountsManager.currentAccount = Self.makeAccount(uuid: uuid)

        XCTAssertEqual(events, ["selected", "selected"])
    }

    /// Existing library-change listeners keep receiving only `.selected` on a switch.
    func testRealSwitch_LibraryChangePublisherCarriesNoWillSwitch() async {
        let container = makeTestAppContainer(bookRegistry: TPPBookRegistryMock())
        let (_, next) = seedSwitch(in: container)
        var events: [String] = []
        container.accountsManager.currentLibraryChangePublisher
            .sink { events.append(Self.describe($0)) }
            .store(in: &cancellables)

        container.accountsManager.currentAccount = Self.makeAccount(uuid: next)
        await awaitConditionAsync { !container.accountsManager.isAccountSwitching }

        XCTAssertEqual(events, ["selected"])
    }

    // MARK: - Reset dispatch

    /// The container's cell-model cache is empty by the time the switch
    /// cancels requests: the reset ran on `.willSwitch`, not after the switch.
    func testRealSwitch_ResetsAccountScopedServicesBeforeCleanup() async {
        let executor = CleanupObservingExecutor(cachingStrategy: .ephemeral)
        let container = makeTestAppContainer(bookRegistry: TPPBookRegistryMock(), networkExecutor: executor)
        let cache = container.bookCellModelCache
        _ = cache.model(for: TPPBookMocker.mockBook(distributorType: .EpubZip))
        XCTAssertEqual(cache.count, 1, "Setup: the cache must hold a model, or an empty count proves nothing")
        var countAtCleanup: Int?
        executor.onCancel = { countAtCleanup = MainActor.assumeIsolated { cache.count } }
        let (_, next) = seedSwitch(in: container)

        container.accountsManager.currentAccount = Self.makeAccount(uuid: next)
        await awaitConditionAsync { !container.accountsManager.isAccountSwitching }

        XCTAssertEqual(countAtCleanup, 0, "Per-account services must reset before the switch cleanup runs")
    }

    /// A switch on A resets A's services and leaves B's alone.
    func testRealSwitch_OnContainerA_ResetsOnlyItsOwnServices() async {
        let containerA = makeTestAppContainer(bookRegistry: TPPBookRegistryMock())
        let containerB = makeTestAppContainer(bookRegistry: TPPBookRegistryMock())
        _ = containerA.bookCellModelCache.model(for: TPPBookMocker.mockBook(distributorType: .EpubZip))
        _ = containerB.bookCellModelCache.model(for: TPPBookMocker.mockBook(distributorType: .EpubZip))
        let (_, next) = seedSwitch(in: containerA)

        containerA.accountsManager.currentAccount = Self.makeAccount(uuid: next)
        await awaitConditionAsync { !containerA.accountsManager.isAccountSwitching }
        await drainMainQueueAsync()

        XCTAssertEqual(containerA.bookCellModelCache.count, 0, "The container that switched must drop its models")
        XCTAssertEqual(containerB.bookCellModelCache.count, 1, "Another container's cache must keep its models")
    }

    /// A refresh of the same library is not a switch, so the container does
    /// not reset its services synchronously; the cache clears on its own hop.
    func testRefreshRequest_DoesNotRunTheSwitchReset() {
        let container = makeTestAppContainer(bookRegistry: TPPBookRegistryMock())
        let cache = container.bookCellModelCache
        _ = cache.model(for: TPPBookMocker.mockBook(distributorType: .EpubZip))

        container.accountsManager.requestCurrentLibraryRefresh()

        XCTAssertEqual(cache.count, 1, "Only .willSwitch may run the switch reset")
    }

    /// Leaving a library for none is a switch too: `.willSwitch` names no target.
    func testSwitchToNoLibrary_SendsWillSwitchWithNilTarget() async {
        let container = makeTestAppContainer(bookRegistry: TPPBookRegistryMock())
        let (prior, _) = seedSwitch(in: container)
        var events: [String] = []
        container.accountsManager.accountSwitchPublisher
            .sink { events.append(Self.describe($0)) }
            .store(in: &cancellables)

        container.accountsManager.currentAccount = nil
        await awaitConditionAsync { !container.accountsManager.isAccountSwitching }

        XCTAssertEqual(events, ["willSwitch(\(prior)→nil)", "selected"])
    }

    // MARK: - Playback survives a switch

    /// A library switch must not stop audiobook playback; CarPlay and the
    /// lock screen keep the book playing across it.
    func testRealSwitch_DoesNotStopAudiobookPlayback() async throws {
        let container = makeTestAppContainer(bookRegistry: TPPBookRegistryMock())
        let session = try XCTUnwrap(container.audiobookSession as? AudiobookSessionManager)
        var states: [AudiobookSessionState] = []
        session.playbackStatePublisher.sink { states.append($0) }.store(in: &cancellables)
        let (_, next) = seedSwitch(in: container)

        container.accountsManager.currentAccount = Self.makeAccount(uuid: next)
        await awaitConditionAsync { !container.accountsManager.isAccountSwitching }
        await drainMainQueueAsync()

        XCTAssertFalse(states.contains(.idle), "A library switch must not stop the audiobook session")
        XCTAssertFalse(container.accountScopedServices().contains { $0 === session },
                       "The audiobook session must not be reset on a library switch")
        await session.stopPlayback(dismissPhoneUI: false)
        XCTAssertTrue(states.contains(.idle), "Premise: this observer must see a stop when one happens")
    }

    // MARK: - Census

    /// Every stored service has a decision: it resets on a switch, or it
    /// lives for the process. A new cell fails here until it is classified,
    /// and a reset service missing from `accountScopedServices()` fails too.
    func testCensus_EveryStoredServiceIsClassified() throws {
        let container = makeTestAppContainer(bookRegistry: TPPBookRegistryMock())
        Self.materializeEveryService(in: container)
        let resetters = container.accountScopedServices()

        let process = Mirror(reflecting: container.processServices).children
        let owned = try XCTUnwrap(ownedServicesStorage(of: container), "Could not read the owned services")
        let children = Array(process) + Array(Mirror(reflecting: owned).children)
        let lockHeld = Self.lockHeldServices(of: container.processServices)
        XCTAssertGreaterThan(children.count, 12, "Expected to read every stored service")

        for child in children {
            let label = child.label ?? "<unlabelled>"
            if label == "accountSwitchSubscription" { continue }
            let value: Any?
            if String(describing: type(of: child.value)).hasPrefix("OSAllocatedUnfairLock") {
                guard let held = lockHeld[label] else {
                    XCTFail("\(label) is lock-held; read it through its lock in lockHeldServices(of:)")
                    continue
                }
                value = held
            } else {
                value = Self.unwrapped(child.value)
            }
            guard Self.resetOnSwitch.contains(label) || Self.livesForTheProcess.contains(label) else {
                XCTFail("\(label) has no lifetime decision; add it to resetOnSwitch or livesForTheProcess")
                continue
            }
            let service = try XCTUnwrap(value, "Setup: \(label) must be built before it is checked")
            if Self.resetOnSwitch.contains(label) {
                let resetter = try XCTUnwrap(service as? AccountScopedResetting,
                                             "\(label) is listed as reset on a switch but does not conform")
                XCTAssertTrue(resetters.contains { $0 === resetter },
                              "\(label) conforms but is missing from accountScopedServices()")
            } else {
                XCTAssertFalse(service is AccountScopedResetting,
                               "\(label) conforms to AccountScopedResetting; move it to resetOnSwitch")
            }
        }
        XCTAssertEqual(resetters.count, Self.resetOnSwitch.count)
    }

    /// Services that hold state for the current library.
    private static let resetOnSwitch: Set<String> = [
        "playtimeUploader",   // in-flight sends the switch cancels
        "bookCellModelCache", // models for the previous library's books
    ]

    /// Services that read the current library live, key their state by
    /// library, or must survive a switch (audiobook playback, CarPlay).
    private static let livesForTheProcess: Set<String> = [
        "samplePreviewManager", "audiobookSession", "audiobookSessionPresenter", "playbackBootstrapper",
        "appRatingService", "ratingPromptPresenter", "activityPolicy",
        "sideloadedBookRegistry", "sideloadedBookManager", "offlineQueueCoordinator",
        "signInModalSheetPresenter", "catalogAPI", "catalogRepository",
    ]

    /// The cells kept behind a lock, read through it so their values can be
    /// checked. A cell that is still empty keeps its key with a nil value.
    private static func lockHeldServices(of services: ProcessServices) -> [String: Any?] {
        [
            "sideloadedBookRegistry": services.sideloadedBookRegistry.withLock { $0 } as Any?,
            "sideloadedBookManager": services.sideloadedBookManager.withLock { $0 } as Any?,
            "offlineQueueCoordinator": services.offlineQueueCoordinator.withLock { $0 } as Any?,
        ]
    }

    // MARK: - Helpers

    /// Seeds a current library and returns it with the next one's UUID.
    private func seedSwitch(in container: AppContainer) -> (prior: String, next: String) {
        let prior = "urn:uuid:scoped-prior-\(UUID().uuidString)"
        let next = "urn:uuid:scoped-next-\(UUID().uuidString)"
        touchedAccountUUIDs = [prior, next]
        let cleanup = container.accountsManager._seedAccountForTesting(Self.makeAccount(uuid: prior))
        addTeardownBlock { cleanup() }
        return (prior, next)
    }

    private static func materializeEveryService(in container: AppContainer) {
        _ = container.samplePreviewManager
        _ = container.audiobookSessionPresenter
        _ = container.playbackBootstrapper
        _ = container.ratingPromptPresenter
        _ = container.playtimeUploader
        _ = container.sideloadedBookManager
        // Filled directly: registering would point the app-wide offline queue
        // at a coordinator that dies with this test's container.
        let coordinator = OfflineQueueCoordinator.production(
            downloadCenter: container.downloadCenter,
            bookRegistry: container.bookRegistry,
            currentLibraryID: { nil }
        )
        container.processServices.offlineQueueCoordinator.withLock { $0 = coordinator }
        _ = container.bookCellModelCache
        _ = container.catalogRepository
        _ = container.signInModalSheetPresenter
    }

    private func ownedServicesStorage(of container: AppContainer) -> AppContainerOwnedServices? {
        let link = Mirror(reflecting: container).children.first { $0.label == "ownedServicesLink" }?.value
        return link.flatMap { Mirror(reflecting: $0).children.first?.value as? AppContainerOwnedServices }
    }

    /// The value inside an optional cell, so conformance can be checked.
    private static func unwrapped(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            return mirror.children.first.map { unwrapped($0.value) } ?? nil
        }
        return value
    }

    private static func describe(_ change: CurrentLibraryChange) -> String {
        switch change {
        case .willSwitch(let from, let to): return "willSwitch(\(from)→\(to ?? "nil"))"
        case .selected: return "selected"
        case .refreshRequested: return "refreshRequested"
        }
    }

    /// Link-less publication, so the switch drives no network fetch.
    private static func makeAccount(uuid: String) -> Account {
        let metadata = OPDS2Publication.Metadata(updated: Date(), description: "scoped", id: uuid,
                                                 title: "Scoped \(uuid.suffix(6))")
        let publication = OPDS2Publication(links: [], metadata: metadata, images: nil)
        return Account(publication: publication, imageCache: MockImageCache())
    }
}

/// Collects switch events and cleanup calls in the order they happen.
private final class SwitchLog: @unchecked Sendable {
    var entries: [String] = []
}

/// Runs a hook where the switch would cancel requests, instead of cancelling.
private final class CleanupObservingExecutor: TPPNetworkExecutor, @unchecked Sendable {
    var onCancel: () -> Void = {}

    override func cancelNonEssentialTasks() {
        onCancel()
    }
}

//
//  AccountsManagerEventPublisherTests.swift
//  PalaceTests
//
//  Pins the catalog-loaded and sign-in progress publishers on AccountsManager.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
import PalaceCatalog
@testable import Palace

@MainActor
final class AccountsManagerEventPublisherTests: PalaceWiringTestCase {

    /// A catalog load from the disk cache tells the manager's listeners once,
    /// so the library picker refreshes its list. Once holds here because the
    /// fixture starts no background refresh; in the app that refresh announces again.
    func testLoadCatalogsFromCache_EmitsCatalogLoadedOnce() async throws {
        let uuids = ["urn:uuid:cat-loaded-a-\(UUID().uuidString)", "urn:uuid:cat-loaded-b-\(UUID().uuidString)"]
        let manager = makeFreshAccountsManager(
            defaults: Self.testUserDefaults(),
            registryCache: CachedFeed(data: try Self.feed(uuids: uuids)),
            crawlScheduler: .neverStarts
        )
        var loads = 0
        manager.catalogLoadedPublisher
            .sink { loads += 1 }
            .store(in: &cancellables)

        var completedSuccess: Bool?
        manager.loadCatalogs { success in completedSuccess = success }
        await drainMainQueueAsync()

        XCTAssertEqual(completedSuccess, true, "premise: the cached load must complete")
        XCTAssertEqual(loads, 1)
        uuids.forEach { AccountStateStore.shared.reset(for: $0) }
    }

    /// Each manager announces only its own catalog loads.
    func testCatalogLoadOnOneManager_IsNotDeliveredToAnother() async throws {
        let uuids = ["urn:uuid:cat-iso-\(UUID().uuidString)"]
        let loading = makeFreshAccountsManager(
            defaults: Self.testUserDefaults(),
            registryCache: CachedFeed(data: try Self.feed(uuids: uuids)),
            crawlScheduler: .neverStarts
        )
        let other = makeFreshAccountsManager(defaults: Self.testUserDefaults())
        var loadingLoads = 0
        loading.catalogLoadedPublisher
            .sink { loadingLoads += 1 }
            .store(in: &cancellables)
        var otherLoads = 0
        other.catalogLoadedPublisher
            .sink { otherLoads += 1 }
            .store(in: &cancellables)

        var completed = false
        loading.loadCatalogs { _ in completed = true }
        await drainMainQueueAsync()

        XCTAssertTrue(completed, "premise: the cached load must complete")
        XCTAssertEqual(loadingLoads, 1, "premise: the loading manager must announce its load")
        XCTAssertEqual(otherLoads, 0)
        uuids.forEach { AccountStateStore.shared.reset(for: $0) }
    }

    /// Sign-in progress reported to the manager reaches its listeners in order.
    func testReportSignInProgress_EmitsEachReportInOrder() {
        let manager = makeFreshAccountsManager(defaults: Self.testUserDefaults())
        var received: [SignInProgress] = []
        manager.signInProgressPublisher
            .sink { received.append($0) }
            .store(in: &cancellables)

        manager.reportSignInProgress(.started)
        manager.reportSignInProgress(.finished)

        XCTAssertEqual(received, [.started, .finished])
    }

    private static func feed(uuids: [String]) throws -> Data {
        try XCTUnwrap(LibraryCatalogMerger.serializeAsCatalogsFeed(
            publications: uuids.map {
                OPDS2Publication(links: [], metadata: .init(id: $0, title: "Library"), images: nil)
            },
            metadata: OPDS2CatalogsFeed.Metadata(adobe_vendor_id: "ThePalaceProject", title: "Libraries", numberOfItems: uuids.count)
        ))
    }
}

/// Serves `data` as a fresh cached catalog for every hash, so `loadCatalogs`
/// takes the disk-cache path.
private final class CachedFeed: AccountRegistryCaching, @unchecked Sendable {
    private let data: Data
    init(data: Data) { self.data = data }
    func writeCatalogData(_ data: Data, hash: String, isBundled: Bool) {}
    func readCatalogData(hash: String) -> Data? { data }
    func hasFreshCatalogData(hash: String) -> Bool { true }
    func isCatalogStale(hash: String) -> Bool { false }
    func slimSnapshotURL(hash: String) -> URL? { nil }
    func clearFileCaches() {}
}

private extension CrawlTaskScheduler {
    /// Returns finished tasks without running the operation, so the disk-cache
    /// path's background refresh never reaches the network.
    static let neverStarts = CrawlTaskScheduler(
        spawn: { _, _ in Task {} },
        spawnDetached: { _, _ in Task {} }
    )
}

//
//  DLNavigatorLoginRetryTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
import PalaceCatalog
@testable import Palace

/// PP-5473 — a deep-link sign-in for a library the registry has not loaded yet
/// retries once the catalog loads, instead of waiting for an event nothing sends.
@MainActor
final class DLNavigatorLoginRetryTests: PalaceWiringTestCase {

    func testRetryLogin_RunsOnceWhenTheCatalogLoads() async throws {
        let uuids = ["urn:uuid:dl-retry-\(UUID().uuidString)"]
        let manager = makeFreshAccountsManager(
            defaults: Self.testUserDefaults(),
            registryCache: CachedCatalog(data: try Self.feed(uuids: uuids)),
            crawlScheduler: .startsNothing
        )
        let retries = RetryCounter()

        DLNavigator.retryLoginWhenCatalogLoads(accountsManager: manager) { retries.count += 1 }
        XCTAssertEqual(retries.count, 0, "precondition: nothing retries before a catalog load")

        var completed = false
        manager.loadCatalogs { _ in completed = true }
        await drainMainQueueAsync()

        XCTAssertTrue(completed, "premise: the cached load must complete")
        XCTAssertEqual(retries.count, 1)
        uuids.forEach { AccountStateStore.shared.reset(for: $0) }
    }

    /// Selecting a library is not a catalog load, so it does not retry: the
    /// library the link names may still be missing from the registry.
    func testRetryLogin_IgnoresALibrarySelection() {
        let manager = makeFreshAccountsManager(defaults: Self.testUserDefaults())
        let retries = RetryCounter()

        DLNavigator.retryLoginWhenCatalogLoads(accountsManager: manager) { retries.count += 1 }
        manager.currentAccount = Self.makeAccount(uuid: "urn:uuid:dl-retry-select-\(UUID().uuidString)")

        XCTAssertEqual(retries.count, 0)
    }

    /// The retry belongs to the manager it was given; another manager's load
    /// must not trigger it.
    func testRetryLogin_IgnoresAnotherManagersCatalogLoad() async throws {
        let uuids = ["urn:uuid:dl-retry-other-\(UUID().uuidString)"]
        let waiting = makeFreshAccountsManager(defaults: Self.testUserDefaults())
        let loading = makeFreshAccountsManager(
            defaults: Self.testUserDefaults(),
            registryCache: CachedCatalog(data: try Self.feed(uuids: uuids)),
            crawlScheduler: .startsNothing
        )
        let retries = RetryCounter()

        DLNavigator.retryLoginWhenCatalogLoads(accountsManager: waiting) { retries.count += 1 }
        var completed = false
        loading.loadCatalogs { _ in completed = true }
        await drainMainQueueAsync()

        XCTAssertTrue(completed, "premise: the other manager's load must complete")
        XCTAssertEqual(retries.count, 0)
        uuids.forEach { AccountStateStore.shared.reset(for: $0) }
    }

    private static func makeAccount(uuid: String) -> Account {
        let metadata = OPDS2Publication.Metadata(id: uuid, title: "Library \(uuid.suffix(6))")
        return Account(publication: OPDS2Publication(links: [], metadata: metadata, images: nil),
                       imageCache: MockImageCache())
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

@MainActor
private final class RetryCounter {
    var count = 0
}

/// Serves `data` as a fresh cached catalog for every hash, so `loadCatalogs`
/// takes the disk-cache path.
private final class CachedCatalog: AccountRegistryCaching, @unchecked Sendable {
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
    static let startsNothing = CrawlTaskScheduler(
        spawn: { _, _ in Task {} },
        spawnDetached: { _, _ in Task {} }
    )
}

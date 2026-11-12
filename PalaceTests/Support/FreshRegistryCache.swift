//
//  FreshRegistryCache.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation
@testable import Palace
import PalaceAccounts

/// Serves `data` as a fresh cached catalog for every hash, so `loadCatalogs`
/// takes the disk-cache path.
final class FreshRegistryCache: AccountRegistryCaching, @unchecked Sendable {
    private let data: Data
    init(data: Data) { self.data = data }
    func writeCatalogData(_ data: Data, hash: String, isBundled: Bool) {}
    func readCatalogData(hash: String) -> Data? { data }
    func hasFreshCatalogData(hash: String) -> Bool { true }
    func isCatalogStale(hash: String) -> Bool { false }
    func slimSnapshotURL(hash: String) -> URL? { nil }
    func clearFileCaches() {}
}

extension CrawlTaskScheduler {
    /// Returns finished tasks without running the operation, so the disk-cache
    /// path's background refresh never reaches the network.
    static let startsNothing = CrawlTaskScheduler(
        spawn: { _, _ in Task {} },
        spawnDetached: { _, _ in Task {} }
    )
}

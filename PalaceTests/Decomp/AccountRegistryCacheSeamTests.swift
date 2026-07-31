//
//  AccountRegistryCacheSeamTests.swift
//  PalaceTests
//
//  Pins the Wave 3 / 3a-1 `AccountRegistryCache` seam: `AccountsManager` reaches
//  the on-disk catalog cache ONLY through the injected `any AccountRegistryCaching`
//  collaborator, never inline FileManager bodies. This is the extraction that lets
//  the hub carry no disk-I/O and move into `PalaceAccounts` cleanly.
//
//  Two lenses:
//   1. Routing (spy) — `clearCache()` clears the file caches through the injected
//      seam (a mutant that drops the call, or clears inline, flips it red).
//   2. Behaviour (real impl) — `DiskAccountRegistryCache` round-trips a write→read
//      and honours the `isBundled` always-stale rule; covers the moved disk bodies
//      end-to-end (the concrete path the spy tests intentionally bypass).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
import PalaceBookModel
@testable import Palace

@MainActor
final class AccountRegistryCacheSeamTests: PalaceWiringTestCase {

    // MARK: - Routing through the injected seam

    /// Contract: `AccountsManager.clearCache()` clears the on-disk caches through
    /// the injected `AccountRegistryCaching`, not an inline FileManager sweep.
    ///
    /// Kill case: dropping `registryCache.clearFileCaches()` (or reverting to the
    /// inline loop) → the spy never records `clearFileCaches` → fails.
    func testClearCache_routesThroughInjectedRegistryCache() {
        let spy = RecordingRegistryCache()
        let manager = makeFreshAccountsManager(
            defaults: Self.testUserDefaults(),
            registryCache: spy
        )

        manager.clearCache()

        XCTAssertTrue(
            spy.clearFileCachesCalled,
            "clearCache() must clear the disk caches through the injected AccountRegistryCaching seam"
        )
    }

    // MARK: - Real disk implementation (moved bodies)

    /// Contract: `DiskAccountRegistryCache` persists and reads back catalog bytes
    /// for a hash, reports freshness after a write, and treats a bundled-origin
    /// write as always-stale (the refresh-keeps-firing rule).
    ///
    /// Kill cases: breaking the write/read URL derivation → read returns nil;
    /// dropping the `isBundled` short-circuit in `isStale` → bundled write reports
    /// not-stale; negating `isExpired` → fresh write reports not-fresh.
    func testDiskCache_roundTripsAndHonorsBundledStaleness() {
        let cache = DiskAccountRegistryCache()
        let hash = "acctcache-\(UUID().uuidString)"
        defer { cache.clearFileCaches() }

        let payload = Data("catalog-bytes-\(hash)".utf8)

        // Network-origin write → readable, fresh, and NOT bundled-stale.
        cache.writeCatalogData(payload, hash: hash, isBundled: false)
        XCTAssertEqual(cache.readCatalogData(hash: hash), payload,
                       "a written catalog blob must read back byte-identical")
        XCTAssertTrue(cache.hasFreshCatalogData(hash: hash),
                      "a just-written catalog must be fresh (not expired)")
        XCTAssertFalse(cache.isCatalogStale(hash: hash),
                       "a just-written network-origin catalog must not be stale")

        // Bundled-origin overwrite → still fresh, but ALWAYS stale for refresh.
        cache.writeCatalogData(payload, hash: hash, isBundled: true)
        XCTAssertTrue(cache.hasFreshCatalogData(hash: hash),
                      "a bundled write is still usable (not expired)")
        XCTAssertTrue(cache.isCatalogStale(hash: hash),
                      "a bundled-origin catalog must report stale so refresh keeps firing")
    }

    /// Contract: the convenience `writeCatalogData(_:hash:)` (protocol-extension
    /// default) writes a non-bundled entry — the ergonomics the hub's network
    /// write sites rely on through the `any AccountRegistryCaching` existential.
    func testDiskCache_convenienceWrite_isNotBundled() {
        let cache = DiskAccountRegistryCache()
        let hash = "acctcache-conv-\(UUID().uuidString)"
        defer { cache.clearFileCaches() }

        cache.writeCatalogData(Data("x".utf8), hash: hash)

        XCTAssertFalse(cache.isCatalogStale(hash: hash),
                       "the isBundled-defaulting convenience must write a non-bundled (fresh, not-stale) entry")
    }
}

// MARK: - Test double

/// Records the routing calls the hub makes; returns inert reads. `@unchecked
/// Sendable`: only holds trivially-guarded flags/counters, mutated on the main
/// actor by these serial tests.
fileprivate final class RecordingRegistryCache: AccountRegistryCaching, @unchecked Sendable {
    private(set) var clearFileCachesCalled = false
    private(set) var writes: [(hash: String, isBundled: Bool)] = []

    func writeCatalogData(_ data: Data, hash: String, isBundled: Bool) {
        writes.append((hash, isBundled))
    }
    func readCatalogData(hash: String) -> Data? { nil }
    func hasFreshCatalogData(hash: String) -> Bool { false }
    func isCatalogStale(hash: String) -> Bool { true }
    func slimSnapshotURL(hash: String) -> URL? { nil }
    func clearFileCaches() { clearFileCachesCalled = true }
}

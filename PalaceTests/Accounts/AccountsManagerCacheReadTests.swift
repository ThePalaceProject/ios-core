//
//  AccountsManagerCacheReadTests.swift
//  PalaceTests
//
//  Behavioral tests for the launch-path disk-cache read optimizations in
//  `AccountsManager` (swarm_27c181b5, module Accounts-Startup):
//
//   C1 — `hasCachedCatalogData(hash:)` probes existence with
//        `FileManager.fileExists` instead of a full `Data(contentsOf:)`, so
//        the ~2.4MB catalog blob is read off disk exactly once per launch
//        (by the caller's `readCachedAccountsCatalogData`) rather than twice.
//        These tests drive the sole production seam onto that path,
//        `preloadAccountsFromDiskCacheSync()`, and assert the observable
//        decision surface of `hasCachedCatalogData` (exists+fresh → hydrate;
//        expired → skip; data-without-metadata → skip). An inverted or broken
//        `fileExists` gate makes the fresh-cache hydration fail, so these
//        kill the C1 mutant even though the byte-read *count* is not directly
//        observable from the test bundle (see read-count note below).
//
//   C4 — `loadAccountSetsAndAuthDoc` carries over each old account's
//        authentication document via a `[uuid: Account]` dictionary built
//        once, replacing an O(n²) `first(where:)` scan. The carry-over test
//        assigns a DISTINCT auth doc to every one of the 171 fixture accounts
//        and asserts each new account receives the exact doc of the old
//        account with the SAME uuid — a wrong dict lookup would surface as a
//        mismatched id, so this pins per-uuid correctness across the full set.
//
//  Read-count note: `readCachedAccountsCatalogData` reads via
//  `Data(contentsOf:)` on a `FileManager.default`-derived URL that is not
//  injectable, and `hasCachedCatalogData` is `private`. Counting byte reads
//  at runtime would require a production reader seam, which the contract asks
//  us NOT to add. The single-read property is therefore verified structurally
//  (the production diff replaces the existence-time `Data(contentsOf:)` with
//  `FileManager.fileExists`) and behaviorally via the fileExists-gated
//  hydration below — not via a runtime byte-read spy.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalacePreferences
import PalaceCatalog
@testable import Palace

@MainActor
final class AccountsManagerCacheReadTests: PalaceWiringTestCase {

    // MARK: - Fixtures

    /// The 171-account production registry fixture, reused as both the disk
    /// cache blob (C1) and the catalog feed (C4).
    private var feedData: Data!

    /// The catalog-cache hash a freshly-constructed `AccountsManager` will use
    /// for its `accountSet`. Computed identically to `AccountsManager.init`
    /// (`TPPConfiguration.customUrlHash() ?? prod/beta`) so a file seeded at
    /// this hash is the one `preloadAccountsFromDiskCacheSync()` reads.
    private var accountSetHash: String!

    override func setUpWithError() throws {
        try super.setUpWithError()

        let bundle = Bundle(for: type(of: self))
        guard let feedURL = bundle.url(forResource: "OPDS2CatalogsFeed", withExtension: "json") else {
            throw XCTSkip("OPDS2CatalogsFeed.json fixture missing from PalaceTests bundle")
        }
        feedData = try Data(contentsOf: feedURL)

        accountSetHash = Self.currentAccountSetHash()

        // C1 tests seed the real Application Support cache path; the base
        // class already purges every `accounts_catalog_*` file in setUp and
        // tearDown, so no test leaves a blob behind.
    }

    override func tearDownWithError() throws {
        // Restore the disk-cache preload flag defensively in case a test set
        // it and threw before its own reset.
        #if DEBUG
        AccountsManager.deferDiskCachePreloadForTesting = false
        #endif
        feedData = nil
        accountSetHash = nil
        try super.tearDownWithError()
    }

    // MARK: - C1: preload disk-cache read path

    /// exists + fresh metadata → the fileExists-gated preload reads the blob
    /// once and hydrates every seeded account. Inverting/breaking the
    /// `fileExists` gate makes this hydration fail — the C1 mutant is killed.
    func testPreload_readsRegistryCacheOnce_hydratesEverySeededAccount() throws {
        let hash: String = accountSetHash
        let expectedCount = try feedAccountCount()
        seedDiskCache(hash: hash, data: feedData, metadataAge: 60) // 1 min old → fresh, not expired

        let manager = makeManagerWithoutAutoPreload()
        manager.preloadAccountsFromDiskCacheSync()

        let loaded = manager.accounts(hash)
        XCTAssertEqual(
            loaded.count, expectedCount,
            "Fresh disk cache must hydrate all \(expectedCount) accounts through the fileExists-gated read path"
        )
    }

    /// exists but EXPIRED metadata (>24h) → `hasCachedCatalogData` returns
    /// false via `!metadata.isExpired`, so preload skips hydration entirely.
    /// Kills the `!metadata.isExpired` mutant.
    func testPreload_expiredMetadata_doesNotHydrate() throws {
        let hash: String = accountSetHash
        seedDiskCache(hash: hash, data: feedData, metadataAge: 90_000) // 25h old → expired

        let manager = makeManagerWithoutAutoPreload()
        manager.preloadAccountsFromDiskCacheSync()

        XCTAssertTrue(
            manager.accounts(hash).isEmpty,
            "Expired cache metadata must gate preload — no accounts should hydrate"
        )
    }

    /// data file present but NO metadata file → `hasCachedCatalogData`
    /// returns false on the missing-metadata branch, so preload skips.
    /// Kills the missing-metadata branch mutant.
    func testPreload_dataPresentButNoMetadata_doesNotHydrate() throws {
        let hash: String = accountSetHash
        // Seed ONLY the data blob; deliberately omit the metadata file.
        writeCacheFile(name: "accounts_catalog_\(hash).json", data: feedData)

        let manager = makeManagerWithoutAutoPreload()
        manager.preloadAccountsFromDiskCacheSync()

        XCTAssertTrue(
            manager.accounts(hash).isEmpty,
            "A cache blob without metadata must be treated as unusable — no accounts should hydrate"
        )
    }

    // MARK: - C4: per-uuid carry-over via dict lookup

    /// Drives `loadAccountSetsAndAuthDoc` twice over the same 171-account
    /// feed. Between loads, every old account gets a DISTINCT auth document
    /// keyed by its uuid. The second load must carry each old account's doc
    /// onto the new account with the SAME uuid — proving the `[uuid: Account]`
    /// dictionary lookup preserves the prior `first(where:)` behavior for
    /// every matching uuid, not just one.
    func testLoadAccountSets_carryOver_isCorrectForEveryMatchingUUID() throws {
        // Empty per-test defaults → currentAccountId is nil → the auth-doc
        // network branch inside loadAccountSetsAndAuthDoc stays dormant, so
        // the load is a pure parse + carry-over + state-transition pass.
        let manager = makeFreshAccountsManager(defaults: Self.testUserDefaults())
        let hash = "carryover-\(UUID().uuidString.prefix(8))"

        // First load establishes the old-account set in accountSets[hash].
        try driveLoad(manager, data: feedData, key: hash)
        let oldAccounts = manager.accounts(hash)
        XCTAssertGreaterThan(
            oldAccounts.count, 100,
            "Fixture must yield the full large registry so the dict lookup is exercised at scale"
        )

        // Assign a distinct auth doc to each old account, keyed by uuid.
        var expectedDocIdByUUID = [String: String]()
        for (index, account) in oldAccounts.enumerated() {
            let docId = "urn:uuid:carry-\(account.uuid)-\(index)"
            account.authenticationDocument = makeAuthDoc(id: docId)
            expectedDocIdByUUID[account.uuid] = docId
        }

        // Second load over the same uuids triggers the carry-over dict lookup.
        try driveLoad(manager, data: feedData, key: hash)
        let newAccounts = manager.accounts(hash)
        XCTAssertEqual(newAccounts.count, oldAccounts.count, "Reload must not change the account count")

        var verified = 0
        for newAccount in newAccounts {
            guard let expectedDocId = expectedDocIdByUUID[newAccount.uuid] else {
                XCTFail("New account uuid \(newAccount.uuid) has no matching old account — feed changed unexpectedly")
                continue
            }
            XCTAssertEqual(
                newAccount.authenticationDocument?.id, expectedDocId,
                "Carry-over must map uuid \(newAccount.uuid) to ITS OWN old auth doc, not another account's"
            )
            verified += 1
        }
        XCTAssertEqual(verified, newAccounts.count, "Every reloaded account must be a matched carry-over")
        XCTAssertGreaterThan(verified, 100, "Per-uuid carry-over must be proven across the full large set")
    }

    // MARK: - Helpers

    /// Mirror of `AccountsManager.init`'s `accountSet` derivation so tests can
    /// locate the exact disk-cache file a fresh manager will read.
    private static func currentAccountSetHash() -> String {
        if let custom = TPPConfiguration.customUrlHash() {
            return custom
        }
        return TPPSettings().useBetaLibraries
            ? TPPConfiguration.betaUrlHash
            : TPPConfiguration.prodUrlHash
    }

    private func feedAccountCount() throws -> Int {
        let feed = try OPDS2CatalogsFeed.fromData(feedData)
        return feed.catalogs.count
    }

    /// Construct a manager with the init-time disk-cache preload deferred, so
    /// the test drives `preloadAccountsFromDiskCacheSync()` explicitly against
    /// a cache it seeded. The flag is reset in `tearDownWithError`.
    private func makeManagerWithoutAutoPreload() -> AccountsManager {
        #if DEBUG
        AccountsManager.deferDiskCachePreloadForTesting = true
        #endif
        return makeFreshAccountsManager(defaults: Self.testUserDefaults())
    }

    /// Seed both the catalog blob and its metadata at the production cache
    /// path for `hash`. `metadataAge` is seconds-in-the-past for the metadata
    /// timestamp (controls fresh vs. expired).
    private func seedDiskCache(hash: String, data: Data, metadataAge: TimeInterval) {
        writeCacheFile(name: "accounts_catalog_\(hash).json", data: data)
        let metadata = CatalogCacheMetadata(
            timestamp: Date().addingTimeInterval(-metadataAge),
            hash: hash
        )
        if let metadataData = try? JSONEncoder().encode(metadata) {
            writeCacheFile(name: "accounts_catalog_metadata_\(hash).json", data: metadataData)
        }
    }

    /// Write a file into the same Application Support directory the production
    /// `accountsCatalogUrl` / `cacheMetadataUrl` helpers use.
    private func writeCacheFile(name: String, data: Data) {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            XCTFail("Could not resolve Application Support directory for cache seeding")
            return
        }
        do {
            try data.write(to: appSupport.appendingPathComponent(name))
        } catch {
            XCTFail("Failed to seed cache file \(name): \(error)")
        }
    }

    /// Drive `loadAccountSetsAndAuthDoc` to completion (its completion fires on
    /// the main queue via `group.notify`).
    private func driveLoad(_ manager: AccountsManager, data: Data, key: String) throws {
        let done = expectation(description: "loadAccountSetsAndAuthDoc completes")
        manager.loadAccountSetsAndAuthDoc(fromCatalogData: data, key: key) { _ in
            done.fulfill()
        }
        wait(for: [done], timeout: 15) // FLAKE-003-OK: drives the real loadAccountSetsAndAuthDoc decode of a local fixture (fromCatalogData, no network); 15s is CI-load headroom, not a real-I/O leak.
    }

    /// Build a valid, decodable `OPDS2AuthenticationDocument` with a caller-
    /// controlled `id` so carry-over can be checked per uuid.
    private func makeAuthDoc(id: String) -> OPDS2AuthenticationDocument {
        let json: [String: Any] = [
            "id": id,
            "title": "Carry-over Test Library",
            "authentication": [[
                "type": "http://opds-spec.org/auth/basic",
                "inputs": [
                    "login": ["keyboard": "Default"],
                    "password": ["keyboard": "Default"]
                ],
                "labels": ["login": "Barcode", "password": "PIN"]
            ]],
            "features": ["enabled": [], "disabled": []]
        ]
        // JSONSerialization of a static, well-formed dictionary; decode is the
        // production path (`fromData`). Failure here is a test-authoring bug,
        // surfaced immediately rather than silently swallowed.
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let doc = try? OPDS2AuthenticationDocument.fromData(data) else {
            fatalError("makeAuthDoc fixture is malformed — static JSON must always decode")
        }
        return doc
    }
}

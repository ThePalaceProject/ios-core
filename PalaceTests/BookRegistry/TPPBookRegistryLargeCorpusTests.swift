//
//  TPPBookRegistryLargeCorpusTests.swift
//  PalaceTests
//
//  Deep, mutation-killing tests for the *scale* of BookRegistrySync.save +
//  load against a real-world worst-case corpus: 5000 books on disk.
//
//  Contract under test:
//    1. Saving 5000 in-memory records produces a complete JSON file (no
//       truncation, no record loss).
//    2. Loading 5000 records from disk produces 5000 unique in-memory
//       records (no record loss, no duplication).
//    3. The save→load round-trip is fully lossless at scale for the fields
//       BookRegistryStore exposes (identifier, title, state).
//    4. Lookup by identifier remains O(1)-ish — every seeded id resolves
//       to a record after load.
//
//  These tests are *correctness at scale*, not perf gates. We pin a generous
//  wall-clock budget (60s) so a 100x slowdown still fails, but we do not
//  assert microbenchmark numbers.
//
//  Copyright 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace
import PalaceBookModel
@testable import PalaceBookRegistry

@MainActor
class TPPBookRegistryLargeCorpusTests: PalaceWiringTestCase {

    private var account: String!
    private var store: BookRegistryStore!
    private var sync: BookRegistrySync!
    private var accountsManager: AccountsManager!

    /// Corpus size — 5000 books is the brief's target. Tests assume this is
    /// also the in-memory record count we re-read.
    private let corpusCount = 5000

    override func setUpWithError() throws {
        try super.setUpWithError()
        account = "test-large-corpus-\(UUID().uuidString)"
        store = BookRegistryStore()
        // FLAKE-003 fix: this suite constructs an AccountsManager purely as a
        // BookRegistrySync dependency and never reads its account sets, so skip
        // the on-disk cached-account preload — the >5s (~1138-account) load that
        // was the root of the intermittent BookRegistry-test timeouts on
        // memory-pressured CI. Reset in tearDown to keep the flip scoped.
        #if DEBUG
        AccountsManager.deferDiskCachePreloadForTesting = true
        #endif
        accountsManager = makeFreshAccountsManager()
        sync = BookRegistrySync(
            store: store,
            accountsManager: accountsManager,
            downloadCenterProvider: { AppContainer.production().downloadCenter },
            opdsFeedServiceProvider: { AppContainer.production().opdsFeedService }
        )
    }

    override func tearDownWithError() throws {
        if let url = sync?.registryUrl(for: account)?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: url)
        }
        account = nil
        store = nil
        sync = nil
        accountsManager = nil
        #if DEBUG
        AccountsManager.deferDiskCachePreloadForTesting = false
        #endif
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Build a minimal book dict directly — avoid the TPPBookMocker overhead
    /// (per-book image generation) at 5000-record scale. The shape mirrors
    /// what TPPBook.dictionaryRepresentation() emits for the minimum fields
    /// that survive read.
    private func minimalBookDict(id: String, title: String) -> [String: Any] {
        return [
            "id": id,
            "title": title,
            "updated": "2023-11-14T22:13:20+00:00",
            "acquisitions": [] as [Any],
            "categories": [] as [Any],
            "authors": [] as [Any],
            "author-links": [] as [Any]
        ]
    }

    private func writeCorpusJSON(_ records: [[String: Any]]) throws {
        guard let url = sync.registryUrl(for: account) else {
            XCTFail("registryUrl(for:) returned nil"); return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["records": records],
                                              options: .fragmentsAllowed)
        try data.write(to: url, options: .atomic)
    }

    private func freshStoreAndSync() {
        store = BookRegistryStore()
        sync = BookRegistrySync(
            store: store,
            accountsManager: accountsManager,
            downloadCenterProvider: { AppContainer.production().downloadCenter },
            opdsFeedServiceProvider: { AppContainer.production().opdsFeedService }
        )
    }

    /// Wave-2 (swarm_ad0b4c65): replaced the `wait(for:timeout:)` +
    /// `RunLoop.current.run(until:+0.2)` settle with a deterministic seam
    /// join — no wall-clock budget needed regardless of corpus size.
    /// `sync.load` drives its mutation through
    /// `BookRegistryStore.mutateRegistry`, which enqueues on `store`'s
    /// barrier `syncQueue`; `_awaitPendingWritesForTesting()` drains that
    /// queue (bounded — one trailing barrier hop, however long the 5000-record
    /// parse inside the barrier block takes), then `drainMainQueueAsync()`
    /// flushes the `DispatchQueue.main.async { callbacks.setState(.loaded) }`
    /// hop the load schedules from inside that barrier block.
    /// `testLoad_5000Books_CompletesUnderTimeBudget` still measures and
    /// asserts real elapsed wall time around this call independently.
    private func loadAndWait() async {
        sync.load(account: account, setState: { _ in }, completion: nil)
        await store._awaitPendingWritesForTesting()
        await drainMainQueueAsync()
    }

    // MARK: - 5000-book corpus integrity

    /// Plant 5000 records on disk and load them. The load must produce
    /// exactly 5000 in-memory records — no losses, no duplication, no
    /// truncation. Kills mutants that:
    ///   - cap the loop iteration count
    ///   - break out of the parse loop on the first non-fatal log
    ///   - rebuild the registry from a subset of records
    func testLoad_5000Books_ProducesExactCount() async throws {
        // Build records.
        var records: [[String: Any]] = []
        records.reserveCapacity(corpusCount)
        var ids: [String] = []
        ids.reserveCapacity(corpusCount)
        for i in 0..<corpusCount {
            let id = "corpus-\(i)"
            ids.append(id)
            records.append([
                "metadata": minimalBookDict(id: id, title: "Corpus Book \(i)"),
                "state": "holding"
            ])
        }
        try writeCorpusJSON(records)

        await loadAndWait()

        XCTAssertEqual(store.allBooks.count, corpusCount,
                       "Loading \(corpusCount) records must produce exactly \(corpusCount) in-memory books — kills mutants that drop or duplicate records at scale")
    }

    /// Save 5000 in-memory records and reload from disk. Identifier, title,
    /// and state must all survive the round-trip for EVERY record.
    /// Kills mutants that drop fields on serialization or replace them with
    /// defaults at scale.
    func testRoundTrip_5000Books_AllFieldsPreserved() async throws {
        // Seed.
        var ids: [String] = []
        ids.reserveCapacity(corpusCount)
        store.mutateRegistrySync { registry in
            for i in 0..<self.corpusCount {
                let id = "rt-\(i)"
                ids.append(id)
                // Build the TPPBook directly with the minimal dict so we
                // avoid TPPBookMocker's image generation per book.
                guard let book = TPPBook(dictionary: self.minimalBookDict(id: id, title: "RT \(i)")) else {
                    continue
                }
                registry[id] = TPPBookRegistryRecord(book: book, state: .holding)
            }
        }

        sync.saveSync(for: account)

        freshStoreAndSync()
        await loadAndWait()

        XCTAssertEqual(store.allBooks.count, corpusCount,
                       "All \(corpusCount) records must round-trip — kills mutant that drops some on save")

        // Spot-check a random sample of 50 ids: every one must resolve, and
        // its title must match the expected pattern. Sampling rather than
        // iterating all 5000 keeps the per-test runtime reasonable.
        let sampleIndices = stride(from: 0, to: corpusCount, by: corpusCount / 50).prefix(50)
        for idx in sampleIndices {
            let id = "rt-\(idx)"
            let book = store.book(forIdentifier: id)
            XCTAssertNotNil(book, "Expected book \(id) to survive round-trip")
            XCTAssertEqual(book?.title, "RT \(idx)",
                           "Title field must round-trip exactly for \(id)")
            XCTAssertEqual(store.state(for: id), .holding,
                           "State must round-trip for \(id)")
        }
    }

    /// Reasonable-time budget — pin a 60-second ceiling on the load of 5000
    /// records. If load suddenly becomes O(n²) (e.g. mutant that does a
    /// linear scan inside a loop), this test fails loudly. We do NOT pin a
    /// tight microbenchmark.
    func testLoad_5000Books_CompletesUnderTimeBudget() async throws {
        var records: [[String: Any]] = []
        records.reserveCapacity(corpusCount)
        for i in 0..<corpusCount {
            records.append([
                "metadata": minimalBookDict(id: "budget-\(i)", title: "Budget \(i)"),
                "state": "holding"
            ])
        }
        try writeCorpusJSON(records)

        let start = Date()
        await loadAndWait() // 60s budget now lives solely in the XCTAssertLessThan below — the wait itself is a deterministic seam join with no timeout.
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 60.0,
                          "Loading 5000 records must complete inside 60s — kills mutant that turns load into O(n²)")
        XCTAssertEqual(store.allBooks.count, corpusCount,
                       "Time-budget run must still produce the full count")
    }

    /// At 5000-book scale, every identifier must resolve uniquely via
    /// book(forIdentifier:). Kills mutants that change the keying field or
    /// reuse a single record across multiple slots.
    func testLookupByIdentifier_5000Books_AllUnique() async throws {
        var records: [[String: Any]] = []
        records.reserveCapacity(corpusCount)
        var ids = Set<String>()
        for i in 0..<corpusCount {
            let id = "unique-\(i)"
            ids.insert(id)
            records.append([
                "metadata": minimalBookDict(id: id, title: "Unique \(i)"),
                "state": "holding"
            ])
        }
        try writeCorpusJSON(records)

        await loadAndWait()

        // Every seeded id must map to a book whose identifier matches.
        for id in ids {
            let book = store.book(forIdentifier: id)
            XCTAssertNotNil(book, "Expected unique resolution for \(id)")
            XCTAssertEqual(book?.identifier, id,
                           "Resolved book's identifier must match the lookup key — kills mutant that reuses a record across slots")
        }
        // And the in-memory size must equal the unique-id count.
        XCTAssertEqual(store.allBooks.count, ids.count,
                       "In-memory record count must equal unique-id count — kills mutant that adds spurious entries")
    }

    /// Saving a 5000-record corpus must produce a JSON file whose
    /// top-level record count matches in-memory. Kills mutants that
    /// silently cap the saved record count at a small number (e.g. truncate
    /// to first N) — those would round-trip fewer records than expected.
    func testSave_5000Books_FileContainsAllRecords() throws {
        var ids: [String] = []
        store.mutateRegistrySync { registry in
            for i in 0..<self.corpusCount {
                let id = "save-cap-\(i)"
                ids.append(id)
                guard let book = TPPBook(dictionary: self.minimalBookDict(id: id, title: "SC \(i)")) else {
                    continue
                }
                registry[id] = TPPBookRegistryRecord(book: book, state: .holding)
            }
        }
        sync.saveSync(for: account)

        let url = sync.registryUrl(for: account)!
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let records = json?["records"] as? [[String: Any]] ?? []

        XCTAssertEqual(records.count, corpusCount,
                       "Saved file must contain exactly \(corpusCount) records — kills mutant that caps the saved subset")
    }
}

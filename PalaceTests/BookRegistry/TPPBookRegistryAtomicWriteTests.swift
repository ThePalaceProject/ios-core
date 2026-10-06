//  TPPBookRegistryAtomicWriteTests.swift
//
//  Successful-save behavior of BookRegistrySync.save / saveSync: complete JSON,
//  the second save replaces the first, no staging files left behind, and no
//  torn file seen by a concurrent reader. None of these interrupt a write, so
//  they do not show that a failed or interrupted save leaves the prior file
//  readable; RegistryWriteFailureTests injects those failures.

import XCTest
@testable import Palace
import PalaceBookModel
@testable import PalaceBookRegistry

@MainActor
class TPPBookRegistryAtomicWriteTests: PalaceWiringTestCase {

    private var account: String!
    private var store: BookRegistryStore!
    private var sync: BookRegistrySync!
    private var accountsManager: AccountsManager!

    override func setUpWithError() throws {
        try super.setUpWithError()
        account = "test-atomic-\(UUID().uuidString)"
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

    private func seedAndSave(count: Int) -> [String] {
        var ids: [String] = []
        store.mutateRegistrySync { registry in
            for i in 0..<count {
                let id = "atomic-seed-\(i)-\(UUID().uuidString)"
                ids.append(id)
                let book = TPPBookMocker.mockBook(identifier: id,
                                                  title: "Atomic Seed \(i)",
                                                  distributorType: .EpubZip)
                registry[id] = TPPBookRegistryRecord(book: book, state: .holding)
            }
        }
        sync.saveSync(for: account)
        return ids
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

    /// Waits for the load with a deterministic seam join instead of a
    /// wall-clock timeout. `sync.load` drives its mutation through
    /// `BookRegistryStore.mutateRegistry`, which enqueues on `store`'s
    /// barrier `syncQueue`; `_awaitPendingWritesForTesting()` drains that
    /// queue (bounded — one trailing barrier hop), which also guarantees the
    /// `DispatchQueue.main.async { callbacks.setState(.loaded) ... }` hop
    /// inside the load completion has been SCHEDULED. `drainMainQueueAsync()`
    /// then flushes that scheduled main-queue hop deterministically — no
    /// wall-clock budget, no AccountsManager-preload timing dependency.
    private func loadAndWait() async {
        sync.load(account: account, setState: { _ in }, completion: nil)
        await store._awaitPendingWritesForTesting()
        await drainMainQueueAsync()
    }

    // MARK: - Successful save

    /// saveSync must produce a complete, parseable JSON file at the canonical
    /// path. This is serialization only: a non-atomic write also passes.
    func testSaveSync_ProducesCompleteParseableJSON() throws {
        _ = seedAndSave(count: 20)

        let url = sync.registryUrl(for: account)!
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data)

        XCTAssertNotNil(json as? [String: Any],
                        "saveSync must produce valid JSON")
        let records = (json as? [String: Any])?["records"] as? [[String: Any]]
        XCTAssertEqual(records?.count, 20,
                       "All 20 seeded records must appear in the saved file — kills mutant that truncates output")
    }

    /// After a successful save, the registry directory must contain the
    /// canonical `registry.json` and (since the #1212/D1 resilience work) the
    /// durable last-good `registry.json.bak` sidecar — and NOTHING ELSE. The
    /// atomic-rename (primary) and write-new→fsync→rename (backup) must leave
    /// no `.tmp` / staging artifacts behind. Catches regressions that switch from
    /// atomic-rename to a manual temp-file + rename leaving staging.
    ///
    /// Updated for the `.bak` sidecar: a non-empty saveSync now legitimately
    /// writes the last-good backup (RegistryFileRecovery.writeBackup) as the
    /// recovery source a later corrupt load reads. The `.bak` is a PERMANENT
    /// durable artifact, not staging — so the anti-staging intent is preserved
    /// by asserting the exact {registry.json, registry.json.bak} set and, in
    /// particular, the ABSENCE of any `.tmp` file (the staging artifact the
    /// regression would leave).
    func testSaveSync_LeavesNoStagingArtifactsInRegistryDir() throws {
        _ = seedAndSave(count: 5)

        let dir = sync.registryUrl(for: account)!.deletingLastPathComponent()
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            // Filter macOS metadata
            .filter { !$0.hasPrefix(".") }
            .sorted()

        // #1212 ("Bulletproof Ownership") writes a durable last-good
        // `registry.json.bak` sidecar on every non-empty save
        // (RegistryFileRecovery.writeBackup, BookRegistrySync.saveSync) — an
        // INTENTIONAL backup, not a staging artifact. The regression this test
        // catches is a leaked `.tmp` staging file from the atomic rename, so assert the dir
        // holds exactly registry.json + its backup and NOTHING else: a stray
        // `.tmp` (or any other file) makes this set comparison fail.
        XCTAssertEqual(contents, ["registry.json", "registry.json.bak"],
                       "Registry dir must contain only registry.json + its durable .bak backup — no leaked staging .tmp files")
    }

    /// Two back-to-back saves (write a registry, then a smaller one) must
    /// converge to the *second* file's contents: the second write replaces the
    /// first rather than appending to it.
    func testSaveSync_OverlappingSaves_FinalContentsOnly() async throws {
        // First save: 10 records.
        let firstIds = seedAndSave(count: 10)

        // Replace in-memory registry with a single new record.
        store.mutateRegistrySync { registry in registry.removeAll() }
        let onlyId = "atomic-final-\(UUID().uuidString)"
        let book = TPPBookMocker.mockBook(identifier: onlyId,
                                          title: "Atomic Final",
                                          distributorType: .EpubZip)
        store.mutateRegistrySync { registry in
            registry[onlyId] = TPPBookRegistryRecord(book: book, state: .holding)
        }
        sync.saveSync(for: account)

        // Cold reload from disk and confirm the file holds ONLY the second save.
        freshStoreAndSync()
        await loadAndWait()

        XCTAssertEqual(store.allBooks.count, 1,
                       "Second save must fully replace the first")
        XCTAssertNotNil(store.book(forIdentifier: onlyId),
                        "Only the second-save record must survive")
        for id in firstIds {
            XCTAssertNil(store.book(forIdentifier: id),
                         "First-save records must be gone after the second save — id \(id) leaked")
        }
    }

    // MARK: - Missing directory

    /// A save after the registry directory was deleted (with its backup) must
    /// recreate the directory and write the new shelf. Nothing interrupts the
    /// write here; the directory is gone before the save starts.
    func testSaveSync_AfterRegistryDirectoryDeleted_RecreatesItAndWritesTheNewShelf() async throws {
        let initialIds = seedAndSave(count: 3)
        let url = sync.registryUrl(for: account)!
        let dir = url.deletingLastPathComponent()
        try FileManager.default.removeItem(at: dir)

        store.mutateRegistrySync { registry in registry.removeAll() }
        let postId = "atomic-post-delete-\(UUID().uuidString)"
        let book = TPPBookMocker.mockBook(identifier: postId,
                                          title: "Post-Delete Save",
                                          distributorType: .EpubZip)
        store.mutateRegistrySync { registry in
            registry[postId] = TPPBookRegistryRecord(book: book, state: .holding)
        }
        sync.saveSync(for: account)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "saveSync must recreate the deleted registry directory and write the file")
        freshStoreAndSync()
        await loadAndWait()
        XCTAssertEqual(store.allBooks.map(\.identifier), [postId],
                       "the reloaded registry must hold exactly the shelf saved after the deletion")
        for id in initialIds {
            XCTAssertNil(store.book(forIdentifier: id), "deleted records must not come back — id \(id)")
        }
    }

    /// Concurrent saves into the same account file from multiple queues must
    /// converge, and a reader polling the file mid-burst must never see torn
    /// JSON. Whether a reader lands inside a write is timing-dependent, so a
    /// pass is evidence of the serial `diskWriteQueue` plus atomic replace, not
    /// proof of it.
    func testConcurrentSaves_EveryDiskStateBetweenSaves_IsValidJSON() async throws {
        _ = seedAndSave(count: 5)

        let qA = DispatchQueue(label: "atomic.qA")
        let qB = DispatchQueue(label: "atomic.qB")
        let url = sync.registryUrl(for: account)!

        // Reader thread: re-reads the file mid-burst. Every read must succeed
        // (file exists & parses) or be ENOENT (transient — possible only if
        // a future regression breaks atomic rename and exposes a delete window).
        // Atomic rename guarantees readers never see an empty/torn file.
        //
        // The previous implementation slept 2ms between reads as a
        // "give the scheduler a chance" hint. That was a fixed-time delay,
        // not synchronization — disk I/O latency already creates a natural
        // interleaving window with writer bursts. Removing the fixed delay
        // tightens the contention loop, making the test STRICTER on
        // atomicity rather than weaker. The 60-read budget is bounded by
        // I/O latency, not a sleep.
        var corruptReads = 0
        let readDone = expectation(description: "reader finished")
        DispatchQueue.global().async {
            for _ in 0..<60 {
                if let data = try? Data(contentsOf: url) {
                    if (try? JSONSerialization.jsonObject(with: data)) == nil {
                        corruptReads += 1
                    }
                }
            }
            readDone.fulfill()
        }

        // Writer bursts: 30 concurrent saves.
        let group = DispatchGroup()
        for _ in 0..<15 {
            group.enter()
            qA.async { [sync, account] in sync?.save(for: account!); group.leave() }
            group.enter()
            qB.async { [sync, account] in sync?.save(for: account!); group.leave() }
        }
        let writeDone = expectation(description: "writers finished")
        group.notify(queue: .main) { writeDone.fulfill() }

        // Waits on BookRegistrySync's private
        // `diskWriteQueue` draining via `save(for:)` fire-and-forget calls — no
        // catalog seam exists for that queue (only BookRegistryStore's syncQueue
        // has `_awaitPendingWritesForTesting()`). Genuinely bounded by a real
        // DispatchGroup.notify + background-thread completion, not a settle
        // delay — left as-is per playbook bucket 4. In an async test method the
        // bounded wait must use the `await fulfillment` form (SDK requirement);
        // it still blocks on the real DispatchGroup.notify + reader completion,
        // NOT a clock, so it is not an unbounded await.
        await fulfillment(of: [writeDone, readDone], timeout: 10.0)

        // Final tail-save: a blocking save bracketing all queued ones, after
        // which the file MUST be valid.
        sync.saveSync(for: account)

        XCTAssertEqual(corruptReads, 0,
                       "Every concurrent read of the registry file mid-burst must parse")

        // Final state must reload cleanly.
        freshStoreAndSync()
        await loadAndWait()
        XCTAssertEqual(store.allBooks.count, 5,
                       "After concurrent save bursts, all 5 seeded records must reload — kills mutant that drops records under contention")
    }

    /// After a completed save the file is non-empty and holds every record.
    /// Serialization only; it does not observe the file during the write.
    func testSaveSync_FileSizeNonZero_AndJSONComplete() throws {
        _ = seedAndSave(count: 50)
        let url = sync.registryUrl(for: account)!
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(size, 0,
                             "Registry file must be non-empty after save — kills mutant that truncates output to 0 bytes")

        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let records = json?["records"] as? [[String: Any]] ?? []
        XCTAssertEqual(records.count, 50,
                       "Saved file's record count must match in-memory — kills mutant that drops records on serialization")
    }

    /// save() (queued, non-blocking) must eventually produce the same file
    /// shape as saveSync(). Brackets the async save with a follow-up
    /// saveSync (which drains the serial diskWriteQueue) to ensure
    /// completion.
    func testAsyncSave_EventuallyProducesValidFile() throws {
        let id = "async-save-\(UUID().uuidString)"
        let book = TPPBookMocker.mockBook(identifier: id,
                                          title: "Async Save",
                                          distributorType: .EpubZip)
        store.mutateRegistrySync { registry in
            registry[id] = TPPBookRegistryRecord(book: book, state: .holding)
        }
        // Async save followed by sync save — when the sync returns, the
        // async one has fully drained.
        sync.save(for: account)
        sync.saveSync(for: account)

        let url = sync.registryUrl(for: account)!
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "Async save must persist — file must exist after the followup saveSync drains the queue")
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json?["records"] as? [[String: Any]],
                        "Async-save output must have the expected JSON shape")
    }
}

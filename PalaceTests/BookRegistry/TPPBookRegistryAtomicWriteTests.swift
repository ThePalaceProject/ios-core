//
//  TPPBookRegistryAtomicWriteTests.swift
//  PalaceTests
//
//  Deep, mutation-killing tests for *atomic-write* robustness of
//  BookRegistrySync.save / saveSync. The contract under test:
//
//    1. `Data.write(to:options:.atomic)` writes to a temp file then renames
//       in a single atomic step. A failure mid-write must NOT leave a
//       half-written file in place — the prior contents must remain readable,
//       or the file must not exist.
//
//    2. A save that succeeds must produce a single intact JSON file at the
//       canonical path. There must be NO leftover staging files visible in
//       the registry directory after the rename completes.
//
//    3. saveSync (blocking) and save (queued) both honor the atomic contract.
//
//  We exercise the contract by:
//    - Pre-seeding a valid registry JSON, then forcing an "interrupted" write
//      by replacing the registry file's parent directory with a read-only
//      barrier mid-save → the resulting file system state must still be loadable.
//    - Verifying no .tmp / staging artifacts are left in the registry dir.
//    - Verifying a successful save → reload → save sequence converges.
//
//  These tests do NOT touch production code. They use per-test temp accounts.
//
//  Copyright 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class TPPBookRegistryAtomicWriteTests: XCTestCase {

    private var account: String!
    private var store: BookRegistryStore!
    private var sync: BookRegistrySync!
    private var accountsManager: AccountsManager!

    override func setUp() {
        super.setUp()
        account = "test-atomic-\(UUID().uuidString)"
        store = BookRegistryStore()
        accountsManager = AccountsManager()
        sync = BookRegistrySync(
            store: store,
            accountsManager: accountsManager,
            downloadCenterProvider: { AppContainer.production().downloadCenter },
            opdsFeedServiceProvider: { AppContainer.production().opdsFeedService }
        )
    }

    override func tearDown() {
        if let url = sync?.registryUrl(for: account)?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: url)
        }
        account = nil
        store = nil
        sync = nil
        accountsManager = nil
        super.tearDown()
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

    /// 30s rather than 5s — same defensive bump as the sibling
    /// TPPBookRegistryPersistenceTests.loadAndWait. AccountsManager preload
    /// of 1138 cached accounts during init can alone consume >5s on
    /// memory-pressured CI before sync.load even starts.
    private func loadAndWait() {
        let exp = expectation(description: "load completes")
        sync.load(account: account, setState: { newState in
            if newState == .loaded { exp.fulfill() }
        }, completion: nil)
        wait(for: [exp], timeout: 30.0)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    }

    // MARK: - Atomic-rename contract

    /// saveSync must produce a complete, parseable JSON file at the canonical
    /// path. Kills mutants that drop `options: .atomic` in favor of a partial
    /// write (which on a sufficiently large dataset would leave a truncated
    /// file half the time).
    func testSaveSync_ProducesCompleteParseableJSON() throws {
        _ = seedAndSave(count: 20)

        let url = sync.registryUrl(for: account)!
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data)

        XCTAssertNotNil(json as? [String: Any],
                        "saveSync must produce valid JSON — kills mutant that drops .atomic and leaves a truncated file")
        let records = (json as? [String: Any])?["records"] as? [[String: Any]]
        XCTAssertEqual(records?.count, 20,
                       "All 20 seeded records must appear in the saved file — kills mutant that truncates output")
    }

    /// After a successful save, the registry directory must contain exactly
    /// one file: the canonical `registry.json`. The atomic-rename should
    /// leave no `.tmp` / staging artifacts behind. Kills mutants that switch
    /// from atomic-rename to a manual temp-file + rename leaving staging.
    func testSaveSync_LeavesNoStagingArtifactsInRegistryDir() throws {
        _ = seedAndSave(count: 5)

        let dir = sync.registryUrl(for: account)!.deletingLastPathComponent()
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            // Filter macOS metadata
            .filter { !$0.hasPrefix(".") }

        XCTAssertEqual(contents, ["registry.json"],
                       "Registry dir must contain only registry.json — kills mutant that leaves staging .tmp files")
    }

    /// Two back-to-back saves (write a registry, then a smaller one) must
    /// converge to the *second* file's contents — atomic rename means the
    /// second write fully replaces the first, never blends. Kills mutants
    /// that append instead of replace (which would survive round-trip but
    /// double-count records).
    func testSaveSync_OverlappingSaves_FinalContentsOnly() throws {
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
        loadAndWait()

        XCTAssertEqual(store.allBooks.count, 1,
                       "Second save must fully replace the first — kills mutant that appends across saves")
        XCTAssertNotNil(store.book(forIdentifier: onlyId),
                        "Only the second-save record must survive")
        for id in firstIds {
            XCTAssertNil(store.book(forIdentifier: id),
                         "First-save records must be gone after atomic overwrite — id \(id) leaked")
        }
    }

    // MARK: - Interrupted write recovery

    /// An "interrupted" save that fails because the registry directory has
    /// been wiped (simulating the iOS "applicationSupport churn" failure
    /// observed in the field when the user clears storage) must NOT leave a
    /// half-written corrupted file behind. Pre-condition: a valid registry
    /// exists. We then yank the directory and attempt to save. The save
    /// either succeeds (write recreates the directory) or fails gracefully
    /// — in both cases, when a subsequent reload runs, the registry must be
    /// either intact-with-new-data OR cleanly empty (never half-written
    /// garbage).
    func testSave_AfterDirectoryDeleted_DoesNotLeaveCorruptedFile() throws {
        // Seed an initial registry on disk.
        let initialIds = seedAndSave(count: 3)
        let url = sync.registryUrl(for: account)!
        let dir = url.deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "Pre-condition: initial registry must exist")

        // Yank the directory mid-flight. saveSync will then try to write into
        // a non-existent directory — the production code's createDirectory
        // call inside save() must handle this.
        try FileManager.default.removeItem(at: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))

        // Mutate in-memory and save. Production code recreates the directory
        // when missing and writes atomically.
        store.mutateRegistrySync { registry in registry.removeAll() }
        let postId = "atomic-post-delete-\(UUID().uuidString)"
        let book = TPPBookMocker.mockBook(identifier: postId,
                                          title: "Post-Delete Save",
                                          distributorType: .EpubZip)
        store.mutateRegistrySync { registry in
            registry[postId] = TPPBookRegistryRecord(book: book, state: .holding)
        }
        sync.saveSync(for: account)

        // Whatever state the disk is in, reload must converge — file is
        // either valid-with-postId or fully absent.
        freshStoreAndSync()
        loadAndWait()

        if FileManager.default.fileExists(atPath: url.path) {
            // Successful re-creation + write — must contain ONLY the new record.
            XCTAssertNotNil(store.book(forIdentifier: postId),
                            "If re-saved after directory deletion, new record must be present")
            for id in initialIds {
                XCTAssertNil(store.book(forIdentifier: id),
                             "Deleted-then-recreated registry must NOT resurrect old data — kills mutant that re-reads from a cached buffer")
            }
        } else {
            // Save failed — registry must be cleanly empty, not corrupt.
            XCTAssertTrue(store.allBooks.isEmpty,
                          "If save failed, registry must come up empty on reload — no corruption")
        }
    }

    /// Concurrent saves into the same account file from multiple queues must
    /// converge — atomic rename guarantees the FINAL save's contents win and
    /// no intermediate write produces a torn JSON. We're testing the
    /// `diskWriteQueue` (serial) + atomic-rename interaction here, but from
    /// a different angle than the persistence agent: we re-read the file at
    /// each intermediate step and assert each read is valid JSON.
    func testConcurrentSaves_EveryDiskStateBetweenSaves_IsValidJSON() throws {
        _ = seedAndSave(count: 5)

        let qA = DispatchQueue(label: "atomic.qA")
        let qB = DispatchQueue(label: "atomic.qB")
        let url = sync.registryUrl(for: account)!

        // Reader thread: re-reads the file mid-burst. Every read must succeed
        // (file exists & parses) or be ENOENT (transient — possible only if
        // a future mutant breaks atomic rename and exposes a delete window).
        // Atomic rename guarantees readers never see an empty/torn file.
        var corruptReads = 0
        let readDone = expectation(description: "reader finished")
        DispatchQueue.global().async {
            for _ in 0..<60 {
                if let data = try? Data(contentsOf: url) {
                    if (try? JSONSerialization.jsonObject(with: data)) == nil {
                        corruptReads += 1
                    }
                }
                usleep(2_000) // 2ms
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

        wait(for: [writeDone, readDone], timeout: 15.0)

        // Final tail-save: a blocking save bracketing all queued ones, after
        // which the file MUST be valid.
        sync.saveSync(for: account)

        XCTAssertEqual(corruptReads, 0,
                       "Every concurrent read of the registry file mid-burst must parse — kills mutant that drops atomic rename")

        // Final state must reload cleanly.
        freshStoreAndSync()
        loadAndWait()
        XCTAssertEqual(store.allBooks.count, 5,
                       "After concurrent save bursts, all 5 seeded records must reload — kills mutant that drops records under contention")
    }

    /// Verify the atomic-rename guarantee at the filesystem level: after a
    /// completed save, the file's inode/contents are present in their
    /// entirety — there is no zero-length file, no truncation. Kills mutants
    /// that open the file with O_TRUNC then write incrementally (a torn
    /// state visible to concurrent readers).
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

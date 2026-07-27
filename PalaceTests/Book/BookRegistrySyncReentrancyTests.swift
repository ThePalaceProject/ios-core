//
//  BookRegistrySyncReentrancyTests.swift
//  PalaceTests
//
//  Regression coverage for the `saveSync` reentrancy hang (Crashlytics
//  8afb1c66) introduced by PR #1061. #1061 wrapped `saveSync` in
//  `diskWriteQueue.sync { ... }` AND moved the registry snapshot inside that
//  block. `saveSync` is reached from `BookmarkManager.setLocationSync`'s
//  `onComplete`, which runs inside a `BookRegistryStore.syncQueue` barrier, so
//  the snapshot's `registrySnapshot() → performSync → syncQueue.sync`
//  re-entered `syncQueue` from a thread already holding the barrier → deadlock.
//  The fix snapshots in the caller's context (off `diskWriteQueue`) and makes
//  the disk write reentrancy-safe.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace
import PalaceBookModel

@MainActor
final class BookRegistrySyncReentrancyTests: XCTestCase {

    private var store: BookRegistryStore!
    private var syncManager: BookRegistrySync!

    override func setUp() {
        super.setUp()
        store = BookRegistryStore()
        let appContainer = makeTestAppContainer()
        syncManager = BookRegistrySync(
            store: store,
            accountsManager: appContainer.accountsManager,
            downloadCenterProvider: { appContainer.downloadCenter },
            opdsFeedServiceProvider: { appContainer.opdsFeedService }
        )
    }

    override func tearDown() {
        syncManager = nil
        store = nil
        super.tearDown()
    }

    private func makeBook(identifier: String) -> TPPBook {
        TPPBook(
            acquisitions: [TPPFake.genericAcquisition],
            authors: nil, categoryStrings: nil, distributor: nil,
            identifier: identifier, imageURL: nil, imageThumbnailURL: nil,
            published: nil, publisher: nil, subtitle: nil, summary: nil,
            title: "Title \(identifier)", updated: Date(),
            annotationsURL: nil, analyticsURL: nil, alternateURL: nil,
            relatedWorksURL: nil, previewLink: nil, seriesURL: nil,
            revokeURL: nil, reportURL: nil, timeTrackingURL: nil,
            contributors: nil, bookDuration: nil, imageCache: MockImageCache()
        )
    }

    private func isolatedAccount() -> (String, URL) {
        let account = "brs-reentrancy-\(UUID().uuidString)"
        let url = syncManager.registryUrl(for: account)!
        return (account, url)
    }

    // MARK: - 8afb1c66: saveSync from inside a store barrier must not deadlock

    /// Reproduces the exact production path: `saveSync` invoked from inside a
    /// `BookRegistryStore.syncQueue` barrier (the same context as
    /// `BookmarkManager.setLocationSync`'s `onComplete`). Pre-fix this hung; the
    /// test fails by timeout if the deadlock returns.
    func testSaveSync_fromInsideRegistryStoreBarrier_doesNotDeadlock() {
        let (account, url) = isolatedAccount()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let book = makeBook(identifier: "reentrancy-1")
        store.mutateRegistrySync { $0[book.identifier] = TPPBookRegistryRecord(book: book, state: .downloadSuccessful) }

        let done = expectation(description: "saveSync from barrier returns")
        DispatchQueue.global(qos: .userInitiated).async {
            // onComplete runs inside performBarrierSync on syncQueue — the
            // reentrancy site. saveSync must take its snapshot here (on
            // syncQueue) and NOT re-enter syncQueue from within diskWriteQueue.
            self.store.mutateRegistrySync({ registry in
                registry[book.identifier]?.state = .used
            }, onComplete: {
                self.syncManager.saveSync(for: account)
            })
            done.fulfill()
        }
        wait(for: [done], timeout: 5.0)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "saveSync must persist the registry to disk after running from the store barrier"
        )
    }

    // MARK: - saveSync still persists the current snapshot (behavior preserved)

    func testSaveSync_persistsCurrentRegistrySnapshotToDisk() throws {
        let (account, url) = isolatedAccount()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let book = makeBook(identifier: "persist-1")
        store.mutateRegistrySync { $0[book.identifier] = TPPBookRegistryRecord(book: book, state: .downloadSuccessful) }

        syncManager.saveSync(for: account)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let records = try XCTUnwrap(json[TPPBookRegistryKey.records.rawValue] as? [[String: Any]])
        XCTAssertEqual(records.count, 1, "the one seeded record must be persisted")
    }

    // MARK: - Concurrent sync saves do not race or deadlock

    func testConcurrentSaveSync_allComplete() {
        let (account, url) = isolatedAccount()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let book = makeBook(identifier: "concurrent-1")
        store.mutateRegistrySync { $0[book.identifier] = TPPBookRegistryRecord(book: book, state: .downloadSuccessful) }

        let iterations = 20
        let done = expectation(description: "all saveSync return")
        done.expectedFulfillmentCount = iterations
        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            self.syncManager.saveSync(for: account)
            done.fulfill()
        }
        wait(for: [done], timeout: 10.0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - saveSync serializes its disk write through diskWriteQueue (#1061)

    /// Pins the reentrancy guard at `saveSync`'s tail: when NOT already on
    /// `diskWriteQueue` (the production path — `saveSync` arrives via the
    /// `syncQueue` barrier, never via `diskWriteQueue`), the write MUST be
    /// routed through `diskWriteQueue.sync` so it lands FIFO-last after any
    /// in-flight async `save(for:)` writes to the same URL. If the guard is
    /// inverted (the `!=`→`==` mutant), `saveSync` runs its write INLINE,
    /// bypassing the queue, and the trailing async writes clobber it — exactly
    /// the disk-write race #1061 closed. Distinguishes the two by record count:
    /// the async saves persist a 1-record snapshot; `saveSync` persists a
    /// 2-record snapshot taken after a second book is added. Original ⇒ the
    /// 2-record snapshot wins (written last); mutant ⇒ a 1-record async write
    /// clobbers it.
    func testSaveSync_writeRoutesThroughDiskWriteQueue_landsAfterInFlightAsyncSaves() throws {
        let (account, url) = isolatedAccount()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Snapshot A: a single book. Each async save(for:) captures this at
        // enqueue time and writes a 1-record registry, posting a notification
        // when its disk write completes.
        let book1 = makeBook(identifier: "serialize-1")
        store.mutateRegistrySync { $0[book1.identifier] = TPPBookRegistryRecord(book: book1, state: .downloadSuccessful) }

        let asyncWrites = 30
        let drained = expectation(description: "all async save(for:) writes flushed")
        drained.expectedFulfillmentCount = asyncWrites
        drained.assertForOverFulfill = false
        let token = NotificationCenter.default.addObserver(
            forName: .TPPBookRegistryDidChange, object: nil, queue: nil
        ) { _ in drained.fulfill() }
        defer { NotificationCenter.default.removeObserver(token) }

        for _ in 0..<asyncWrites { syncManager.save(for: account) }

        // Snapshot B: add a second book, then saveSync. saveSync captures the
        // 2-record snapshot in caller context and must write it FIFO-last.
        let book2 = makeBook(identifier: "serialize-2")
        store.mutateRegistrySync { $0[book2.identifier] = TPPBookRegistryRecord(book: book2, state: .downloadSuccessful) }
        syncManager.saveSync(for: account)

        wait(for: [drained], timeout: 15.0) // FLAKE-003-OK: waits for 30 async save(for:) disk writes to flush (NotificationCenter drain signal); integration-scoped real-I/O, generous under suite load.

        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let records = try XCTUnwrap(json[TPPBookRegistryKey.records.rawValue] as? [[String: Any]])
        XCTAssertEqual(
            records.count, 2,
            "saveSync must serialize through diskWriteQueue so its 2-record snapshot lands after the in-flight 1-record async writes; an inline (unserialized) write is clobbered by a trailing async save"
        )
    }

    // MARK: - Real bookmark → saveSync chain under concurrency

    /// Drives the ACTUAL production reentrancy path end-to-end:
    /// `BookmarkManager.setLocationSync` → `store.mutateRegistrySync` →
    /// `onComplete` (runs inside the `syncQueue` barrier) → `saveSync(for:)`.
    /// This is the exact call chain of Crashlytics 8afb1c66 — the previous
    /// reentrancy test invoked `saveSync` through a hand-rolled `mutateRegistrySync`
    /// onComplete; this one goes through the real `BookmarkManager` seam wired with
    /// the same `saveSync` closure production uses (`TPPBookRegistry.init` wires
    /// `saveSync: { sync?.saveSync(for: account) }`). ~20-way concurrent to smoke
    /// out the barrier-reentrancy hang under contention. Fails by timeout if the
    /// deadlock returns; asserts the location persisted to disk.
    func testSetLocationSync_fromMultipleThreads_savesyncSucceeds() throws {
        let (account, url) = isolatedAccount()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let book = makeBook(identifier: "setlocsync-1")
        store.mutateRegistrySync { $0[book.identifier] = TPPBookRegistryRecord(book: book, state: .downloadSuccessful) }

        // Wire the BookmarkManager exactly as TPPBookRegistry.init does: its
        // `saveSync` closure forwards to the sync manager under test, so
        // setLocationSync reaches the real saveSync via the onComplete barrier.
        let bookmarkManager = BookmarkManager(
            store: store,
            save: { [syncManager] account in syncManager?.save(for: account) },
            saveSync: { [syncManager] account in syncManager?.saveSync(for: account) }
        )

        let iterations = 20
        let done = expectation(description: "all setLocationSync return")
        done.expectedFulfillmentCount = iterations
        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            let location = TPPBookLocation(locationString: "loc-\(i)", renderer: "test-renderer")
            bookmarkManager.setLocationSync(location, forIdentifier: book.identifier, account: account)
            done.fulfill()
        }
        wait(for: [done], timeout: 10.0)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "the real setLocationSync → saveSync chain must persist the registry to disk"
        )
        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let records = try XCTUnwrap(json[TPPBookRegistryKey.records.rawValue] as? [[String: Any]])
        XCTAssertEqual(records.count, 1, "the one seeded book must be persisted after the concurrent location writes")
    }

    // MARK: - Concurrent load() + sync() must not deadlock and must not empty the shelf

    /// Runs `load()` (which takes a `store.mutateRegistry` barrier while it reads
    /// the on-disk registry) concurrently with `sync()` (which runs its guard /
    /// credential checks and, on a fresh unsigned-in account, takes the safe
    /// `currentAccount == nil` early return). The two barrier-adjacent paths race:
    /// a sync can fire while load's barrier is active. Pre-seeds the on-disk file
    /// so load has real records to restore — asserting the registry is REBUILT
    /// from disk (merged, non-empty), never overwritten to empty by the race.
    /// Fails by timeout if either path deadlocks against the store barrier.
    func testConcurrentLoadAndSync_bothComplete() {
        let (account, _) = isolatedAccount()
        let url = syncManager.registryUrl(for: account)!
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Seed the on-disk registry so load() has records to restore. Without a
        // file on disk load() legitimately settles to an empty registry — the
        // pre-seed is what lets us distinguish "merged/rebuilt" from
        // "overwritten to empty by the concurrent sync".
        let book = makeBook(identifier: "loadsync-1")
        store.mutateRegistrySync { $0[book.identifier] = TPPBookRegistryRecord(book: book, state: .downloadSuccessful) }
        syncManager.saveSync(for: account)
        store.removeAll()

        let loadDone = expectation(description: "load completes")
        let syncDone = expectation(description: "sync completes")

        DispatchQueue.concurrentPerform(iterations: 2) { i in
            if i == 0 {
                self.syncManager.load(account: account, setState: { _ in }) {
                    loadDone.fulfill()
                }
            } else {
                // sync() at currentState == .loaded runs its state guard + the
                // `currentAccount` lookup concurrently with load's barrier — the
                // reentrancy-adjacent surface under test. On a fresh unsigned-in
                // account it takes the safe early return (`currentAccount == nil`)
                // and returns SYNCHRONOUSLY without invoking `completion`, so we
                // signal on the call returning — its returning at all (not
                // hanging) is the deadlock check.
                self.syncManager.sync(
                    currentState: .loaded,
                    setState: { _ in },
                    completion: { _, _ in }
                )
                syncDone.fulfill()
            }
        }
        wait(for: [loadDone, syncDone], timeout: 10.0)

        // Merged/rebuilt from disk, not overwritten to empty by the concurrent sync.
        let restored = store.readRegistry { $0[book.identifier] }
        XCTAssertNotNil(
            restored,
            "load() must rebuild the seeded record from disk; the concurrent sync must not have overwritten the shelf to empty"
        )
    }
}

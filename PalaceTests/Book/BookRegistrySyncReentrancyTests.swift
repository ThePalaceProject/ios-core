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
}

//
//  TPPBookRegistryPersistenceTests.swift
//  PalaceTests
//
//  Deep, mutation-killing persistence tests for TPPBookRegistry and its
//  collaborator BookRegistrySync. Covers the P0 gap from
//  docs/Testing/Coverage_Roadmap.md §2.2:
//
//    - Save → cold-start load round-trip (state preserved across disk)
//    - Corrupted JSON on load → empty registry, no crash
//    - Truncated JSON on load → empty registry, no crash
//    - State-change publisher fires on real transitions
//    - State-change publisher does NOT fire on a no-op updateBook
//    - Account isolation: registry A's records don't leak into registry B
//    - Concurrent writes from two queues converge to a consistent on-disk file
//
//  Strategy
//  --------
//  Most tests drive BookRegistrySync + BookRegistryStore directly, the actual
//  persistence layer that TPPBookRegistry delegates to. This lets us pass an
//  explicit account UUID into save(for:) / load(account:) without touching the
//  shared AccountsManager singleton. The facade's other behaviors (publisher
//  emissions, in-memory state) are covered through TPPBookRegistry itself.
//
//  Each test uses a unique account UUID (`test-persistence-<UUID>`) so the
//  on-disk artifacts at
//    <AppSupport>/<bundleId>/<test-uuid>/registry/registry.json
//  never collide. tearDown removes the directory.
//
//  Copyright 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace

class TPPBookRegistryPersistenceTests: PalaceWiringTestCase {

    private var account: String!
    private var store: BookRegistryStore!
    private var sync: BookRegistrySync!
    private var accountsManager: AccountsManager!
    // NOTE: `cancellables` is inherited from PalaceWiringTestCase and drained
    // automatically on tearDown. Don't shadow it locally.

    override func setUpWithError() throws {
        try super.setUpWithError()
        account = "test-persistence-\(UUID().uuidString)"
        store = BookRegistryStore()
        accountsManager = makeFreshAccountsManager()
        // Lazy-resolved providers — never invoked unless we save records in a
        // file-tracking state (.downloading/.downloadSuccessful/.used/...). All
        // persistence round-trip tests below use `.holding`, which bypasses the
        // file-existence path in BookRegistrySync.load entirely.
        sync = BookRegistrySync(
            store: store,
            accountsManager: accountsManager,
            downloadCenterProvider: { AppContainer.production().downloadCenter },
            opdsFeedServiceProvider: { AppContainer.production().opdsFeedService }
        )
    }

    override func tearDownWithError() throws {
        // Best-effort cleanup of the on-disk registry directory for this test.
        if let url = sync?.registryUrl(for: account)?.deletingLastPathComponent() {
            try? FileManager.default.removeItem(at: url)
        }
        account = nil
        store = nil
        sync = nil
        accountsManager = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Inserts a record into the in-memory store under the given identifier and
    /// state. Uses the store's barrier API so the in-memory snapshot is fully
    /// committed before save reads `registrySnapshot()`.
    private func seedStore(identifier: String, title: String = "Persistence Book", state: TPPBookState = .holding) -> TPPBook {
        let book = TPPBookMocker.mockBook(identifier: identifier, title: title, distributorType: .EpubZip)
        store.mutateRegistrySync { registry in
            registry[identifier] = TPPBookRegistryRecord(book: book, state: state)
        }
        return book
    }

    /// Drives `sync.load(account:)` to completion. The load dispatches the
    /// in-memory mutation onto the store's concurrent queue and the publisher
    /// emission onto the main thread; we wait on a `loaded` setState callback
    /// and then drain the main RunLoop.
    ///
    /// Timeout: 30s. Locally these round-trips resolve in <1s, but CI
    /// runners under parallel-test contention have been observed exceeding
    /// 10s on the BookRegistry load path (JSON parse + publisher dispatch
    /// + RunLoop drain). PR #989 tightened this from 30s → 10s under the
    /// assumption that 10s "fail loud on degraded production load" was
    /// sufficient; the actual CI floor is higher. 30s still fails loud
    /// on a true regression (the local <1s baseline gives 30× headroom)
    /// without bouncing off runner load.
    private func loadAndWait(account: String) {
        let exp = expectation(description: "load(\(account)) completes")
        sync.load(account: account, setState: { newState in
            if newState == .loaded { exp.fulfill() }
        }, completion: nil)
        // Drain RunLoop so the publisher-on-main dispatch lands before assertions.
        wait(for: [exp], timeout: 30.0)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    }

    private func writeRaw(_ data: Data, to account: String) {
        guard let url = sync.registryUrl(for: account) else {
            XCTFail("registryUrl(for:) returned nil for account '\(account)'")
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Round-trip: save → reload from disk

    /// Kills the mutant: drop the `try registryData.write(to:options:.atomic)` call
    /// (or replace JSONSerialization output with empty data). If save is a no-op,
    /// the reload sees nothing and the state assertion below fails.
    func testSave_ThenColdStartLoad_PreservesRecord() {
        let bookId = "round-trip-\(UUID().uuidString)"
        _ = seedStore(identifier: bookId, title: "Round Trip", state: .holding)

        sync.saveSync(for: account)

        // Cold-start: drop the in-memory store and rebuild from disk.
        store = BookRegistryStore()
        sync = BookRegistrySync(
            store: store,
            accountsManager: accountsManager,
            downloadCenterProvider: { AppContainer.production().downloadCenter },
            opdsFeedServiceProvider: { AppContainer.production().opdsFeedService }
        )

        loadAndWait(account: account)

        XCTAssertEqual(store.state(for: bookId), .holding,
                       "Record state must be preserved across save → cold-start load round-trip")
        XCTAssertNotNil(store.book(forIdentifier: bookId),
                        "Book identity must be preserved across cold-start load")
        XCTAssertEqual(store.book(forIdentifier: bookId)?.title, "Round Trip",
                       "Title field must survive JSON round-trip — kills mutant that drops metadata serialization")
    }

    /// Kills the mutant that flips `.atomic` to a non-atomic write and writes
    /// partial data on the second save. Persistence must be the LAST-WRITER-WINS
    /// snapshot, not an additive append.
    func testSave_OverwritesPreviousSave_NotAppends() {
        let firstId = "first-\(UUID().uuidString)"
        _ = seedStore(identifier: firstId, state: .holding)
        sync.saveSync(for: account)

        // Replace in-memory contents with a single new record. The next save
        // must replace the on-disk snapshot, not merge with it.
        store.mutateRegistrySync { registry in registry.removeAll() }
        let secondId = "second-\(UUID().uuidString)"
        _ = seedStore(identifier: secondId, state: .holding)
        sync.saveSync(for: account)

        store = BookRegistryStore()
        sync = BookRegistrySync(
            store: store,
            accountsManager: accountsManager,
            downloadCenterProvider: { AppContainer.production().downloadCenter },
            opdsFeedServiceProvider: { AppContainer.production().opdsFeedService }
        )
        loadAndWait(account: account)

        XCTAssertNil(store.book(forIdentifier: firstId),
                     "Save must overwrite prior on-disk snapshot — first record must not survive")
        XCTAssertNotNil(store.book(forIdentifier: secondId),
                        "Second record from latest snapshot must be present on reload")
    }

    // MARK: - Corruption resilience

    /// Kills the mutant that replaces `(try? JSONSerialization.jsonObject(...)) as?
    /// TPPBookRegistryData` with a force-try — corrupted JSON must not crash;
    /// the registry must come up empty.
    func testLoad_WithCorruptedJSON_RegistryIsEmpty_DoesNotCrash() {
        // Write a deliberately garbled blob that is NOT valid JSON.
        let garbage = Data("not-valid-json-{[]}".utf8)
        writeRaw(garbage, to: account)

        loadAndWait(account: account)

        XCTAssertTrue(store.allBooks.isEmpty,
                      "Corrupted on-disk JSON must produce an empty registry, not partial garbage")
        // And a subsequent legitimate save must succeed (the registry remains usable).
        let recoveryId = "recovery-\(UUID().uuidString)"
        _ = seedStore(identifier: recoveryId, state: .holding)
        sync.saveSync(for: account)
        // Reload to confirm the file is now valid again.
        store = BookRegistryStore()
        sync = BookRegistrySync(
            store: store,
            accountsManager: accountsManager,
            downloadCenterProvider: { AppContainer.production().downloadCenter },
            opdsFeedServiceProvider: { AppContainer.production().opdsFeedService }
        )
        loadAndWait(account: account)
        XCTAssertNotNil(store.book(forIdentifier: recoveryId),
                        "Registry must recover (be writable + reloadable) after a corrupted-load")
    }

    /// Kills the mutant that drops the `json.array(for: .records)` nil-check —
    /// a truncated JSON object that can't be deserialized as a dictionary OR a
    /// dictionary that lacks the `records` key MUST produce empty state.
    func testLoad_WithTruncatedJSON_RegistryIsEmpty_DoesNotCrash() {
        // Truncate the JSON mid-stream so JSONSerialization fails. Starts with a
        // valid `{` but never closes.
        let truncated = Data("{\"records\":[{\"metadata\":{\"id\":\"abc\",\"title\":\"x\"".utf8)
        writeRaw(truncated, to: account)

        loadAndWait(account: account)

        XCTAssertTrue(store.allBooks.isEmpty,
                      "Truncated/malformed JSON must yield an empty registry — no partial parse, no crash")
    }

    /// Kills the mutant that drops the `let records = json.array(for: .records)`
    /// guard — when the file is valid JSON but missing the `records` array, the
    /// registry must come up empty.
    func testLoad_WithJSONMissingRecordsKey_RegistryIsEmpty() {
        let unrelatedJSON = Data("{\"some-other-key\":[]}".utf8)
        writeRaw(unrelatedJSON, to: account)

        loadAndWait(account: account)

        XCTAssertTrue(store.allBooks.isEmpty,
                      "JSON without a 'records' key must produce an empty registry")
    }

    // MARK: - Publisher emissions

    /// Kills the mutant that removes the `store.bookStateSubject.send(...)`
    /// inside setState — the registry must publish state transitions to
    /// downstream subscribers.
    func testBookStatePublisher_FiresOnDownloadingToDownloadedTransition() {
        let registry = TPPBookRegistry(accountsManager: makeFreshAccountsManager(), imageLoader: AppContainer.production().imageLoader)
        let book = TPPBookMocker.mockBook(identifier: "publisher-transition-\(UUID().uuidString)",
                                          title: "Transition Test",
                                          distributorType: .EpubZip)

        registry.addBook(book, state: .downloading)

        let received = expectation(description: "Publisher fires Downloaded after Downloading")
        registry.bookStatePublisher
            .filter { $0.0 == book.identifier && $0.1 == .downloadSuccessful }
            .first()
            .sink { _ in received.fulfill() }
            .store(in: &cancellables)

        registry.setState(.downloadSuccessful, for: book.identifier)

        wait(for: [received], timeout: 2.0)

        registry.removeBook(forIdentifier: book.identifier)
    }

    /// Kills the mutant that flips `nextState != previousState` to `==` (or
    /// drops the guard entirely) inside BookRegistryStore.updateBook —
    /// updateBook with the same book must NOT spuriously emit a state event
    /// when its state doesn't change.
    func testBookStatePublisher_DoesNotFireOnNoOpUpdateBook() {
        let registry = TPPBookRegistry(accountsManager: makeFreshAccountsManager(), imageLoader: AppContainer.production().imageLoader)
        let book = TPPBookMocker.mockBook(identifier: "no-op-update-\(UUID().uuidString)",
                                          title: "No-op Update",
                                          distributorType: .EpubZip)
        registry.addBook(book, state: .holding)
        // Drain the addBook emission so the next subscription is clean.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))

        var receivedAfterAdd: [(String, TPPBookState)] = []
        registry.bookStatePublisher
            .filter { $0.0 == book.identifier }
            .sink { receivedAfterAdd.append($0) }
            .store(in: &cancellables)

        registry.updateBook(book) // .holding → .holding (no-op transition)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))

        XCTAssertTrue(receivedAfterAdd.isEmpty,
                      "updateBook with unchanged state must not emit on bookStatePublisher — kills `nextState != previousState` → `==` mutant")

        registry.removeBook(forIdentifier: book.identifier)
    }

    // MARK: - Account isolation

    /// Kills the mutant that hard-codes a single registry URL regardless of the
    /// `account` argument. Writes to account A must NOT be visible when loading
    /// account B's registry.
    func testAccountIsolation_AccountADoesNotLeakIntoAccountB() {
        let accountA = "test-isolation-A-\(UUID().uuidString)"
        let accountB = "test-isolation-B-\(UUID().uuidString)"

        defer {
            if let urlA = sync.registryUrl(for: accountA)?.deletingLastPathComponent() {
                try? FileManager.default.removeItem(at: urlA)
            }
            if let urlB = sync.registryUrl(for: accountB)?.deletingLastPathComponent() {
                try? FileManager.default.removeItem(at: urlB)
            }
        }

        // Seed account A and persist.
        let aOnlyId = "a-only-\(UUID().uuidString)"
        let bookA = TPPBookMocker.mockBook(identifier: aOnlyId, title: "A Only", distributorType: .EpubZip)
        store.mutateRegistrySync { registry in
            registry[aOnlyId] = TPPBookRegistryRecord(book: bookA, state: .holding)
        }
        sync.saveSync(for: accountA)

        // Wipe in-memory + persist account B (empty).
        store.mutateRegistrySync { registry in registry.removeAll() }
        sync.saveSync(for: accountB)

        // Cold-start: load account B and confirm A's record is absent.
        store = BookRegistryStore()
        sync = BookRegistrySync(
            store: store,
            accountsManager: accountsManager,
            downloadCenterProvider: { AppContainer.production().downloadCenter },
            opdsFeedServiceProvider: { AppContainer.production().opdsFeedService }
        )
        loadAndWait(account: accountB)

        XCTAssertNil(store.book(forIdentifier: aOnlyId),
                     "Account A's record must NOT be visible when loading account B's registry")
        XCTAssertTrue(store.allBooks.isEmpty,
                      "Account B's registry must be empty — A's data must not leak across account boundaries")

        // Sanity: A's record must still be present when we load A.
        store = BookRegistryStore()
        sync = BookRegistrySync(
            store: store,
            accountsManager: accountsManager,
            downloadCenterProvider: { AppContainer.production().downloadCenter },
            opdsFeedServiceProvider: { AppContainer.production().opdsFeedService }
        )
        loadAndWait(account: accountA)
        XCTAssertNotNil(store.book(forIdentifier: aOnlyId),
                        "Account A's record must remain intact in A's registry after B was saved")
    }

    /// Kills the mutant that swaps `registryUrl(for: account)` to use a captured
    /// `self.account` — different accounts must produce different on-disk URLs.
    func testRegistryUrl_DiffersAcrossAccounts() {
        let urlA = sync.registryUrl(for: "account-A-\(UUID().uuidString)")
        let urlB = sync.registryUrl(for: "account-B-\(UUID().uuidString)")

        XCTAssertNotNil(urlA, "registryUrl must return a non-nil URL for a valid account")
        XCTAssertNotNil(urlB, "registryUrl must return a non-nil URL for a valid account")
        XCTAssertNotEqual(urlA, urlB,
                          "Different account UUIDs must map to different on-disk registry URLs")
    }

    // MARK: - Concurrent writes

    /// Kills the mutant that drops the serial `diskWriteQueue` and allows
    /// out-of-order writes — concurrent saves from two queues must converge on
    /// a valid on-disk JSON snapshot that contains the final in-memory state.
    func testConcurrentSaves_ProduceValidJSONOnDisk() {
        // Pre-seed with 10 records.
        let ids = (0..<10).map { "concurrent-\(UUID().uuidString)-\($0)" }
        store.mutateRegistrySync { registry in
            for id in ids {
                let book = TPPBookMocker.mockBook(identifier: id, title: "C-\(id)", distributorType: .EpubZip)
                registry[id] = TPPBookRegistryRecord(book: book, state: .holding)
            }
        }

        // Fire 20 saves split across two background queues. Each one snapshots
        // the current store state and writes it to disk. The serial
        // diskWriteQueue inside BookRegistrySync.save guarantees they don't
        // tear the file mid-write.
        let group = DispatchGroup()
        let qA = DispatchQueue(label: "test.concurrent.a")
        let qB = DispatchQueue(label: "test.concurrent.b")
        for _ in 0..<10 {
            group.enter()
            qA.async { [sync, account] in
                sync?.save(for: account!)
                group.leave()
            }
            group.enter()
            qB.async { [sync, account] in
                sync?.save(for: account!)
                group.leave()
            }
        }
        let waitExp = expectation(description: "All concurrent saves complete")
        group.notify(queue: .main) { waitExp.fulfill() }
        wait(for: [waitExp], timeout: 10.0)

        // Drain the diskWriteQueue deterministically. The async `save(for:)`
        // enqueues onto a serial queue; calling `saveSync(for:)` blocks until
        // its own enqueued write completes, which by FIFO semantics means all
        // previously enqueued writes (including the 20 above) have flushed.
        // No fixed-delay sleep needed.
        sync.saveSync(for: account)

        // Reload from disk and validate.
        store = BookRegistryStore()
        sync = BookRegistrySync(
            store: store,
            accountsManager: accountsManager,
            downloadCenterProvider: { AppContainer.production().downloadCenter },
            opdsFeedServiceProvider: { AppContainer.production().opdsFeedService }
        )
        loadAndWait(account: account)

        for id in ids {
            XCTAssertNotNil(store.book(forIdentifier: id),
                            "Concurrent save bursts must converge to a snapshot containing all 10 seeded records — '\(id)' missing")
        }
        XCTAssertEqual(store.allBooks.count, ids.count,
                       "Concurrent writes must not duplicate or drop records on disk")
    }
}

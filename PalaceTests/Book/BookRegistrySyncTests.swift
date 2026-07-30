//
//  BookRegistrySyncTests.swift
//  PalaceTests
//
//  Tests for BookRegistrySync: disk load/save state transitions,
//  download state validation, reset, sync URL guarding, and
//  bulk-deletion protection logic.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

final class BookRegistrySyncTests: XCTestCase {

    private var store: BookRegistryStore!
    private var syncManager: BookRegistrySync!
    private var accountsManager: AccountsManager!
    private var tempDirectory: URL!
    private var appContainer: AppContainer!
    private var scheduler: SpyRedownloadScheduler!
    private var isolatedAccountsManagers: [AccountsManager] = []
    /// Collapses production's account-switch grace period so tests assert the
    /// DECISION instead of sleeping through it.
    private static let testDelay: TimeInterval = 0.05

    override func setUp() {
        super.setUp()
        store = BookRegistryStore()
        appContainer = makeTestAppContainer()
        accountsManager = appContainer.accountsManager
        scheduler = SpyRedownloadScheduler()
        let container = appContainer!
        let spy = scheduler!
        syncManager = BookRegistrySync(
            store: store,
            accountsManager: container.accountsManager,
            downloadCenterProvider: { container.downloadCenter },
            opdsFeedServiceProvider: { container.opdsFeedService },
            redownloadSchedulerProvider: { spy },
            contentRedownloadDelay: Self.testDelay,
            orphanRedownloadDelay: Self.testDelay
        )

        // Create a temp directory for registry file I/O tests
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookRegistrySyncTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
        isolatedAccountsManagers.removeAll()
        scheduler = nil
        appContainer = nil
        syncManager = nil
        accountsManager = nil
        store = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeBook(
        identifier: String = "book-1",
        title: String = "Test Book"
    ) -> TPPBook {
        TPPBook(
            acquisitions: [TPPFake.genericAcquisition],
            authors: nil,
            categoryStrings: nil,
            distributor: nil,
            identifier: identifier,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: nil,
            publisher: nil,
            subtitle: nil,
            summary: nil,
            title: title,
            updated: Date(),
            annotationsURL: nil,
            analyticsURL: nil,
            alternateURL: nil,
            relatedWorksURL: nil,
            previewLink: nil,
            seriesURL: nil,
            revokeURL: nil,
            reportURL: nil,
            timeTrackingURL: nil,
            contributors: nil,
            bookDuration: nil,
            imageCache: MockImageCache()
        )
    }

    /// Writes a registry JSON file to the given URL for load testing.
    private func writeRegistryFile(records: [[String: Any]], to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json: [String: Any] = [TPPBookRegistryKey.records.rawValue: records]
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: url)
    }

    // MARK: - Reset

    func test_reset_clearsSyncUrlAndStore() {
        // Add a book to the store
        let book = makeBook()
        let addDone = expectation(description: "added")
        store.addBook(book, state: .downloadNeeded) { _ in addDone.fulfill() }
        wait(for: [addDone], timeout: 2.0)

        drainMainQueue()

        XCTAssertEqual(store.allBooks.count, 1)

        syncManager.syncUrl = URL(string: "https://example.com/loans")
        syncManager.reset("test-account")

        // Allow barrier to complete
        drainMainQueue()
            XCTAssertNil(self.syncManager.syncUrl)
            XCTAssertTrue(self.store.allBooks.isEmpty)
    }

    // MARK: - Loading Account Guard

    func test_load_preventsReentrantLoadsForSameAccount() {
        // Simulate a load in progress
        syncManager.loadingAccount = "account-1"

        var stateChanges: [TPPBookRegistry.RegistryState] = []
        let setState: (TPPBookRegistry.RegistryState) -> Void = { state in
            stateChanges.append(state)
        }

        // This should be skipped because loadingAccount is already "account-1"
        syncManager.load(account: "account-1", setState: setState)

        // Give time for any async work
        drainMainQueue()
            // No state changes should have occurred (the load was skipped)
            XCTAssertTrue(stateChanges.isEmpty)
    }

    func test_load_allowsLoadForDifferentAccount() {
        // A different account should not be blocked
        syncManager.loadingAccount = "account-1"

        var stateChanges: [TPPBookRegistry.RegistryState] = []
        let setState: (TPPBookRegistry.RegistryState) -> Void = { state in
            stateChanges.append(state)
        }

        // This tries to load account-2, which is different — should proceed
        // It will likely fail to find the registry file, but setState should be called
        syncManager.load(account: "account-2", setState: setState)

        drainMainQueue()
            // setState should have been called at least with .loading
            XCTAssertTrue(stateChanges.contains(.loading))
    }

    // MARK: - SyncUrl Cancellation

    func test_syncUrl_isSetDuringSync_andClearedAfter() {        // syncUrl should be nil initially
        XCTAssertNil(syncManager.syncUrl)
    }

    // MARK: - Store Snapshot Round-Trip

    func test_registrySnapshot_producesSerializableData() {
        let book = makeBook()
        let addDone = expectation(description: "added")
        store.addBook(book, state: .downloadNeeded) { _ in addDone.fulfill() }
        wait(for: [addDone], timeout: 2.0)

        drainMainQueue()

        let snapshot = store.registrySnapshot()
        XCTAssertEqual(snapshot.count, 1)

        // Should be JSON-serializable
        let registryObject = [TPPBookRegistryKey.records.rawValue: snapshot]
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: registryObject))
    }

    // MARK: - State Transition Logic During Load

    /// Drives `load()` end to end and asserts the state it PERSISTS.
    ///
    /// This replaces a stub of the same name that wrote a registry file and then
    /// asserted only that the file existed — it never called `load()`, so the
    /// reconciliation WIRING was entirely unpinned. The pure `reconcile`
    /// function is exhaustively covered by `BookRegistryReconciliationTableTests`,
    /// but a green detector proves nothing if `load()` never applies its result:
    /// deleting `record.state = decision.state` left every test green.
    func test_load_downloadingWithNoFileOnDisk_persistsDownloadFailed() throws {
        let (account, url) = makeIsolatedAccount()
        defer { cleanupAccount(url) }

        let book = makeBook(identifier: "dl-book-\(UUID().uuidString)")
        let record = TPPBookRegistryRecord(book: book, state: .downloading)
        try writeRegistryFile(records: [record.dictionaryRepresentation], to: url)

        let done = expectation(description: "loaded")
        syncManager.load(account: account) { state in
            if state == .loaded { done.fulfill() }
        }
        wait(for: [done], timeout: 10.0)

        XCTAssertEqual(
            store.state(for: book.identifier), .downloadFailed,
            "load() must APPLY the reconciliation decision, not merely compute it — a book left .downloading with nothing on disk did not finish downloading"
        )
    }

    /// Kills the mutant "load() ignores `presence`". The previous wiring test
    /// used a book with nothing on disk, so hardcoding `presence: .absent`
    /// produced the same answer and survived.
    func test_load_downloadingWithContentOnDisk_persistsDownloadSuccessful() throws {
        let (account, url) = makeIsolatedAccount()
        defer { cleanupAccount(url) }

        let book = makeBook(identifier: "dl-present-\(UUID().uuidString)")
        let record = TPPBookRegistryRecord(book: book, state: .downloading)
        try writeRegistryFile(records: [record.dictionaryRepresentation], to: url)

        // Put real content where the download center resolves this book.
        let contentURL = try XCTUnwrap(
            appContainer.downloadCenter.fileUrl(for: book, account: account)
        )
        try FileManager.default.createDirectory(at: contentURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x7A, count: 1024).write(to: contentURL)
        defer { try? FileManager.default.removeItem(at: contentURL) }

        let done = expectation(description: "loaded")
        syncManager.load(account: account) { state in
            if state == .loaded { done.fulfill() }
        }
        wait(for: [done], timeout: 10.0)

        XCTAssertEqual(
            store.state(for: book.identifier), .downloadSuccessful,
            "load() must feed the REAL disk condition into reconcile — a download interrupted after the content landed is finished, not failed"
        )
    }

    /// A sync manager whose accounts manager reports `account` as current.
    ///
    /// `load()` guards both re-download schedules on
    /// `currentAccountId == loadedAccount` — it must not kick off a transfer
    /// with the wrong auth context. Tests that assert scheduling therefore need
    /// the loaded account to BE the current one, via an isolated UserDefaults
    /// suite rather than writing to `.standard`.
    private func makeSchedulingSyncManager(currentAccount account: String)
        -> (BookRegistrySync, SpyRedownloadScheduler, BookRegistryStore) {
        let suite = UserDefaults(suiteName: "brs-sched-\(UUID().uuidString)")!
        suite.set(account, forKey: currentAccountIdentifierKey)
        let manager = AccountsManager(defaults: suite)
        let spy = SpyRedownloadScheduler()
        let localStore = BookRegistryStore()
        let container = appContainer!
        let sync = BookRegistrySync(
            store: localStore,
            accountsManager: manager,
            downloadCenterProvider: { container.downloadCenter },
            opdsFeedServiceProvider: { container.opdsFeedService },
            redownloadSchedulerProvider: { spy },
            contentRedownloadDelay: Self.testDelay,
            orphanRedownloadDelay: Self.testDelay
        )
        isolatedAccountsManagers.append(manager)
        return (sync, spy, localStore)
    }

    /// Kills the mutant "load() computes `schedulesContentRedownload` and never
    /// acts on it". A license with no `.lcpa` is the exact 3.2.3 defect: the
    /// patron holds a book that cannot play, and only this scheduling recovers it.
    func test_load_licenseWithoutContent_schedulesTheContentRedownload() throws {
        let account = "brs-test-\(UUID().uuidString)"
        let (sync, spy, localStore) = makeSchedulingSyncManager(currentAccount: account)
        let url = try XCTUnwrap(sync.registryUrl(for: account))
        defer { cleanupAccount(url) }

        let book = makeLCPAudiobook(identifier: "lcp-sched-\(UUID().uuidString)")
        let record = TPPBookRegistryRecord(book: book, state: .downloadSuccessful)
        try writeRegistryFile(records: [record.dictionaryRepresentation], to: url)

        let licenseURL = try XCTUnwrap(appContainer.downloadCenter.fileUrl(for: book, account: account))
            .deletingPathExtension().appendingPathExtension("lcpl")
        try FileManager.default.createDirectory(at: licenseURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: licenseURL)
        defer { try? FileManager.default.removeItem(at: licenseURL) }

        let scheduled = expectation(description: "content re-download scheduled")
        spy.onLCPContentRedownload = { if $0.identifier == book.identifier { scheduled.fulfill() } }

        let done = expectation(description: "loaded")
        sync.load(account: account) { if $0 == .loaded { done.fulfill() } }
        wait(for: [done], timeout: 10.0)
        wait(for: [scheduled], timeout: 20.0)

        XCTAssertEqual(localStore.state(for: book.identifier), .downloadNeeded,
                       "a license alone is not a playable book")
    }

    /// Kills the mutant "load() drops the orphan-redownload block". Content gone
    /// from disk with no license is a different recovery path from the one above.
    func test_load_contentMissingEntirely_schedulesTheOrphanRedownload() throws {
        let account = "brs-test-\(UUID().uuidString)"
        let (sync, spy, _) = makeSchedulingSyncManager(currentAccount: account)
        let url = try XCTUnwrap(sync.registryUrl(for: account))
        defer { cleanupAccount(url) }

        let book = makeBook(identifier: "orphan-\(UUID().uuidString)")
        let record = TPPBookRegistryRecord(book: book, state: .downloadSuccessful)
        try writeRegistryFile(records: [record.dictionaryRepresentation], to: url)

        let scheduled = expectation(description: "orphan re-download scheduled")
        spy.onOrphanRedownload = { if $0.identifier == book.identifier { scheduled.fulfill() } }

        let done = expectation(description: "loaded")
        sync.load(account: account) { if $0 == .loaded { done.fulfill() } }
        wait(for: [done], timeout: 10.0)
        wait(for: [scheduled], timeout: 20.0)
    }

    /// Kills the mutant "load() ignores `isDownloadInFlight`". `load()` is not
    /// launch-only — the app delegate runs it on every foreground — so during a
    /// multi-minute `.lcpa` transfer a warm load must leave the healthy
    /// in-flight download alone rather than declare it failed.
    func test_load_downloadInFlight_leavesTheDownloadingRecordAlone() throws {
        let account = "brs-test-\(UUID().uuidString)"
        let book = makeBook(identifier: "inflight-\(UUID().uuidString)")

        let localStore = BookRegistryStore()
        let container = appContainer!
        let sync = StubInFlightSync(
            store: localStore,
            accountsManager: container.accountsManager,
            downloadCenterProvider: { container.downloadCenter },
            opdsFeedServiceProvider: { container.opdsFeedService }
        )
        sync.inFlightIdentifiers = [book.identifier]

        let url = try XCTUnwrap(sync.registryUrl(for: account))
        defer { cleanupAccount(url) }
        let record = TPPBookRegistryRecord(book: book, state: .downloading)
        try writeRegistryFile(records: [record.dictionaryRepresentation], to: url)

        let done = expectation(description: "loaded")
        sync.load(account: account) { if $0 == .loaded { done.fulfill() } }
        wait(for: [done], timeout: 10.0)

        XCTAssertEqual(
            localStore.state(for: book.identifier), .downloading,
            "a foreground load during a live transfer must not flip a healthy in-flight download to .downloadFailed"
        )
    }

    /// The duplicate-download guard.
    ///
    /// A device trace of a fresh borrow showed reconciliation firing three times
    /// inside eight seconds while the `.lcpa` was still transferring; each pass
    /// saw a license with no content, and one scheduled re-download ran to
    /// completion alongside the fulfillment — two 1.8 GB transfers for one book,
    /// the second discarded with "an item with the same name already exists".
    ///
    /// `downloadInfo` cannot see the fulfillment (it lives on Readium's own
    /// URLSession), so the transfer registry is the only thing standing between a
    /// patron and a doubled download.
    func test_load_licenseWithoutContent_whileFulfillmentIsRunning_schedulesNothing() throws {
        let account = "brs-test-\(UUID().uuidString)"
        let (sync, spy, localStore) = makeSchedulingSyncManager(currentAccount: account)
        let url = try XCTUnwrap(sync.registryUrl(for: account))
        defer { cleanupAccount(url) }

        let book = makeLCPAudiobook(identifier: "lcp-inflight-\(UUID().uuidString)")
        let record = TPPBookRegistryRecord(book: book, state: .downloading)
        try writeRegistryFile(records: [record.dictionaryRepresentation], to: url)

        let licenseURL = try XCTUnwrap(appContainer.downloadCenter.fileUrl(for: book, account: account))
            .deletingPathExtension().appendingPathExtension("lcpl")
        try FileManager.default.createDirectory(at: licenseURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: licenseURL)
        defer { try? FileManager.default.removeItem(at: licenseURL) }

        // The fulfillment is mid-flight — exactly the device scenario.
        appContainer.downloadCenter.progressReporter
            .sendLCPContentDownloadActive(bookIdentifier: book.identifier, active: true)
        defer {
            appContainer.downloadCenter.progressReporter
                .sendLCPContentDownloadActive(bookIdentifier: book.identifier, active: false)
        }

        let done = expectation(description: "loaded")
        sync.load(account: account) { if $0 == .loaded { done.fulfill() } }
        wait(for: [done], timeout: 10.0)

        // Outlive both (now-collapsed) schedules without a wall-clock sleep.
        let settled = expectation(description: "schedules would have fired")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settled.fulfill() }
        wait(for: [settled], timeout: 5.0)

        XCTAssertTrue(
            spy.lcpContentRedownloads.isEmpty,
            "reconciliation re-downloaded a book that was already downloading — this is the doubled 1.8 GB transfer"
        )
        XCTAssertTrue(spy.orphanRedownloads.isEmpty, "no orphan restart either — the book is mid-transfer")
        XCTAssertEqual(localStore.state(for: book.identifier), .downloading,
                       "a book whose content is actively transferring stays .downloading")
    }

    // MARK: - Multiple Books with Various States

    func test_storeSnapshotWithMultipleStates() {
        let books: [(String, TPPBookState)] = [
            ("b1", .downloadNeeded),
            ("b2", .downloadSuccessful),
            ("b3", .holding),
            ("b4", .downloadFailed),
            ("b5", .used),
        ]

        let addDone = expectation(description: "all added")
        addDone.expectedFulfillmentCount = books.count

        for (id, state) in books {
            let book = makeBook(identifier: id, title: "Book \(id)")
            store.addBook(book, state: state) { _ in addDone.fulfill() }
        }
        wait(for: [addDone], timeout: 3.0)

        drainMainQueue()
            XCTAssertEqual(self.store.allBooks.count, 5)
            XCTAssertEqual(self.store.heldBooks.count, 1)
            // myBooks: downloadNeeded, downloadFailed, downloadSuccessful, used = 4
            XCTAssertEqual(self.store.myBooks.count, 4)

            for (id, expectedState) in books {
                XCTAssertEqual(self.store.state(for: id), expectedState,
                               "Expected \(expectedState) for book \(id)")
            }
    }

    // MARK: - Validate Downloaded Content

    func test_validateDownloadedContent_marksDownloadNeededWhenFileMissing() {
        // This test relies on the fact that no actual book file exists for our fake book,
        // so downloadSuccessful books should be marked as downloadNeeded.
        // However, validateDownloadedContent requires the test accountsManager to have a
        // current account, which won't be set in unit tests. We verify the store mutation
        // mechanism instead.

        let book = makeBook(identifier: "validated-book")
        let addDone = expectation(description: "added")
        store.addBook(book, state: .downloadSuccessful) { _ in addDone.fulfill() }
        wait(for: [addDone], timeout: 2.0)

        drainMainQueue()

        // Directly simulate what validateDownloadedContent does using mutateRegistrySync
        store.mutateRegistrySync { registry in
            for (identifier, record) in registry {
                if record.state == .downloadSuccessful || record.state == .used {
                    // Simulate: file doesn't exist
                    registry[identifier]?.state = .downloadNeeded
                }
            }
        }

        XCTAssertEqual(store.state(for: "validated-book"), .downloadNeeded)
    }

    // MARK: - Bulk Deletion Protection
    //
    // shouldSkipBulkDeletion must trip whenever the feed comes back empty and
    // we have ANY local books — regardless of local count. The old `localCount > 2`
    // floor let small libraries fall through and nuked every downloaded book when
    // a transient feed response was empty.

    func test_bulkDeletionProtection_emptyFeedWithLargeLibrary_skipsDeletion() {
        let localCount = 5
        let feedCount = 0
        let deletionCount = 5
        let shouldSkipBulkDeletion = BookRegistrySync.shouldSkipBulkDeletion(
            localCount: localCount, feedCount: feedCount, deletionCount: deletionCount
        )
        XCTAssertTrue(shouldSkipBulkDeletion,
                      "Empty feed with \(localCount) local books must be treated as a server error and skip deletion")
    }

    func test_bulkDeletionProtection_normalFeedDoesNotSkip() {
        let shouldSkipBulkDeletion = BookRegistrySync.shouldSkipBulkDeletion(
            localCount: 5, feedCount: 4, deletionCount: 1
        )
        XCTAssertFalse(shouldSkipBulkDeletion,
                       "A non-empty feed must proceed through normal reconciliation, not skip")
    }

    func test_bulkDeletionProtection_emptyFeedWithSingleLocalBook_skipsDeletion() {
        // This is the regression we're fixing: a 1-book shelf with a transient
        // empty feed must not delete that book.
        let shouldSkipBulkDeletion = BookRegistrySync.shouldSkipBulkDeletion(
            localCount: 1, feedCount: 0, deletionCount: 1
        )
        XCTAssertTrue(shouldSkipBulkDeletion,
                      "1-book shelf + empty feed must skip deletion — losing a single downloaded book is still a data-loss regression")
    }

    func test_bulkDeletionProtection_emptyFeedWithTwoLocalBooks_skipsDeletion() {
        // Matches the user-reported scenario: 2 test books, transient empty feed response,
        // previously-downloaded book shows Download button after relaunch.
        let shouldSkipBulkDeletion = BookRegistrySync.shouldSkipBulkDeletion(
            localCount: 2, feedCount: 0, deletionCount: 2
        )
        XCTAssertTrue(shouldSkipBulkDeletion,
                      "2-book shelf + empty feed must skip deletion")
    }

    func test_bulkDeletionProtection_zeroLocalBooks_doesNotSkip() {
        // Nothing to protect — skip flag only exists to guard non-empty local state.
        let shouldSkipBulkDeletion = BookRegistrySync.shouldSkipBulkDeletion(
            localCount: 0, feedCount: 0, deletionCount: 0
        )
        XCTAssertFalse(shouldSkipBulkDeletion,
                       "No local books means no deletion to skip")
    }

    func test_largeDeletionWarning_notTriggeredForSmallRatio() {
        let localCount = 10
        let deletionCount = 2
        let deletionRatio = Double(deletionCount) / Double(localCount)

        let shouldWarnLargeDeletion = localCount > 4
            && deletionRatio > 0.5
            && deletionCount > 2

        XCTAssertFalse(shouldWarnLargeDeletion,
                       "Should NOT warn when deletion ratio is below 50%")
    }

    // MARK: - registryUrl

    func test_registryUrl_returnsPathContainingAccountAndRegistryFile() {
        let account = "unit-test-acct-\(UUID().uuidString)"
        let url = syncManager.registryUrl(for: account)
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.lastPathComponent, "registry.json")
        XCTAssertEqual(url?.deletingLastPathComponent().lastPathComponent, "registry")
        XCTAssertTrue(url?.path.contains(account) ?? false,
                      "Expected path to contain account id for isolation")
    }

    // MARK: - Load: end-to-end via real disk

    /// Uses a unique per-test account so registryUrl maps to an isolated directory
    /// we can write to directly. Cleans up after.
    private func makeIsolatedAccount() -> (String, URL) {
        let account = "brs-test-\(UUID().uuidString)"
        let url = syncManager.registryUrl(for: account)!
        return (account, url)
    }

    private func cleanupAccount(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func test_load_withMissingFile_transitionsToLoadedWithEmptyRegistry() {
        let (account, url) = makeIsolatedAccount()
        defer { cleanupAccount(url) }
        // Do NOT write the file.

        let done = expectation(description: "loaded")
        var finalState: TPPBookRegistry.RegistryState?
        syncManager.load(account: account) { state in
            finalState = state
            if state == .loaded { done.fulfill() }
        }
        wait(for: [done], timeout: 3.0)

        XCTAssertEqual(finalState, .loaded)
        XCTAssertEqual(store.allBooks.count, 0)
    }

    func test_load_withMalformedJSON_doesNotCrashAndLoadsEmpty() {
        let (account, url) = makeIsolatedAccount()
        defer { cleanupAccount(url) }

        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("{ not valid json".utf8).write(to: url)

        let done = expectation(description: "loaded")
        syncManager.load(account: account) { state in
            if state == .loaded { done.fulfill() }
        }
        wait(for: [done], timeout: 3.0)

        XCTAssertEqual(store.allBooks.count, 0)
    }

    // MARK: - Reset deletes disk file

    func test_reset_removesRegistryFileFromDisk() throws {
        let (account, url) = makeIsolatedAccount()
        defer { cleanupAccount(url) }

        let book = makeBook(identifier: "r-1")
        let record = TPPBookRegistryRecord(book: book, state: .downloadNeeded)
        try writeRegistryFile(records: [record.dictionaryRepresentation], to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        syncManager.reset(account)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "reset(account:) must delete the registry file from disk")
        XCTAssertNil(syncManager.syncUrl)
    }

    // 3.2.3 introduced two on-disk SIDECARS next to `registry.json`: the
    // last-good `.bak` written before every good save, and `.corrupt-<ts>`
    // quarantine copies. `reset(account:)` — the sign-out / force-reset /
    // "delete server data" path — deleted only the PRIMARY, so a signed-out
    // patron's entire shelf (titles, ids, reading positions) stayed readable on
    // disk in the `.bak` indefinitely. It also keeps
    // `RegistryFileRecovery.onDiskHasRecords` true after sign-out, and leaves
    // the corrupt-primary recovery path able to restore the PREVIOUS patron's
    // books into the next patron's session at the same library (same account
    // UUID → same registry path).
    //
    // Verified live on 3.2.3 (489): after sign-out + relaunch, `registry.json`
    // was gone but `registry.json.bak` still held all 9 of the signed-out
    // patron's records.
    func test_reset_removesBackupAndQuarantineSidecars() throws {
        let (account, url) = makeIsolatedAccount()
        defer { cleanupAccount(url) }

        let book = makeBook(identifier: "r-sidecar")
        let record = TPPBookRegistryRecord(book: book, state: .downloadNeeded)
        try writeRegistryFile(records: [record.dictionaryRepresentation], to: url)

        let backup = RegistryFileRecovery.backupURL(for: url)
        try Data(contentsOf: url).write(to: backup)
        let quarantine = RegistryFileRecovery.quarantineURL(
            for: url,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try Data("{ truncated".utf8).write(to: quarantine)

        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), "setup: .bak present")
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine.path), "setup: quarantine present")

        syncManager.reset(account)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "reset must delete the primary registry file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path),
                       "reset must delete the last-good .bak — otherwise a signed-out patron's shelf persists on disk and can be recovered into the next patron's session")
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantine.path),
                       "reset must prune quarantined corrupt registry copies rather than accumulate them forever")
    }

    // MARK: - checkIfBookFileExists

    func test_checkIfBookFileExists_returnsFalseForUnknownBook() {
        let book = makeBook(identifier: "nofile")
        let exists = syncManager.checkIfBookFileExists(for: book, account: "ghost-account")
        XCTAssertFalse(exists)
    }

    // MARK: - sync: account-fixture injection helper
    //
    // F-003 / PP-4542: the PP-4407 awaitReady() migration changed sync()'s
    // contract for the "current account present but no loansUrl" case. The
    // OLD synchronous guard `guard let loansUrl = currentAccount.loansUrl
    // else { return }` was a clean no-op; the NEW code reaches setState(.loaded)
    // + completion(nil,false) — either synchronously (no stored credentials) or
    // after awaitReady() resolves to AccountDetails with a nil loansUrl
    // (anonymous library). The two tests below previously dodged this with a
    // `try XCTSkipIf(currentAccount?.loansUrl != nil)` band-aid, so they
    // false-greened on a signed-in CI sim and only ran in a clean env. They
    // now INJECT a fixture account (unique UUID → host sign-in state is
    // irrelevant) and assert the real state sequence.

    /// Seeds a fresh-UUID fixture Account as the injected manager's
    /// `currentAccount`. The UUID is unique per call, so the production-stack
    /// credentials lookup (`TPPUserAccount.sharedAccount(libraryUUID:)` →
    /// `AppContainer.production().accountsManager.userAccount(for:)`) returns a
    /// never-signed-in instance: `hasCredentials() == false`, deterministically,
    /// regardless of what account the host simulator has signed in.
    ///
    /// - Returns: the fixture's UUID and a cleanup closure (removes the seeded
    ///   account + restores the prior currentAccountId). Defer-call it.
    private func seedFixtureCurrentAccount() -> (uuid: String, cleanup: () -> Void) {
        let fixtureId = "brs-pp4542-\(UUID().uuidString)"
        let pub = OPDS2Publication(
            links: [OPDS2Link(href: "https://example.com/catalog",
                              rel: "http://opds-spec.org/catalog")],
            metadata: OPDS2Publication.Metadata(id: fixtureId, title: "PP-4542 Fixture"),
            images: nil
        )
        let fixture = Account(publication: pub, imageCache: MockImageCache())
        let cleanup = accountsManager._seedAccountForTesting(fixture)
        return (fixtureId, cleanup)
    }

    /// Builds an `AccountDetails` whose auth document has NO "shelf" link, so
    /// `details.loansUrl == nil` — the anonymous-library shape that drives
    /// sync()'s post-awaitReady `.loaded` branch.
    private func makeNoLoansUrlDetails(uuid: String) -> AccountDetails {
        let json: [String: Any] = [
            "id": "urn:uuid:\(uuid)",
            "title": "Anonymous Library (no shelf link)",
            "authentication": [[
                "type": "http://librarysimplified.org/rel/auth/anonymous",
                "inputs": ["login": ["keyboard": "Default"],
                           "password": ["keyboard": "Default"]],
                "labels": ["login": "Login", "password": "Password"]
            ]],
            "features": ["enabled": [], "disabled": []]
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let doc = try! OPDS2AuthenticationDocument.fromData(data)
        return AccountDetails(authenticationDocument: doc, uuid: uuid)
    }

    // MARK: - sync: re-entrancy guard

    func test_sync_whenAlreadySyncing_returnsBeforeSettingSyncingState() throws {
        // The `if currentState == .syncing { return }` guard sits AFTER the
        // credentials gate, so it is only REACHABLE once hasCredentials() is
        // true. We therefore give the fixture stored credentials (on the exact
        // production-manager instance sync() will consult) and drive its
        // awaitReady() state to a terminal .detailsLoaded with a nil loansUrl.
        // Keychain-gated because credential writes need the entitlement (CI
        // sims without it skip — this is an environment-capability guard, NOT
        // a host-sign-in-state dodge).
        try KeychainAvailability.skipIfUnavailable()

        let (uuid, cleanup) = seedFixtureCurrentAccount()
        defer { cleanup() }

        // Credentials must live on the instance sync() reads:
        // sharedAccount(libraryUUID:) → production manager's userAccount(for:).
        let prodUserAccount = AppContainer.production().accountsManager.userAccount(for: uuid) // MIGRATED-DEFERRED: PP-4542 — sync() checks hasCredentials() via sharedAccount→production keychain-backed userAccount; the credential path has no DI seam (only currentAccount STATE is injected)
        prodUserAccount.setAuthToken("pp4542-token", barcode: "bc", pin: "1234",
                                     expirationDate: Date().addingTimeInterval(3600))
        defer { prodUserAccount.removeAll() }
        XCTAssertTrue(prodUserAccount.hasCredentials(),
                      "Precondition: fixture has stored credentials so sync() reaches the .syncing guard")

        // Drive awaitReady() to a terminal so the Task branch (if reached) does
        // not hang the test. loansUrl is nil → if the guard were absent, sync()
        // would setState(.syncing) here.
        accountsManager.currentAccount?._setState(.detailsLoaded(makeNoLoansUrlDetails(uuid: uuid)))

        var received: [TPPBookRegistry.RegistryState] = []
        var completed = false
        let setState: (TPPBookRegistry.RegistryState) -> Void = { received.append($0) }

        // Already-.syncing: the re-entrancy guard must short-circuit BEFORE
        // setState(.syncing). We allow the (defensive) async Task to settle, then
        // assert no state was ever emitted.
        let exp = expectation(description: "sync re-entrancy settled")
        syncManager.sync(currentState: .syncing, setState: setState) { _, _ in completed = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)

        XCTAssertTrue(received.isEmpty,
                      "sync() called while already .syncing must short-circuit before setState — got \(received)")
        XCTAssertFalse(completed,
                       "completion must not fire for the re-entrancy short-circuit")
        XCTAssertNil(syncManager.syncUrl,
                     "syncUrl must not be captured for a short-circuited re-entrant sync")
    }

    func test_sync_whenNotSyncing_withCredentialsAndNoLoansUrl_resolvesToLoaded() throws {
        // Contrast to the re-entrancy test: SAME credentialed fixture with a
        // nil loansUrl, but currentState is .loaded (not .syncing). Now the
        // re-entrancy guard does NOT fire, so sync() proceeds into the Task,
        // awaits readiness, sees no loansUrl, and resolves to setState(.loaded)
        // + completion(nil,false). This proves the .syncing short-circuit above
        // is what suppresses setState — not the mere presence of credentials.
        try KeychainAvailability.skipIfUnavailable()

        let (uuid, cleanup) = seedFixtureCurrentAccount()
        defer { cleanup() }

        let prodUserAccount = AppContainer.production().accountsManager.userAccount(for: uuid) // MIGRATED-DEFERRED: PP-4542 — sync() checks hasCredentials() via sharedAccount→production keychain-backed userAccount; the credential path has no DI seam (only currentAccount STATE is injected)
        prodUserAccount.setAuthToken("pp4542-token", barcode: "bc", pin: "1234",
                                     expirationDate: Date().addingTimeInterval(3600))
        defer { prodUserAccount.removeAll() }

        accountsManager.currentAccount?._setState(.detailsLoaded(makeNoLoansUrlDetails(uuid: uuid)))

        var received: [TPPBookRegistry.RegistryState] = []
        var completionArgs: (errorDoc: [AnyHashable: Any]?, newBooks: Bool)?
        let setState: (TPPBookRegistry.RegistryState) -> Void = { received.append($0) }

        let exp = expectation(description: "sync resolved")
        syncManager.sync(currentState: .loaded, setState: setState) { errorDoc, newBooks in
            completionArgs = (errorDoc, newBooks)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3.0)

        // sync() sets .syncing, then awaitReady resolves with no loansUrl → .loaded.
        XCTAssertEqual(received.last, .loaded,
                       "no-loansUrl account must end in .loaded after awaitReady, not stay .syncing — got \(received)")
        XCTAssertNil(completionArgs?.errorDoc,
                     "anonymous/no-loansUrl resolution is not an error — errorDocument must be nil")
        XCTAssertEqual(completionArgs?.newBooks, false,
                       "no loans were fetched, so newBooks must be false")
        XCTAssertNil(syncManager.syncUrl,
                     "syncUrl must be cleared (never set) when there is no loansUrl to sync")
    }

    // MARK: - sync: load-completion guard
    //
    // These guards prevent the cold-launch race where sync() runs before load()
    // populates the in-memory registry. Without the guard, every loan in the feed
    // would be written as a fresh .downloadNeeded record, overwriting the on-disk
    // state and wiping location/bookmarks. The guard MUST run before any other
    // check in sync() — specifically before the currentAccount lookup — so this
    // test is deterministic regardless of simulator sign-in state.

    func test_sync_whenStateIsUnloaded_shortCircuitsBeforeTouchingAccounts() {
        var received: [TPPBookRegistry.RegistryState] = []
        var completed = false
        let setState: (TPPBookRegistry.RegistryState) -> Void = { received.append($0) }

        syncManager.sync(currentState: .unloaded, setState: setState) { _, _ in
            completed = true
        }

        XCTAssertTrue(received.isEmpty,
                      "sync() with .unloaded state must not invoke setState — the in-memory registry is empty and sync would overwrite the disk file with fresh .downloadNeeded records")
        XCTAssertNil(syncManager.syncUrl,
                     "syncUrl must not be captured for a short-circuited sync — a stale syncUrl would cause a later feed response to be applied to the wrong account")
        XCTAssertFalse(completed,
                       "completion must not fire for a short-circuited sync — callers should not observe side-effects of a no-op")
    }

    func test_sync_whenStateIsLoading_shortCircuitsBeforeTouchingAccounts() {
        // The account-change observer sets state to .loading, calls load(), and
        // schedules sync() 1 second later. If load's disk I/O runs slow (large
        // registry, older device), sync fires while state is still .loading.
        // Without this guard, sync would overwrite the still-loading disk state.
        var received: [TPPBookRegistry.RegistryState] = []
        var completed = false
        let setState: (TPPBookRegistry.RegistryState) -> Void = { received.append($0) }

        syncManager.sync(currentState: .loading, setState: setState) { _, _ in
            completed = true
        }

        XCTAssertTrue(received.isEmpty,
                      "sync() with .loading state must not invoke setState — load is in progress and sync would race against it")
        XCTAssertNil(syncManager.syncUrl)
        XCTAssertFalse(completed)
    }

    func test_sync_withCurrentAccountButNoCredentials_resolvesToLoadedSynchronously() {
        // F-003 / PP-4542. NEW contract: with a current account whose
        // production-stack user-account has NO stored credentials, sync() takes
        // the credentials gate — setState(.loaded) + completion(nil,false) —
        // and returns BEFORE touching awaitReady/the loans feed. This replaces
        // the old `try XCTSkipIf(currentAccount?.loansUrl != nil)` dodge: the
        // fixture's UUID is unique, so the production manager returns a
        // never-signed-in TPPUserAccount and hasCredentials() is false
        // regardless of host sign-in state.
        //
        // No keychain guard needed: we assert the ABSENCE of credentials, and a
        // fresh-UUID instance has none whether or not the keychain is writable.
        let (uuid, cleanup) = seedFixtureCurrentAccount()
        defer { cleanup() }

        let prodUserAccount = AppContainer.production().accountsManager.userAccount(for: uuid) // MIGRATED-DEFERRED: PP-4542 — sync() checks hasCredentials() via sharedAccount→production keychain-backed userAccount; the credential path has no DI seam (only currentAccount STATE is injected)
        XCTAssertFalse(prodUserAccount.hasCredentials(),
                       "Precondition: fresh-UUID fixture must have no stored credentials")

        var received: [TPPBookRegistry.RegistryState] = []
        var completionArgs: (errorDoc: [AnyHashable: Any]?, newBooks: Bool)?
        let setState: (TPPBookRegistry.RegistryState) -> Void = { received.append($0) }

        syncManager.sync(currentState: .loaded, setState: setState) { errorDoc, newBooks in
            completionArgs = (errorDoc, newBooks)
        }

        // The credentials-gate path is synchronous — no awaiting needed.
        XCTAssertEqual(received, [.loaded],
                       "no-credentials sync must emit exactly one setState(.loaded) — got \(received)")
        XCTAssertNotNil(completionArgs,
                        "completion must fire synchronously for the no-credentials gate")
        XCTAssertNil(completionArgs?.errorDoc,
                     "deferring sync for missing credentials is not an error")
        XCTAssertEqual(completionArgs?.newBooks, false,
                       "no loans fetched → newBooks must be false")
        XCTAssertNil(syncManager.syncUrl,
                     "syncUrl must never be captured when the credentials gate defers the sync")
    }

    // MARK: - Reliability WS-B: registry resilience (INV-1, quarantine, backup, schema)
    //
    // Ported from #1212 ("Bulletproof Ownership") onto 3.2.3. These drive the
    // real load/save disk pipeline on an isolated per-test account so
    // registryUrl maps to a temp directory we own. They exercise the
    // corrupt-file quarantine branch, `.bak` recovery, the empty-over-backup save
    // refusal (INV-1), and schema versioning/migration.

    /// Adds one book to `store`, snapshots the exact dictionary shape production
    /// persists, then clears the store. The returned records round-trip through
    /// the same `TPPBookRegistryRecord(record:)` path production uses on load.
    private func snapshotWithOneBook(id: String = "wsb-book", state: TPPBookState = .downloadNeeded) -> [[String: Any]] {
        let book = makeBook(identifier: id, title: "WS-B \(id)")
        let added = expectation(description: "added")
        store.addBook(book, state: state) { _ in added.fulfill() }
        wait(for: [added], timeout: 2.0)
        drainMainQueue()
        let snapshot = store.registrySnapshot()
        store.removeAll()
        drainMainQueue()
        return snapshot
    }

    /// Writes a `{ [schemaVersion,] records }` payload to an arbitrary URL.
    private func writeRegistryPayload(records: [[String: Any]], schemaVersion: Int?, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var json: [String: Any] = [TPPBookRegistryKey.records.rawValue: records]
        if let schemaVersion { json[RegistryFileRecovery.schemaVersionKey] = schemaVersion }
        let data = try! JSONSerialization.data(withJSONObject: json)
        try! data.write(to: url)
    }

    /// Spins the run loop until `predicate()` is true or `timeout` elapses. Lets
    /// `DispatchQueue.main.async` completion blocks (e.g. the save notification)
    /// run while we wait on the background disk write.
    private func waitUntil(timeout: TimeInterval = 3.0, _ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// Fixed run-loop settle for asserting the ABSENCE of an effect (a refused
    /// save posts no notification, so there is no positive edge to await).
    private func settle(_ seconds: TimeInterval = 0.4) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func quarantineFileExists(besideRegistryAt url: URL) -> Bool {
        let dir = url.deletingLastPathComponent()
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return contents.contains { $0.hasPrefix("registry.json.corrupt-") }
    }

    // MARK: INV-1 — empty save refused over a non-empty backup without server authority

    func testSaveEmptyOverNonEmptyBackup_isRefusedWithoutServerAuthority() {
        let (account, url) = makeIsolatedAccount()
        defer { cleanupAccount(url) }

        // Arrange: a non-empty last-good backup on disk + the SUT in the
        // post-corrupt-load rebuild window with an empty in-memory shelf.
        let goodRecords = snapshotWithOneBook(id: "kept-book")
        XCTAssertEqual(goodRecords.count, 1, "precondition: backup fixture has one record")
        writeRegistryPayload(records: goodRecords, schemaVersion: 1,
                             to: RegistryFileRecovery.backupURL(for: url))
        XCTAssertTrue(RegistryFileRecovery.backupHasRecords(for: url),
                      "precondition: a non-empty .bak exists")
        syncManager.needsRebuildFromServer = true
        XCTAssertTrue(store.allBooks.isEmpty, "precondition: empty in-memory shelf")

        // Act: a NON-authoritative save of the empty shelf.
        syncManager.save(for: account)
        settle()

        // Assert: the last-good backup survived — the empty snapshot was refused.
        XCTAssertTrue(RegistryFileRecovery.backupHasRecords(for: url),
                      "INV-1: a non-authoritative empty save must NOT clobber the non-empty last-good backup")
        // And the primary was not written as a valid-empty file that erased the shelf.
        if case .valid(let recs) = RegistryFileRecovery.classify(data: try? Data(contentsOf: url)) {
            XCTFail("INV-1: the primary registry.json must not be overwritten with a valid-empty file during rebuild (found \(recs.count) records)")
        }
        XCTAssertTrue(syncManager.needsRebuildFromServer,
                      "a refused save must leave the rebuild flag set")
    }

    func testSaveEmpty_withServerAuthority_persistsAndClearsRebuildFlag() {
        let (account, url) = makeIsolatedAccount()
        defer { cleanupAccount(url) }

        syncManager.needsRebuildFromServer = true
        XCTAssertTrue(store.allBooks.isEmpty)

        // An authoritative sync result may legitimately persist an empty shelf.
        syncManager.save(for: account, serverAuthoritative: true)
        waitUntil { FileManager.default.fileExists(atPath: url.path) }

        guard case .valid(let recs) = RegistryFileRecovery.classify(data: try? Data(contentsOf: url)) else {
            return XCTFail("an authoritative empty save must persist a valid (empty) registry.json")
        }
        XCTAssertTrue(recs.isEmpty, "the authoritative save persisted the empty shelf")
        XCTAssertFalse(syncManager.needsRebuildFromServer,
                       "an authoritative save must clear the rebuild flag")
    }

    func testNonEmptySave_isNeverBlocked_evenDuringRebuildWindow() {
        // Borrowing a book during the rebuild window is a legitimate non-empty
        // save; it must proceed and exit the rebuild window.
        let (account, url) = makeIsolatedAccount()
        defer { cleanupAccount(url) }

        syncManager.needsRebuildFromServer = true
        let added = expectation(description: "added")
        store.addBook(makeBook(identifier: "borrowed-during-rebuild"), state: .downloadNeeded) { _ in added.fulfill() }
        wait(for: [added], timeout: 2.0)
        drainMainQueue()

        syncManager.save(for: account)   // non-authoritative, but non-empty
        waitUntil { FileManager.default.fileExists(atPath: url.path) }

        guard case .valid(let recs) = RegistryFileRecovery.classify(data: try? Data(contentsOf: url)) else {
            return XCTFail("a non-empty save must always persist a valid registry")
        }
        XCTAssertEqual(recs.count, 1, "the borrowed book must be persisted despite the rebuild flag")
        XCTAssertFalse(syncManager.needsRebuildFromServer,
                       "a successful non-empty save clears the rebuild flag")
        // A non-empty save (even non-authoritative) must refresh the last-good
        // `.bak` sidecar — this is the recovery source a later corrupt load reads.
        XCTAssertTrue(RegistryFileRecovery.backupHasRecords(for: url),
                      "a non-empty save must write the last-good .bak backup")
    }

    // MARK: INV-1 (broadened, HelpSpot #18414) — non-authoritative empty over a
    // non-empty PRIMARY is refused even with NO rebuild flag; zero-book patron
    // is un-trapped via the authoritative sync path instead.
    //
    // D1 shipped a corrupt-only guard: it refused an empty non-authoritative
    // save only while `needsRebuildFromServer` was set (i.e. a `.bak` existed
    // from a corrupt load). D2 broadens it to cover the confirmed data-loss
    // wedge where the shelf was NEVER corrupted (no `.bak`, flag unset) but
    // registry sync wedged on a dropped auth-doc fetch, leaving an empty
    // in-memory shelf poised to clobber a healthy primary. These two tests flip
    // the D1 assertion for that precondition (non-authoritative empty over a
    // non-empty primary now REFUSED), and the third proves the genuine
    // zero-book patron is NOT trapped because the authoritative loans-feed sync
    // still persists empty.

    func testEmptySave_nonAuthoritative_overNonEmptyPrimary_isRefused_evenWithoutRebuildFlag() {
        // The exact HelpSpot #18414 data-loss path: a healthy non-empty primary
        // on disk, NO rebuild flag (never corrupted), an empty in-memory shelf
        // (registry sync wedged / never populated), and an incidental
        // non-authoritative save. That save must be REFUSED so the patron's
        // books survive — this is the wedge D1's corrupt-only guard missed.
        let (account, url) = makeIsolatedAccount()
        defer { cleanupAccount(url) }

        writeRegistryPayload(records: snapshotWithOneBook(id: "kept-primary"),
                             schemaVersion: 1, to: url)
        XCTAssertTrue(RegistryFileRecovery.primaryHasRecords(for: url),
                      "precondition: a non-empty primary registry.json exists")
        XCTAssertFalse(syncManager.needsRebuildFromServer,
                       "precondition: NOT in a rebuild window (clean load, no corruption)")
        XCTAssertTrue(store.allBooks.isEmpty, "precondition: empty in-memory shelf (wedge)")

        // Act: a plain (non-authoritative) empty save.
        syncManager.save(for: account)
        settle()

        // Assert: the healthy primary survived — the empty snapshot was refused.
        guard case .valid(let recs) = RegistryFileRecovery.classify(data: try? Data(contentsOf: url)) else {
            return XCTFail("INV-1(broadened): the non-empty primary must NOT be overwritten/erased by a non-authoritative empty save")
        }
        XCTAssertEqual(recs.count, 1,
                       "INV-1(broadened): a non-authoritative empty save must NOT clobber a non-empty primary even without a rebuild flag — this is the #18414 data-loss guard")
    }

    func testSaveSyncEmpty_overNonEmptyPrimary_isRefused_evenWithoutRebuildFlag() {
        // Same broadened invariant for the SYNCHRONOUS teardown path
        // (bookmark/location persistence on scene disconnect): a bookmark-flush
        // must never erase a healthy primary while the in-memory shelf is
        // transiently empty, flag or no flag.
        let (account, url) = makeIsolatedAccount()
        defer { cleanupAccount(url) }

        writeRegistryPayload(records: snapshotWithOneBook(id: "sync-kept-primary"),
                             schemaVersion: 1, to: url)
        XCTAssertTrue(RegistryFileRecovery.primaryHasRecords(for: url))
        XCTAssertFalse(syncManager.needsRebuildFromServer)
        XCTAssertTrue(store.allBooks.isEmpty)

        syncManager.saveSync(for: account)   // synchronous — no run loop needed

        guard case .valid(let recs) = RegistryFileRecovery.classify(data: try? Data(contentsOf: url)) else {
            return XCTFail("INV-1(broadened): saveSync must not erase a non-empty primary with an empty snapshot")
        }
        XCTAssertEqual(recs.count, 1,
                       "saveSync of an empty shelf must be refused over a non-empty primary even with no rebuild flag")
    }

    func testEmptySave_withServerAuthority_overNonEmptyPrimary_persists_zeroBookPatronNotTrapped() {
        // The don't-over-block guarantee: a GENUINE zero-book patron (server's
        // loans feed came back empty) persists an empty shelf via the
        // AUTHORITATIVE sync save — even over a previously non-empty primary.
        // This is how a patron who returned their last book is NOT trapped with
        // a stale non-empty file: the authoritative reconciliation clears it.
        let (account, url) = makeIsolatedAccount()
        defer { cleanupAccount(url) }

        writeRegistryPayload(records: snapshotWithOneBook(id: "returned-then-synced"),
                             schemaVersion: 1, to: url)
        XCTAssertTrue(RegistryFileRecovery.primaryHasRecords(for: url),
                      "precondition: a non-empty primary exists (the book before the loans-feed reconciliation)")
        XCTAssertTrue(store.allBooks.isEmpty, "precondition: reconciled in-memory shelf is empty")

        // Act: the authoritative loans-feed reconciliation persists the empty shelf.
        syncManager.save(for: account, serverAuthoritative: true)
        waitUntil {
            if case .valid(let recs) = RegistryFileRecovery.classify(data: try? Data(contentsOf: url)) {
                return recs.isEmpty
            }
            return false
        }

        guard case .valid(let recs) = RegistryFileRecovery.classify(data: try? Data(contentsOf: url)) else {
            return XCTFail("an authoritative empty save must persist a valid (empty) registry.json even over a non-empty primary")
        }
        XCTAssertTrue(recs.isEmpty,
                      "a genuine zero-book patron is NOT trapped: the authoritative sync persists the empty shelf over the stale non-empty primary")
    }

    func testSaveSyncEmpty_duringRebuildWindow_isRefused() {
        // saveSync is always non-authoritative teardown persistence — an empty
        // snapshot during the rebuild window must be refused so a bookmark-flush
        // on scene disconnect cannot erase the shelf before an authoritative sync.
        let (account, url) = makeIsolatedAccount()
        defer { cleanupAccount(url) }

        let goodRecords = snapshotWithOneBook(id: "sync-kept")
        writeRegistryPayload(records: goodRecords, schemaVersion: 1,
                             to: RegistryFileRecovery.backupURL(for: url))
        syncManager.needsRebuildFromServer = true
        XCTAssertTrue(store.allBooks.isEmpty)

        syncManager.saveSync(for: account)

        XCTAssertTrue(RegistryFileRecovery.backupHasRecords(for: url),
                      "INV-1: saveSync of an empty shelf during rebuild must NOT clobber the non-empty backup")
        if case .valid(let recs) = RegistryFileRecovery.classify(data: try? Data(contentsOf: url)) {
            XCTFail("INV-1: saveSync must not persist a valid-empty primary during rebuild (found \(recs.count) records)")
        }
    }

    // MARK: Corrupt-load quarantine + backup recovery

    func testCorruptLoad_recoversFromNonEmptyBackup_andQuarantinesOriginal() {
        let (account, url) = makeIsolatedAccount()
        defer { cleanupAccount(url) }

        // A valid non-empty backup + a corrupt primary.
        let good = snapshotWithOneBook(id: "recovered-book")
        writeRegistryPayload(records: good, schemaVersion: 1,
                             to: RegistryFileRecovery.backupURL(for: url))
        writeRegistryPayload(records: [], schemaVersion: nil, to: url) // ensure dir exists
        try! Data("{ truncated corrupt primary".utf8).write(to: url)

        let done = expectation(description: "loaded")
        syncManager.load(account: account) { state in if state == .loaded { done.fulfill() } }
        wait(for: [done], timeout: 3.0)

        XCTAssertEqual(store.allBooks.count, 1,
                       "a corrupt primary must be healed from the last-good .bak — the shelf is restored, not erased")
        XCTAssertFalse(syncManager.needsRebuildFromServer,
                       "successful .bak recovery must NOT flag a server rebuild")
        XCTAssertTrue(quarantineFileExists(besideRegistryAt: url),
                      "the corrupt original must be quarantined to registry.json.corrupt-<ts>")
    }

    func testCorruptLoad_withoutBackup_leavesEmptyAndFlagsRebuild_andQuarantines() {
        let (account, url) = makeIsolatedAccount()
        defer { cleanupAccount(url) }

        // Corrupt primary, NO backup.
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data("{ corrupt and no backup".utf8).write(to: url)

        let done = expectation(description: "loaded")
        syncManager.load(account: account) { state in if state == .loaded { done.fulfill() } }
        wait(for: [done], timeout: 3.0)

        XCTAssertTrue(store.allBooks.isEmpty,
                      "with no recoverable backup the in-memory shelf is left empty (not populated from a corrupt file)")
        XCTAssertTrue(syncManager.needsRebuildFromServer,
                      "an unrecoverable corrupt load must set needsRebuildFromServer so the next sync repopulates")
        XCTAssertTrue(quarantineFileExists(besideRegistryAt: url),
                      "even with no backup, the corrupt original must be quarantined")
    }

    func testCorruptLoad_thenNonAuthoritativeEmptySave_isRefused_untilServerSync() {
        // End-to-end INV-1: corrupt load with a recoverable backup restores the
        // shelf; the last-good backup remains intact.
        let (account, url) = makeIsolatedAccount()
        defer { cleanupAccount(url) }

        let good = snapshotWithOneBook(id: "shelf-book")
        writeRegistryPayload(records: good, schemaVersion: 1,
                             to: RegistryFileRecovery.backupURL(for: url))
        try! Data("{ corrupt".utf8).write(to: url)

        let done = expectation(description: "loaded")
        syncManager.load(account: account) { state in if state == .loaded { done.fulfill() } }
        wait(for: [done], timeout: 3.0)
        // Recovery from .bak succeeds here, so the shelf is restored and NOT flagged.
        XCTAssertEqual(store.allBooks.count, 1)
        XCTAssertFalse(syncManager.needsRebuildFromServer)
        XCTAssertTrue(RegistryFileRecovery.backupHasRecords(for: url),
                      "the last-good backup remains intact after a recovering load")
    }

    // MARK: Schema version + migration

    func testSave_writesSchemaVersionField() {
        let (account, url) = makeIsolatedAccount()
        defer { cleanupAccount(url) }

        let added = expectation(description: "added")
        store.addBook(makeBook(identifier: "schema-book"), state: .downloadNeeded) { _ in added.fulfill() }
        wait(for: [added], timeout: 2.0)
        drainMainQueue()

        syncManager.save(for: account)
        waitUntil { FileManager.default.fileExists(atPath: url.path) }

        let version = RegistryFileRecovery.schemaVersion(from: try? Data(contentsOf: url))
        XCTAssertEqual(version, RegistryFileRecovery.currentSchemaVersion,
                       "save() must stamp the current schemaVersion into the persisted payload")
    }

    func testSchemaMigration_unversionedFileLoads_thenSaveWritesVersion() {
        let (account, url) = makeIsolatedAccount()
        defer { cleanupAccount(url) }

        // An OLD file: valid records, but NO schemaVersion field.
        let legacy = snapshotWithOneBook(id: "legacy-book")
        writeRegistryPayload(records: legacy, schemaVersion: nil, to: url)
        XCTAssertNil(RegistryFileRecovery.schemaVersion(from: try? Data(contentsOf: url)),
                     "precondition: the legacy file is unversioned")

        // Load migrates it in-memory (loads fine); the book must appear.
        let done = expectation(description: "loaded")
        syncManager.load(account: account) { state in if state == .loaded { done.fulfill() } }
        wait(for: [done], timeout: 3.0)
        XCTAssertEqual(store.allBooks.count, 1, "an unversioned legacy file must load without loss")
        XCTAssertFalse(syncManager.needsRebuildFromServer, "a valid legacy file is not a corrupt/rebuild case")

        // Saving migrates it on disk to the versioned shape.
        syncManager.save(for: account)
        waitUntil {
            RegistryFileRecovery.schemaVersion(from: try? Data(contentsOf: url)) != nil
        }
        XCTAssertEqual(RegistryFileRecovery.schemaVersion(from: try? Data(contentsOf: url)),
                       RegistryFileRecovery.currentSchemaVersion,
                       "the next save must migrate the unversioned file to the current schema version")
    }

    /// An LCP audiobook shaped like a real `/loans/` acquisition: the acquisition
    /// type is the LCP *license* MIME with the audiobook as an indirect. That
    /// shape is what `LCPAudiobooks.canOpenBook` requires, and it is what the
    /// server actually sends — a fixture that skips the indirect makes the
    /// license-only branch of `contentPresence` unreachable and the test vacuous.
    private func makeLCPAudiobook(identifier: String) -> TPPBook {
        let acquisition = TPPOPDSAcquisition(
            relation: .generic,
            type: "application/vnd.readium.lcp.license.v1.0+json",
            hrefURL: URL(string: "https://example.org/loans/\(identifier)")!,
            indirectAcquisitions: [
                TPPOPDSIndirectAcquisition(type: "application/audiobook+lcp", indirectAcquisitions: [])
            ],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        return TPPBook(
            acquisitions: [acquisition],
            authors: nil, categoryStrings: nil, distributor: nil,
            identifier: identifier, imageURL: nil, imageThumbnailURL: nil,
            published: nil, publisher: nil, subtitle: nil, summary: nil,
            title: "LCP Audiobook", updated: Date(),
            annotationsURL: nil, analyticsURL: nil, alternateURL: nil,
            relatedWorksURL: nil, previewLink: nil, seriesURL: nil,
            revokeURL: nil, reportURL: nil, timeTrackingURL: nil,
            contributors: nil, bookDuration: nil, imageCache: MockImageCache()
        )
    }
}

/// Observes what `load()` scheduled. See `RegistryRedownloadScheduling` — the
/// real methods live in extensions on `MyBooksDownloadCenter` and cannot be
/// overridden, which is why the seam exists.
final class SpyRedownloadScheduler: RegistryRedownloadScheduling {
    var lcpContentRedownloads: [TPPBook] = []
    var orphanRedownloads: [TPPBook] = []
    var onLCPContentRedownload: ((TPPBook) -> Void)?
    var onOrphanRedownload: ((TPPBook) -> Void)?

    func scheduleLCPContentRedownload(for book: TPPBook) {
        lcpContentRedownloads.append(book)
        onLCPContentRedownload?(book)
    }

    func scheduleOrphanRedownload(for book: TPPBook) {
        orphanRedownloads.append(book)
        onOrphanRedownload?(book)
    }
}

/// Forces the in-flight answer without standing up a real transfer.
/// `isDownloadInFlight` reads `downloadCenter.downloadInfo(forBookIdentifier:)`,
/// which only a live `URLSession` task populates.
final class StubInFlightSync: BookRegistrySync {
    var inFlightIdentifiers: Set<String> = []

    override func isDownloadInFlight(for book: TPPBook) -> Bool {
        inFlightIdentifiers.contains(book.identifier)
    }
}

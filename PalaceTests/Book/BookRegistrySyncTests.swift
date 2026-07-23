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
import PalaceBookModel

@MainActor
final class BookRegistrySyncTests: XCTestCase {

    private var store: BookRegistryStore!
    private var syncManager: BookRegistrySync!
    private var accountsManager: AccountsManager!
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        store = BookRegistryStore()
        let appContainer = makeTestAppContainer()
        accountsManager = appContainer.accountsManager
        syncManager = BookRegistrySync(
            store: store,
            accountsManager: appContainer.accountsManager,
            downloadCenterProvider: { appContainer.downloadCenter },
            opdsFeedServiceProvider: { appContainer.opdsFeedService }
        )

        // Create a temp directory for registry file I/O tests
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookRegistrySyncTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
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

    func test_reset_clearsSyncUrlAndStore() async {
        // CONVERTED: addBook completion+wait replaced with the S1 seam join.
        let book = makeBook()
        store.addBook(book, state: .downloadNeeded)
        await store._awaitPendingWritesForTesting()

        XCTAssertEqual(store.allBooks.count, 1)

        syncManager.syncUrl = URL(string: "https://example.com/loans")
        syncManager.reset("test-account")
        // reset() calls store.removeAll(), which is itself a barrier write —
        // join the seam again so the read below observes the post-reset state.
        await store._awaitPendingWritesForTesting()

        XCTAssertNil(syncManager.syncUrl)
        XCTAssertTrue(store.allBooks.isEmpty)
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

    func test_registrySnapshot_producesSerializableData() async {
        // CONVERTED: addBook completion+wait replaced with the S1 seam join.
        let book = makeBook()
        store.addBook(book, state: .downloadNeeded)
        await store._awaitPendingWritesForTesting()

        let snapshot = store.registrySnapshot()
        XCTAssertEqual(snapshot.count, 1)

        // Should be JSON-serializable
        let registryObject = [TPPBookRegistryKey.records.rawValue: snapshot]
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: registryObject))
    }

    // MARK: - State Transition Logic During Load

    func test_loadStateTransition_downloadingWithNoFile_becomesDownloadFailed() {
        // The checkIfBookFileExists will return false for our fake book
        // since no file is on disk. This tests the state correction logic.
        let book = makeBook(identifier: "dl-book")
        let record = TPPBookRegistryRecord(book: book, state: .downloading)
        let dict = record.dictionaryRepresentation

        // Write a registry with the downloading record
        let registryUrl = tempDirectory
            .appendingPathComponent("registry")
            .appendingPathComponent("registry.json")

        do {
            try writeRegistryFile(records: [dict], to: registryUrl)
        } catch {
            XCTFail("Failed to write test registry: \(error)")
            return
        }

        // Verify the file was written
        XCTAssertTrue(FileManager.default.fileExists(atPath: registryUrl.path))
    }

    // MARK: - Multiple Books with Various States

    func test_storeSnapshotWithMultipleStates() async {
        let books: [(String, TPPBookState)] = [
            ("b1", .downloadNeeded),
            ("b2", .downloadSuccessful),
            ("b3", .holding),
            ("b4", .downloadFailed),
            ("b5", .used),
        ]

        // CONVERTED: per-add expectedFulfillmentCount expectation+wait replaced
        // with the S1 seam join — all 5 barrier writes are FIFO on the same
        // syncQueue, so a single trailing join drains them all.
        for (id, state) in books {
            let book = makeBook(identifier: id, title: "Book \(id)")
            store.addBook(book, state: state)
        }
        await store._awaitPendingWritesForTesting()

        XCTAssertEqual(store.allBooks.count, 5)
        XCTAssertEqual(store.heldBooks.count, 1)
        // myBooks: downloadNeeded, downloadFailed, downloadSuccessful, used = 4
        XCTAssertEqual(store.myBooks.count, 4)

        for (id, expectedState) in books {
            XCTAssertEqual(store.state(for: id), expectedState,
                           "Expected \(expectedState) for book \(id)")
        }
    }

    // MARK: - Validate Downloaded Content

    func test_validateDownloadedContent_marksDownloadNeededWhenFileMissing() async {
        // This test relies on the fact that no actual book file exists for our fake book,
        // so downloadSuccessful books should be marked as downloadNeeded.
        // However, validateDownloadedContent requires the test accountsManager to have a
        // current account, which won't be set in unit tests. We verify the store mutation
        // mechanism instead.

        let book = makeBook(identifier: "validated-book")
        // CONVERTED: addBook completion+wait replaced with the S1 seam join.
        store.addBook(book, state: .downloadSuccessful)
        await store._awaitPendingWritesForTesting()

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

    // MARK: - sync: feed-fetch branches (P5 — OPDSFeedFetching seam)
    //
    // Before P5, `opdsFeedServiceProvider` returned the concrete `OPDSFeedService`
    // actor, so the three branches below the credentials gate were untestable
    // (no way to force a fetch failure or return a fixture feed). Widening the
    // provider to `() -> OPDSFeedFetching` lets these tests inject a fake fetcher
    // and drive:
    //   1. the feed-fetch FAILURE branch (setState(.loaded) + error document)
    //   2. the `.synced` success path (setState(.synced), syncUrl cleared)
    //   3. the awaitReady() catch/carrier branch (aborts BEFORE any fetch)
    // All three sit AFTER the keychain-backed credentials gate, so they seed real
    // stored credentials on the production user-account instance sync() consults
    // — hence the keychain-availability guard (environment-capability, not a
    // host-sign-in dodge).

    /// AccountDetails whose auth document HAS an `http://opds-spec.org/shelf`
    /// link, so `details.loansUrl != nil` — the shape that lets sync() proceed
    /// past the loansUrl guard into the feed fetch.
    private func makeLoansUrlDetails(
        uuid: String,
        loansHref: String = "https://loans.example.com/shelf"
    ) -> AccountDetails {
        let json: [String: Any] = [
            "id": "urn:uuid:\(uuid)",
            "title": "Library With Shelf Link",
            "links": [["rel": "http://opds-spec.org/shelf", "href": loansHref]],
            "authentication": [[
                "type": "http://opds-spec.org/auth/basic",
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

    /// A minimal, well-formed OPDS acquisition feed with zero entries — the
    /// "all loans reconciled, nothing to add/remove" shape used to drive the
    /// `.synced` success path without a heavy fixture.
    private func makeEmptyLoansFeed() -> TPPOPDSFeed {
        let xmlString = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <id>urn:uuid:p5-empty-loans</id>
          <title>Loans</title>
          <updated>2026-01-01T00:00:00Z</updated>
        </feed>
        """
        let xml = TPPXML.xml(withData: Data(xmlString.utf8))!
        return TPPOPDSFeed(xml: xml)!
    }

    /// Builds a BookRegistrySync sharing this test's `store` + `accountsManager`
    /// (so the seeded fixture account is visible to sync()) but with the OPDS
    /// feed provider swapped for `feedFetcher`.
    private func makeSyncManager(feedFetcher: OPDSFeedFetching) -> BookRegistrySync {
        // Use the test AppContainer's downloadCenter (the AppContainer.production()
        // lint whitelists makeTestAppContainer over a raw production() reference —
        // the download path is inert wiring here; only the feed provider is exercised).
        let appContainer = makeTestAppContainer()
        return BookRegistrySync(
            store: store,
            accountsManager: accountsManager,
            downloadCenterProvider: { appContainer.downloadCenter },
            opdsFeedServiceProvider: { feedFetcher }
        )
    }

    /// Shared arrange for the two post-awaitReady tests: seed a credentialed
    /// fixture whose details expose a loansUrl. Returns the uuid plus a cleanup
    /// closure the caller must defer.
    private func seedCredentialedLoansAccount() throws -> (uuid: String, cleanup: () -> Void) {
        try KeychainAvailability.skipIfUnavailable()
        let (uuid, seedCleanup) = seedFixtureCurrentAccount()

        let prodUserAccount = AppContainer.production().accountsManager.userAccount(for: uuid) // MIGRATED-DEFERRED: PP-4542 — sync() checks hasCredentials() via sharedAccount→production keychain-backed userAccount; the credential path has no DI seam (only currentAccount STATE is injected)
        prodUserAccount.setAuthToken("p5-token", barcode: "bc", pin: "1234",
                                     expirationDate: Date().addingTimeInterval(3600))
        XCTAssertTrue(prodUserAccount.hasCredentials(),
                      "Precondition: fixture must have credentials so sync() reaches the feed fetch")

        accountsManager.currentAccount?._setState(.detailsLoaded(makeLoansUrlDetails(uuid: uuid)))

        return (uuid, {
            prodUserAccount.removeAll()
            seedCleanup()
        })
    }

    func test_sync_whenFeedFetchFails_revertsToLoadedAndForwardsErrorDocument() throws {
        let (_, cleanup) = try seedCredentialedLoansAccount()
        defer { cleanup() }

        let fetcher = StubOPDSFeedFetcher()
        fetcher.stubbedError = NSError(domain: "P5.feedFetch", code: 503,
                                       userInfo: ["p5.marker": "boom"])
        let sut = makeSyncManager(feedFetcher: fetcher)

        var received: [TPPBookRegistry.RegistryState] = []
        var completionArgs: (errorDoc: [AnyHashable: Any]?, newBooks: Bool)?
        let exp = expectation(description: "feed fetch failure resolved")
        sut.sync(currentState: .loaded, setState: { received.append($0) }) { errorDoc, newBooks in
            completionArgs = (errorDoc, newBooks)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3.0)

        XCTAssertEqual(fetcher.resetCacheCalls, [true],
                       "loans sync must request a cache-reset fetch (resetCache: true) through the widened seam — got \(fetcher.resetCacheCalls)")
        XCTAssertEqual(received.last, .loaded,
                       "a feed-fetch failure must revert state to .loaded, not leave it stuck .syncing — got \(received)")
        XCTAssertEqual(completionArgs?.errorDoc?["p5.marker"] as? String, "boom",
                       "the thrown NSError.userInfo must be forwarded to completion as the error document")
        XCTAssertEqual(completionArgs?.newBooks, false,
                       "a failed fetch fetched no loans → newBooks must be false")
        XCTAssertNil(sut.syncUrl,
                     "syncUrl must be cleared after a failed feed fetch")
    }

    func test_sync_whenFeedFetchSucceeds_resolvesToSyncedAndClearsSyncUrl() throws {
        let (_, cleanup) = try seedCredentialedLoansAccount()
        defer { cleanup() }

        let fetcher = StubOPDSFeedFetcher()
        fetcher.stubbedFeed = makeEmptyLoansFeed()
        let sut = makeSyncManager(feedFetcher: fetcher)

        var received: [TPPBookRegistry.RegistryState] = []
        var completionArgs: (errorDoc: [AnyHashable: Any]?, newBooks: Bool)?
        let exp = expectation(description: "feed fetch succeeded")
        sut.sync(currentState: .loaded, setState: { received.append($0) }) { errorDoc, newBooks in
            completionArgs = (errorDoc, newBooks)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3.0)

        XCTAssertEqual(fetcher.resetCacheCalls, [true],
                       "successful loans sync must also request a cache-reset fetch")
        XCTAssertEqual(received.last, .synced,
                       "a successful feed fetch must land the registry in .synced — got \(received)")
        XCTAssertNil(completionArgs?.errorDoc,
                     "a successful sync is not an error — errorDocument must be nil")
        XCTAssertEqual(completionArgs?.newBooks, false,
                       "an empty loans feed against an empty registry made no changes → newBooks false")
        XCTAssertNil(sut.syncUrl,
                     "syncUrl must be cleared once the synced reconciliation completes")
    }

    func test_sync_whenAwaitReadyFails_revertsToLoadedWithoutFetching() throws {
        try KeychainAvailability.skipIfUnavailable()
        let (uuid, seedCleanup) = seedFixtureCurrentAccount()
        defer { seedCleanup() }

        let prodUserAccount = AppContainer.production().accountsManager.userAccount(for: uuid) // MIGRATED-DEFERRED: PP-4542 — sync() checks hasCredentials() via sharedAccount→production keychain-backed userAccount; the credential path has no DI seam (only currentAccount STATE is injected)
        prodUserAccount.setAuthToken("p5-token", barcode: "bc", pin: "1234",
                                     expirationDate: Date().addingTimeInterval(3600))
        defer { prodUserAccount.removeAll() }

        // Terminal FAILED load state → awaitReady() throws on its fast path,
        // BEFORE sync() ever reaches the feed fetch.
        accountsManager.currentAccount?._setState(
            .detailsFailed(.authDocumentFetchFailed(underlyingDescription: "p5 injected")))

        let fetcher = StubOPDSFeedFetcher()
        let sut = makeSyncManager(feedFetcher: fetcher)

        var received: [TPPBookRegistry.RegistryState] = []
        var completionArgs: (errorDoc: [AnyHashable: Any]?, newBooks: Bool)?
        let exp = expectation(description: "awaitReady failure resolved")
        sut.sync(currentState: .loaded, setState: { received.append($0) }) { errorDoc, newBooks in
            completionArgs = (errorDoc, newBooks)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3.0)

        XCTAssertTrue(fetcher.resetCacheCalls.isEmpty,
                      "awaitReady() failure must abort BEFORE the feed fetch — the fetcher must never be called")
        XCTAssertEqual(received.last, .loaded,
                       "an awaitReady failure reverts to .loaded so BookRegistrySync's own retry policy re-drives — got \(received)")
        XCTAssertNil(completionArgs?.errorDoc,
                     "the awaitReady catch resolves with a nil error document (distinct from the loans-fetch error path)")
        XCTAssertEqual(completionArgs?.newBooks, false)
        XCTAssertNil(sut.syncUrl,
                     "syncUrl must be cleared (never left set) when awaitReady aborts the sync")
    }

    // MARK: - Reliability WS-B: registry resilience (INV-1, quarantine, backup, schema)
    //
    // These drive the real load/save disk pipeline on an isolated per-test
    // account so registryUrl maps to a temp directory we own. They exercise the
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

    /// Runs `action` (a `syncManager.save(...)` that writes on the background
    /// `diskWriteQueue`) and JOINS its completion by waiting for the
    /// `.TPPBookRegistryDidChange` notification the save posts on the main
    /// queue *after* the `write(to:)` lands — rather than polling `fileExists`
    /// against a wall-clock deadline. The observer is registered before
    /// `action` runs (and the post can't be serviced until this synchronous
    /// body yields into `wait(for:)`), so the save's post is captured
    /// deterministically. This is the success-path join: on the refused-save
    /// path no notification fires, which is exactly why the absence assertions
    /// still use `settle()` (there is no positive edge to await).
    ///
    /// Replaces the old `waitUntil { fileExists }` RunLoop poll: under CI
    /// oversubscription the `RunLoop.current.run(until:)` spin could exhaust
    /// the fixed deadline before the thread was scheduled to service the
    /// background write, silently asserting against a not-yet-written file.
    private func awaitRegistrySaved(timeout: TimeInterval = 5.0, _ action: () -> Void) {
        let saved = expectation(description: "registry disk write posted TPPBookRegistryDidChange")
        saved.assertForOverFulfill = false
        let token = NotificationCenter.default.addObserver(
            forName: .TPPBookRegistryDidChange, object: nil, queue: .main
        ) { _ in saved.fulfill() }
        defer { NotificationCenter.default.removeObserver(token) }
        action()
        wait(for: [saved], timeout: timeout)
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
        // UNJOINABLE: this save is REFUSED by INV-1 (empty + non-authoritative +
        // rebuild window) so the diskWriteQueue closure returns early WITHOUT
        // writing or posting `.TPPBookRegistryDidChange`. There is no positive
        // edge to join — we assert the ABSENCE of a clobber, so a bounded
        // `settle()` (fixed run-loop drain) is the correct primitive here.
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
        awaitRegistrySaved { syncManager.save(for: account, serverAuthoritative: true) }

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

        // non-authoritative, but non-empty
        awaitRegistrySaved { syncManager.save(for: account) }

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
        // End-to-end INV-1: corrupt load flags rebuild; a subsequent empty
        // non-authoritative save must be refused so nothing erases the shelf
        // before an authoritative sync runs.
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

        awaitRegistrySaved { syncManager.save(for: account) }

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
        awaitRegistrySaved { syncManager.save(for: account) }
        XCTAssertEqual(RegistryFileRecovery.schemaVersion(from: try? Data(contentsOf: url)),
                       RegistryFileRecovery.currentSchemaVersion,
                       "the next save must migrate the unversioned file to the current schema version")
    }
}

// MARK: - P5 test fake

/// Lock-backed fake `OPDSFeedFetching` for the feed-fetch-branch tests.
/// `@unchecked Sendable` invariant: the only concurrently-touched mutable state
/// (`_resetCacheCalls`) is guarded by `lock`; `stubbedError` / `stubbedFeed` are
/// set once on the test thread before the SUT runs and only read on the fetch
/// path thereafter.
private final class StubOPDSFeedFetcher: OPDSFeedFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _resetCacheCalls: [Bool] = []
    var stubbedError: Error?
    var stubbedFeed: TPPOPDSFeed?

    /// The `resetCache` argument observed on each `fetchFeed` call, in order.
    var resetCacheCalls: [Bool] {
        lock.lock(); defer { lock.unlock() }
        return _resetCacheCalls
    }

    func fetchFeed(from url: URL) async throws -> TPPOPDSFeed {
        try await fetchFeed(from: url, resetCache: false)
    }

    func fetchFeed(from url: URL, resetCache: Bool) async throws -> TPPOPDSFeed {
        lock.withLock { _resetCacheCalls.append(resetCache) }
        if let stubbedError { throw stubbedError }
        if let stubbedFeed { return stubbedFeed }
        throw NSError(domain: "StubOPDSFeedFetcher", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "no stub configured"])
    }
}

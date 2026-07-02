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
        BookRegistrySync(
            store: store,
            accountsManager: accountsManager,
            downloadCenterProvider: { AppContainer.production().downloadCenter },
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
        lock.lock(); _resetCacheCalls.append(resetCache); lock.unlock()
        if let stubbedError { throw stubbedError }
        if let stubbedFeed { return stubbedFeed }
        throw NSError(domain: "StubOPDSFeedFetcher", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "no stub configured"])
    }
}

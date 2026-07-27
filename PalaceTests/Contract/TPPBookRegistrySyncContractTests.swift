//
//  TPPBookRegistrySyncContractTests.swift
//  PalaceTests
//
//  God-class decomposition Wave 2b — the SERVER-SYNC call-order contract for
//  `BookRegistrySync.sync(currentState:setState:completion:)`. Pins the CURRENT
//  ordered effect sequence of a loans-feed sync BEFORE the cluster moves into an
//  SPM package, so the extraction can be proven behavior-neutral: after the move
//  these snapshots must stay green with their assertions untouched.
//
//  WHY a contract snapshot (vs. plain unit tests): `sync()` is a decision tree
//  over enum states that emits an ORDERED sequence of side effects into three
//  injected dependencies. A refactor that reorders them (e.g. saving before the
//  deletion pass, or emitting `.synced` before the feed fetch) is exactly the
//  silent regression class the snapshot pattern was built to catch (see
//  ContractSnapshot.swift header). The cleanly-spyable ordered dependency calls
//  are:
//    · `setState(_:)`            — the RegistryState transition closure sync() drives
//    · `OPDSFeedFetching.fetchFeed(from:resetCache:)` — the loans-feed seam
//    · `LocalBookContentService.deleteLocalContent(forBook:)` — the eviction seam
//      (spied via the same `localContentService` override BookRegistrySync's
//      sideload-exemption suite uses)
//    · `completion(errorDocument:newBooks:)`
//
//  The per-entry merge-vs-fresh registry writes and the authoritative `save(...)`
//  are INTERNAL to `BookRegistrySync` (no dependency call to spy — `save` is a
//  method on a `final` class, and the merge/fresh branch mutates the store's
//  in-memory dict). Those are pinned by explicit assertions on the resulting
//  store state + the on-disk registry file the authoritative save writes.
//  See the header note in TPPBookRegistryFacadeContractTests / the Wave-2b intent
//  for the missing `DownloadCenter` protocol + spyable-save seams the extraction
//  will want to make those steps directly call-order-pinnable.
//
//  VERIFIED sequences (against BookRegistrySync.swift at develop tip 77f6ded53):
//    happy path  : setState(.syncing) → fetchFeed(resetCache:true) →
//                  deleteLocalContent(<evicted book>) → setState(.synced) →
//                  completion(nil, newBooks:true)
//    no creds    : setState(.loaded) → completion(nil,false)  [ZERO fetchFeed]
//    awaitReady✗ : setState(.syncing) → setState(.loaded) →
//                  completion(nil,false)  [ZERO fetchFeed; syncUrl stays nil]
//    empty-feed  : setState(.syncing) → fetchFeed(resetCache:true) →
//    bulk guard    setState(.synced) → completion(nil,false)  [ZERO delete; NO save]
//
//  NOTE — the credentials gate (`!userAccount.hasCredentials()`) sits BEFORE
//  `setState(.syncing)`, so the no-credentials exit emits ONLY `.loaded` (never
//  `.syncing`). This matched the brief's hypothesis. The `.syncing` emission
//  therefore only appears once the account is credentialed — which is why the
//  awaitReady-failure sequence starts `.syncing, .loaded` while the no-creds one
//  is just `.loaded`.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class TPPBookRegistrySyncContractTests: XCTestCase {

    private var store: BookRegistryStore!
    private var accountsManager: AccountsManager!
    private var spyContentService: SpyContentService!
    private var downloadCenter: MyBooksDownloadCenter!
    private var seededRegistryURLs: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = BookRegistryStore()
        let appContainer = makeTestAppContainer()
        accountsManager = appContainer.accountsManager
        spyContentService = SpyContentService(bookRegistry: TPPBookRegistryMock())
        downloadCenter = MyBooksDownloadCenter(
            bookRegistry: TPPBookRegistryMock(),
            localContentService: spyContentService
        )
    }

    override func tearDownWithError() throws {
        // Remove any per-account registry files an authoritative save wrote so a
        // fixture UUID's directory can't leak into another test's disk state.
        for url in seededRegistryURLs {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        seededRegistryURLs.removeAll()
        downloadCenter = nil
        spyContentService = nil
        accountsManager = nil
        store = nil
        try super.tearDownWithError()
    }

    // MARK: - Spies

    /// Recording `OPDSFeedFetching` — records each `fetchFeed` (with the observed
    /// `resetCache`) into the shared sequence log AND returns a stubbed feed /
    /// throws a stubbed error. `@unchecked Sendable`: the mutable call count is
    /// lock-guarded; `stubbedFeed`/`stubbedError` are set on the test thread
    /// before the SUT runs and only read on the fetch path.
    private final class RecordingOPDSFeedFetcher: OPDSFeedFetching, @unchecked Sendable {
        let log: CallLog
        var stubbedFeed: TPPOPDSFeed?
        var stubbedError: Error?
        private let lock = NSLock()
        private var _fetchCount = 0

        init(log: CallLog) { self.log = log }

        var fetchCount: Int { lock.lock(); defer { lock.unlock() }; return _fetchCount }

        func fetchFeed(from url: URL) async throws -> TPPOPDSFeed {
            try await fetchFeed(from: url, resetCache: false)
        }

        func fetchFeed(from url: URL, resetCache: Bool) async throws -> TPPOPDSFeed {
            lock.withLock { _fetchCount += 1 }
            log.record("fetchFeed", args: ["resetCache": resetCache])
            if let stubbedError { throw stubbedError }
            if let stubbedFeed { return stubbedFeed }
            throw NSError(domain: "RecordingOPDSFeedFetcher", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "no stub configured"])
        }
    }

    /// Spies the on-disk delete calls sync()'s eviction pass makes, recording
    /// them into the shared sequence log without touching the filesystem. Mirrors
    /// the `SpyLocalContentService` seam in BookRegistrySyncSideloadExemptionTests
    /// (deleteLocalContent delegates to the overridable `localContentService`).
    private final class SpyContentService: LocalBookContentService {
        var sequenceLog: CallLog?
        private(set) var deletedBookIds: [String] = []

        override func deleteLocalContent(forBook book: TPPBook, account: String? = nil) {
            deletedBookIds.append(book.identifier)
            sequenceLog?.record("deleteLocalContent", args: ["book": book.identifier])
        }

        override func deleteLocalContent(for identifier: String, account: String? = nil) {
            deletedBookIds.append(identifier)
            sequenceLog?.record("deleteLocalContent", args: ["book": identifier])
        }
    }

    // MARK: - Helpers

    private func stateName(_ state: TPPBookRegistry.RegistryState) -> String {
        switch state {
        case .unloaded: return "unloaded"
        case .loading:  return "loading"
        case .loaded:   return "loaded"
        case .syncing:  return "syncing"
        case .synced:   return "synced"
        @unknown default: return "unknown"
        }
    }

    /// A `setState` closure that records the transition into `log` and appends to
    /// `received` for direct assertions.
    private func recordingSetState(
        _ log: CallLog,
        into received: @escaping (TPPBookRegistry.RegistryState) -> Void
    ) -> (TPPBookRegistry.RegistryState) -> Void {
        return { state in
            log.record("setState", args: ["state": self.stateName(state)])
            received(state)
        }
    }

    private func makeBook(identifier: String, title: String) -> TPPBook {
        TPPBook(
            acquisitions: [TPPFake.genericAcquisition],
            authors: nil, categoryStrings: nil, distributor: nil,
            identifier: identifier,
            imageURL: nil, imageThumbnailURL: nil, published: nil, publisher: nil,
            subtitle: nil, summary: nil, title: title, updated: Date(),
            annotationsURL: nil, analyticsURL: nil, alternateURL: nil,
            relatedWorksURL: nil, previewLink: nil, seriesURL: nil,
            revokeURL: nil, reportURL: nil, timeTrackingURL: nil,
            contributors: nil, bookDuration: nil, imageCache: MockImageCache()
        )
    }

    private func seedStore(_ books: [(id: String, state: TPPBookState)]) {
        let done = expectation(description: "seeded")
        done.expectedFulfillmentCount = books.count
        for entry in books {
            store.addBook(makeBook(identifier: entry.id, title: "Seed \(entry.id)"), state: entry.state) { _ in done.fulfill() }
        }
        wait(for: [done], timeout: 5.0)
        drainMainQueue()
    }

    /// Well-formed OPDS acquisition feed with one open-access entry per id.
    private func makeLoansFeed(entryIDs: [String]) -> TPPOPDSFeed {
        let entries = entryIDs.map { id in
            """
            <entry>
              <title type="text">Entry \(id)</title>
              <id>\(id)</id>
              <updated>2026-07-01T00:00:00Z</updated>
              <link href="http://example.com/\(id).epub" type="application/epub+zip" rel="http://opds-spec.org/acquisition/open-access" />
            </entry>
            """
        }.joined(separator: "\n")
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title type="text">Loans</title>
          <id>urn:test:sync-contract-loans</id>
          <updated>2026-07-01T00:00:00Z</updated>
          \(entries)
        </feed>
        """
        return TPPOPDSFeed(xml: TPPXML.xml(withData: Data(xml.utf8))!)!
    }

    /// Seeds a fresh-UUID fixture as the injected manager's `currentAccount`.
    /// Fresh UUID → the production credentials lookup returns a never-signed-in
    /// instance (`hasCredentials() == false`) deterministically.
    private func seedFixtureCurrentAccount() -> (uuid: String, cleanup: () -> Void) {
        let fixtureId = "sync-contract-\(UUID().uuidString)"
        let pub = OPDS2Publication(
            links: [OPDS2Link(href: "https://example.com/catalog",
                              rel: "http://opds-spec.org/catalog")],
            metadata: OPDS2Publication.Metadata(id: fixtureId, title: "Sync Contract Fixture"),
            images: nil
        )
        let fixture = Account(publication: pub, imageCache: MockImageCache())
        let cleanup = accountsManager._seedAccountForTesting(fixture)
        return (fixtureId, cleanup)
    }

    /// AccountDetails whose auth document HAS a shelf link → `loansUrl != nil`.
    private func makeLoansUrlDetails(uuid: String,
                                    loansHref: String = "https://loans.example.com/shelf") -> AccountDetails {
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

    /// Seed a credentialed, shelf-link fixture as currentAccount, driven to a
    /// terminal `.detailsLoaded`. Returns uuid + cleanup (defer-call it).
    private func seedCredentialedLoansAccount() throws -> (uuid: String, cleanup: () -> Void) {
        try KeychainAvailability.skipIfUnavailable()
        let (uuid, seedCleanup) = seedFixtureCurrentAccount()
        // sync() reads credentials via sharedAccount(libraryUUID:) → the
        // production keychain-backed user account; there is no DI seam for the
        // credential path (only currentAccount STATE is injected).
        let prodUserAccount = AppContainer.production().accountsManager.userAccount(for: uuid)
        prodUserAccount.setAuthToken("sync-contract-token", barcode: "bc", pin: "1234",
                                     expirationDate: Date().addingTimeInterval(3600))
        accountsManager.currentAccount?._setState(.detailsLoaded(makeLoansUrlDetails(uuid: uuid)))
        return (uuid, {
            prodUserAccount.removeAll()
            seedCleanup()
        })
    }

    private func makeSyncManager(fetcher: OPDSFeedFetching) -> BookRegistrySync {
        BookRegistrySync(
            store: store,
            accountsManager: accountsManager,
            downloadCenterProvider: { [downloadCenter] in downloadCenter! },
            opdsFeedServiceProvider: { fetcher },
            sideloadedIDsProvider: { [] }
        )
    }

    /// Deterministic join for the authoritative disk write: the save posts
    /// `.TPPBookRegistryDidChange` on main AFTER the bytes land. We fulfill only
    /// once the file actually exists, so the noisier store-mutation posts of the
    /// same notification can't false-satisfy the wait.
    private func awaitFileExists(at url: URL, timeout: TimeInterval = 5.0) {
        if FileManager.default.fileExists(atPath: url.path) { return }
        let exp = expectation(description: "authoritative save wrote \(url.lastPathComponent)")
        exp.assertForOverFulfill = false
        let token = NotificationCenter.default.addObserver(
            forName: .TPPBookRegistryDidChange, object: nil, queue: .main
        ) { _ in
            if FileManager.default.fileExists(atPath: url.path) { exp.fulfill() }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        wait(for: [exp], timeout: timeout)
    }

    // MARK: - 1. Happy path — reconcile (merge + fresh + eviction + authoritative save)

    /// The full server-sync happy path. Pins the ordered dependency-call sequence
    /// AND the reconciliation outcomes that distinguish the two per-entry branches
    /// (a pre-existing record is MERGE-preserved; a feed-only id becomes a FRESH
    /// record) plus the eviction of a downloaded book absent from the feed and the
    /// authoritative save to the syncing account's on-disk registry.
    func testSync_happyPath_reconcilesFeed_evicts_persistsAuthoritative_andSyncs() throws {
        let (uuid, cleanup) = try seedCredentialedLoansAccount()
        defer { cleanup() }

        // Pre-seed: a book that WILL appear in the feed (merge branch, state
        // preserved) + a downloaded book that WON'T (eviction).
        seedStore([(id: "sync-merge-1", state: .downloadSuccessful),
                   (id: "sync-gone-1", state: .downloadSuccessful)])

        let log = CallLog()
        let fetcher = RecordingOPDSFeedFetcher(log: log)
        // Feed carries the merge id + a brand-new id (fresh branch); omits gone-1.
        fetcher.stubbedFeed = makeLoansFeed(entryIDs: ["sync-merge-1", "sync-fresh-1"])
        spyContentService.sequenceLog = log
        let sut = makeSyncManager(fetcher: fetcher)

        let registryURL = sut.registryUrl(for: uuid)!
        seededRegistryURLs.append(registryURL)

        var received: [TPPBookRegistry.RegistryState] = []
        var completionArgs: (errorDoc: [AnyHashable: Any]?, newBooks: Bool)?
        let done = expectation(description: "sync completed")
        sut.sync(currentState: .loaded,
                 setState: recordingSetState(log, into: { received.append($0) })) { errorDoc, newBooks in
            log.record("completion", args: ["newBooks": newBooks, "hasError": errorDoc != nil])
            completionArgs = (errorDoc, newBooks)
            done.fulfill()
        }
        wait(for: [done], timeout: 10.0)

        // --- Ordered dependency-call contract ---
        ContractSnapshot.assert(log, named: "syncHappyPathReconcile")

        // --- Reconciliation outcomes (not expressible as dependency calls) ---
        XCTAssertEqual(received, [.syncing, .synced],
                       "happy path must drive exactly .syncing then .synced — got \(received)")
        XCTAssertEqual(completionArgs?.newBooks, true,
                       "reconciling non-empty feed changes made newBooks must be true")
        XCTAssertNil(completionArgs?.errorDoc)

        // MERGE branch: the pre-existing downloaded record is preserved (state not
        // reset, book still present) — distinct from the fresh branch below.
        XCTAssertEqual(store.state(for: "sync-merge-1"), .downloadSuccessful,
                       "a feed entry that matches an existing record must MERGE-preserve its state")
        // FRESH branch: a feed-only id becomes a new record via deriveInitialState.
        XCTAssertNotNil(store.book(forIdentifier: "sync-fresh-1"),
                        "a feed-only id must be added as a FRESH record")
        // EVICTION: the downloaded book absent from the feed is removed + its
        // on-disk content deleted (recorded in the sequence above).
        XCTAssertNil(store.book(forIdentifier: "sync-gone-1"),
                     "a downloaded book absent from the feed must be evicted")
        XCTAssertEqual(spyContentService.deletedBookIds, ["sync-gone-1"],
                       "exactly the evicted downloaded book's local content is deleted")

        // AUTHORITATIVE save landed in the SYNCING account's registry file.
        awaitFileExists(at: registryURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: registryURL.path),
                      "a changes-made sync must persist an authoritative save to the syncing account's registry.json")
    }

    // MARK: - 2. No-credentials early exit

    /// With a current account whose production user-account has no stored
    /// credentials, sync() takes the credentials gate — setState(.loaded) +
    /// completion(nil,false) — and returns BEFORE touching the feed. Snapshot pins
    /// that the fetcher is NEVER called (fetchFeed absent from the ordered log).
    func testSync_noCredentials_emitsLoadedAndCompletes_withoutFetchingFeed() {
        let (uuid, cleanup) = seedFixtureCurrentAccount()
        defer { cleanup() }

        let prodUserAccount = AppContainer.production().accountsManager.userAccount(for: uuid)
        XCTAssertFalse(prodUserAccount.hasCredentials(),
                       "precondition: fresh-UUID fixture must have no stored credentials")

        let log = CallLog()
        let fetcher = RecordingOPDSFeedFetcher(log: log)
        let sut = makeSyncManager(fetcher: fetcher)

        var received: [TPPBookRegistry.RegistryState] = []
        var completionArgs: (errorDoc: [AnyHashable: Any]?, newBooks: Bool)?
        sut.sync(currentState: .loaded,
                 setState: recordingSetState(log, into: { received.append($0) })) { errorDoc, newBooks in
            log.record("completion", args: ["newBooks": newBooks, "hasError": errorDoc != nil])
            completionArgs = (errorDoc, newBooks)
        }
        // The credentials-gate path is synchronous — no awaiting needed.

        ContractSnapshot.assert(log, named: "syncNoCredentialsEarlyExit")

        XCTAssertEqual(received, [.loaded],
                       "no-credentials sync must emit exactly one setState(.loaded), never .syncing — got \(received)")
        XCTAssertEqual(completionArgs?.newBooks, false)
        XCTAssertNil(completionArgs?.errorDoc)
        XCTAssertEqual(fetcher.fetchCount, 0,
                       "the credentials gate must return BEFORE the loans feed is fetched")
        XCTAssertNil(sut.syncUrl,
                     "syncUrl must never be captured when the credentials gate defers the sync")
    }

    // MARK: - 3. awaitReady failure — revert to .loaded without fetching

    /// Credentialed account whose readiness resolves to a terminal FAILED state:
    /// awaitReady() throws on its fast path, so sync() reverts .syncing → .loaded,
    /// clears syncUrl, and completes with a nil error document — WITHOUT ever
    /// fetching the feed. Distinct from the loans-fetch error path (that one
    /// forwards a non-nil error document).
    func testSync_awaitReadyFailure_revertsToLoaded_withoutFetching() throws {
        try KeychainAvailability.skipIfUnavailable()
        let (uuid, seedCleanup) = seedFixtureCurrentAccount()
        defer { seedCleanup() }

        let prodUserAccount = AppContainer.production().accountsManager.userAccount(for: uuid)
        prodUserAccount.setAuthToken("sync-contract-token", barcode: "bc", pin: "1234",
                                     expirationDate: Date().addingTimeInterval(3600))
        defer { prodUserAccount.removeAll() }

        // Terminal FAILED load state → awaitReady() throws BEFORE the feed fetch.
        accountsManager.currentAccount?._setState(
            .detailsFailed(.authDocumentFetchFailed(underlyingDescription: "wave2b injected")))

        let log = CallLog()
        let fetcher = RecordingOPDSFeedFetcher(log: log)
        let sut = makeSyncManager(fetcher: fetcher)

        var received: [TPPBookRegistry.RegistryState] = []
        var completionArgs: (errorDoc: [AnyHashable: Any]?, newBooks: Bool)?
        let done = expectation(description: "awaitReady failure resolved")
        sut.sync(currentState: .loaded,
                 setState: recordingSetState(log, into: { received.append($0) })) { errorDoc, newBooks in
            log.record("completion", args: ["newBooks": newBooks, "hasError": errorDoc != nil])
            completionArgs = (errorDoc, newBooks)
            done.fulfill()
        }
        wait(for: [done], timeout: 5.0)

        ContractSnapshot.assert(log, named: "syncAwaitReadyFailureRevert")

        XCTAssertEqual(received, [.syncing, .loaded],
                       "awaitReady failure must set .syncing then revert to .loaded — got \(received)")
        XCTAssertEqual(completionArgs?.newBooks, false)
        XCTAssertNil(completionArgs?.errorDoc,
                     "the awaitReady catch resolves with a nil error document (distinct from the loans-fetch error path)")
        XCTAssertEqual(fetcher.fetchCount, 0,
                       "awaitReady failure must abort BEFORE the feed fetch — the fetcher must never be called")
        XCTAssertNil(sut.syncUrl,
                     "syncUrl must be cleared (never left set) when awaitReady aborts the sync")
    }

    // MARK: - 4. Bulk-deletion guard — empty feed, non-empty shelf

    /// An empty loans feed against a non-empty downloaded shelf must SKIP every
    /// deletion (shouldSkipBulkDeletion) — treating the empty response as a
    /// transient server error. Pins that the sequence still fetches + reaches
    /// .synced, but performs ZERO deleteLocalContent and (changesMade == false)
    /// writes NO authoritative save. The boolean is unit-tested directly
    /// elsewhere; this pins the end-to-end no-eviction sequence.
    func testSync_bulkDeletionGuard_emptyFeedNonEmptyShelf_skipsAllDeletions() throws {
        let (uuid, cleanup) = try seedCredentialedLoansAccount()
        defer { cleanup() }

        seedStore([(id: "guard-1", state: .downloadSuccessful),
                   (id: "guard-2", state: .downloadSuccessful)])

        let log = CallLog()
        let fetcher = RecordingOPDSFeedFetcher(log: log)
        fetcher.stubbedFeed = makeLoansFeed(entryIDs: []) // empty feed
        spyContentService.sequenceLog = log
        let sut = makeSyncManager(fetcher: fetcher)

        let registryURL = sut.registryUrl(for: uuid)!
        seededRegistryURLs.append(registryURL)

        var received: [TPPBookRegistry.RegistryState] = []
        var completionArgs: (errorDoc: [AnyHashable: Any]?, newBooks: Bool)?
        let done = expectation(description: "sync completed")
        sut.sync(currentState: .loaded,
                 setState: recordingSetState(log, into: { received.append($0) })) { errorDoc, newBooks in
            log.record("completion", args: ["newBooks": newBooks, "hasError": errorDoc != nil])
            completionArgs = (errorDoc, newBooks)
            done.fulfill()
        }
        wait(for: [done], timeout: 10.0)

        ContractSnapshot.assert(log, named: "syncBulkDeletionGuardEmptyFeed")

        XCTAssertEqual(received, [.syncing, .synced])
        XCTAssertEqual(completionArgs?.newBooks, false,
                       "an empty feed that changed nothing (all deletions skipped) → newBooks false")
        XCTAssertNotNil(store.book(forIdentifier: "guard-1"),
                        "the bulk-deletion guard must preserve every downloaded book on an empty feed")
        XCTAssertNotNil(store.book(forIdentifier: "guard-2"))
        XCTAssertTrue(spyContentService.deletedBookIds.isEmpty,
                      "the guard must perform ZERO on-disk deletions")
        XCTAssertFalse(FileManager.default.fileExists(atPath: registryURL.path),
                       "no changes made → no authoritative save should be written")
    }
}

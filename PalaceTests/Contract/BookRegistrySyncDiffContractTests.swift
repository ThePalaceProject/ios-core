//
//  BookRegistrySyncDiffContractTests.swift
//  PalaceTests
//
//  A loans sync replaces, saves and announces only the records the feed changed
//  (PP-5503). The snapshots pin the main-queue sequence (setState, completion,
//  registry publications) followed by the registry file writes, in order, for
//  the no-change, one-change and one-removal scenarios.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
import PalaceCatalog
import PalaceBookModel
@testable import Palace
@testable import PalaceBookRegistry

@MainActor
final class BookRegistrySyncDiffContractTests: XCTestCase {

    private static let accountID = "pp5503-diff-account"
    private static let loansURL = URL(string: "https://diff-sync-test.example.com/loans")!

    private var tempDirectory: URL!
    private var store: BookRegistryStore!
    private var fetcher: SwappableLoansFeedFetcher!
    private var downloadSpy: DiffDeleteRecordingDownloadService!
    private var writes: WriteStepRecorder!
    private var log: CallLog!
    private var subscriptions = Set<AnyCancellable>()

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookRegistrySyncDiffContractTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        store = BookRegistryStore()
        fetcher = SwappableLoansFeedFetcher()
        downloadSpy = DiffDeleteRecordingDownloadService()
        writes = WriteStepRecorder()
        log = CallLog()
        store.registrySubject.dropFirst()
            .sink { [log] in log?.record("registryPublished", args: ["count": $0.count]) }
            .store(in: &subscriptions)
        store.registryDidChangeSubject
            .sink { [log] in log?.record("registryDidChange") }
            .store(in: &subscriptions)
    }

    override func tearDown() {
        subscriptions.removeAll()
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
        store = nil
        fetcher = nil
        downloadSpy = nil
        writes = nil
        log = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private struct Entry {
        var id: String
        var title: String = "Title"
        var updated: String = "2026-07-01T00:00:00Z"
        var until: String = "2026-08-01T00:00:00Z"
        var author: String?
        var summary: String?
    }

    private static func feed(_ entries: [Entry]) -> TPPOPDSFeed {
        let body = entries.map { entry in
            let author = entry.author.map { "<author><name>\($0)</name></author>" } ?? ""
            let summary = entry.summary.map { "<summary type=\"text\">\($0)</summary>" } ?? ""
            return """
            <entry>
              <title type="text">\(entry.title)</title>
              <id>\(entry.id)</id>
              <updated>\(entry.updated)</updated>
              \(author)
              \(summary)
              <link href="http://example.com/\(entry.id).epub" type="application/epub+zip" rel="http://opds-spec.org/acquisition">
                <opds:availability status="available" since="2026-07-01T00:00:00Z" until="\(entry.until)"/>
              </link>
            </entry>
            """
        }.joined(separator: "\n")
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:opds="http://opds-spec.org/2010/catalog">
          <title type="text">Loans</title>
          <id>urn:test:pp5503-loans</id>
          <updated>2026-07-01T00:00:00Z</updated>
          \(body)
        </feed>
        """
        guard let parsed = TPPXML.xml(withData: Data(xml.utf8)), let feed = TPPOPDSFeed(xml: parsed) else {
            fatalError("loans fixture did not parse")
        }
        return feed
    }

    private func makeSync() -> BookRegistrySync {
        let spy = downloadSpy!
        let fetcher = self.fetcher!
        let directory = tempDirectory!
        let writes = self.writes!
        return BookRegistrySync(
            store: store,
            accountScope: DiffLoansAccountScope(accountID: Self.accountID, loansURL: Self.loansURL),
            dependencies: RegistryExternalDependencies(
                downloadService: { spy },
                loansFeedFetcher: { fetcher },
                sideloadedIdentifiers: { [] },
                registryDirectory: { _ in directory },
                onAvailabilityChange: { _, _ in },
                beforeRegistryWrite: { step, _ in writes.record(step) }
            )
        )
    }

    /// Runs one sync to completion and drains every queue it posts to: the store
    /// barrier, the disk-write queue, and the main-queue publications behind it.
    @discardableResult
    private func runSync(_ sut: BookRegistrySync, feed: TPPOPDSFeed) async -> Bool {
        fetcher.feed = feed
        var newBooks: Bool?
        sut.sync(currentState: .loaded,
                 setState: { [log] state in log?.record("setState", args: ["state": "\(state)"]) },
                 completion: { [log] errorDoc, changed in
                     log?.record("completion", args: ["newBooks": changed, "hasError": errorDoc != nil])
                     newBooks = changed
                 })
        await sut._awaitSyncTasksForTesting()
        await store._awaitPendingWritesForTesting()
        await sut._awaitPendingDiskWritesForTesting()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { cont.resume() }
        }
        XCTAssertNotNil(newBooks, "sync() must call its completion")
        return newBooks ?? false
    }

    /// Seeds the shelf through a first sync, then clears every recorder so the
    /// test observes only the second sync.
    private func seedBySync(_ sut: BookRegistrySync, _ entries: [Entry]) async {
        await runSync(sut, feed: Self.feed(entries))
        log.reset()
        writes.reset()
    }

    /// The main-queue sequence, then the registry file writes in order.
    private func assertSnapshot(named name: String) {
        for step in writes.steps {
            log.record("registryWrite", args: ["step": step])
        }
        ContractSnapshot.assert(log, named: name)
    }

    private func records() -> [String: TPPBookRegistryRecord] {
        store.readRegistry { $0 }
    }

    private let shelf = [Entry(id: "book-a", author: "Author A", summary: "Summary A"),
                         Entry(id: "book-b", author: "Author B", summary: "Summary B"),
                         Entry(id: "book-c", author: "Author C", summary: "Summary C")]

    // MARK: - No change

    /// An identical feed must not rebuild, save or announce anything: it runs
    /// after every token refresh, including while the phone is locked.
    func testSync_WhenFeedIsUnchanged_KeepsRecordsAndNeitherSavesNorAnnounces() async {
        let sut = makeSync()
        await seedBySync(sut, shelf)
        let before = records()

        let newBooks = await runSync(sut, feed: Self.feed(shelf))

        let after = records()
        XCTAssertEqual(Set(after.keys), Set(before.keys))
        for (id, record) in before {
            XCTAssertTrue(after[id] === record, "unchanged record \(id) must keep its instance")
        }
        XCTAssertEqual(writes.steps, [], "an unchanged sync must not write the registry file")
        XCTAssertFalse(newBooks, "an unchanged sync reports no changes")
        XCTAssertFalse(log.snapshot().contains { $0.method == "registryDidChange" || $0.method == "registryPublished" },
                       "an unchanged sync must not announce a registry change")
        assertSnapshot(named: "syncDiffNoChange")
    }

    // MARK: - One change

    /// A new due date replaces exactly that record and saves once; the others
    /// keep their instances.
    func testSync_WhenOneDueDateChanges_ReplacesOnlyThatRecordAndSavesOnce() async {
        let sut = makeSync()
        await seedBySync(sut, shelf)
        let before = records()
        var changed = shelf
        changed[1].until = "2026-09-15T00:00:00Z"

        let newBooks = await runSync(sut, feed: Self.feed(changed))

        let after = records()
        XCTAssertTrue(after["book-a"] === before["book-a"])
        XCTAssertFalse(after["book-b"] === before["book-b"], "the changed record must be replaced")
        XCTAssertTrue(after["book-c"] === before["book-c"])
        let until = after["book-b"]?.book.defaultAcquisition?.availability.until
        XCTAssertEqual(until, NSDate.date(withRFC3339String: "2026-09-15T00:00:00Z") as Date?)
        XCTAssertEqual(writes.steps.filter { $0 == "primary" }.count, 1, "exactly one registry save")
        XCTAssertTrue(newBooks)
        assertSnapshot(named: "syncDiffOneChange")
    }

    // MARK: - One removal

    /// A book the feed no longer lists is removed and the shelf is saved; the
    /// remaining records keep their instances.
    func testSync_WhenOneBookIsRemoved_RemovesItAndSaves() async {
        let sut = makeSync()
        await seedBySync(sut, shelf)
        let before = records()

        let newBooks = await runSync(sut, feed: Self.feed(Array(shelf.prefix(2))))

        let after = records()
        XCTAssertNil(after["book-c"])
        XCTAssertTrue(after["book-a"] === before["book-a"])
        XCTAssertTrue(after["book-b"] === before["book-b"])
        XCTAssertEqual(writes.steps.filter { $0 == "primary" }.count, 1)
        XCTAssertTrue(newBooks)
        assertSnapshot(named: "syncDiffOneRemoval")
    }

    // MARK: - New book

    func testSync_WhenFeedAddsABook_AddsItAndSaves() async {
        let sut = makeSync()
        await seedBySync(sut, shelf)
        let before = records()

        let newBooks = await runSync(sut, feed: Self.feed(shelf + [Entry(id: "book-d")]))

        let after = records()
        XCTAssertNotNil(after["book-d"])
        XCTAssertEqual(after["book-d"]?.state, .downloadNeeded)
        XCTAssertTrue(after["book-a"] === before["book-a"])
        XCTAssertEqual(writes.steps.filter { $0 == "primary" }.count, 1)
        XCTAssertTrue(newBooks)
    }

    // MARK: - Lean entries (metadata preservation)

    /// A lean entry (no author or summary) for an otherwise unchanged book merges
    /// to the stored record, so nothing is replaced or saved and the metadata stays.
    func testSync_WhenEntryComesBackLean_KeepsMetadataWithoutSaving() async {
        let sut = makeSync()
        await seedBySync(sut, shelf)
        let before = records()
        var lean = shelf
        lean[0].author = nil
        lean[0].summary = nil

        await runSync(sut, feed: Self.feed(lean))

        let after = records()
        XCTAssertTrue(after["book-a"] === before["book-a"])
        XCTAssertEqual(after["book-a"]?.book.authors, "Author A")
        XCTAssertEqual(after["book-a"]?.book.summary, "Summary A")
        XCTAssertEqual(writes.steps, [])
    }

    /// A lean entry that also carries a real change replaces the record but keeps
    /// the stored metadata.
    func testSync_WhenLeanEntryAlsoChanges_ReplacesRecordAndKeepsMetadata() async {
        let sut = makeSync()
        await seedBySync(sut, shelf)
        let before = records()
        var lean = shelf
        lean[0].author = nil
        lean[0].summary = nil
        lean[0].until = "2026-10-01T00:00:00Z"

        await runSync(sut, feed: Self.feed(lean))

        let after = records()
        XCTAssertFalse(after["book-a"] === before["book-a"])
        XCTAssertEqual(after["book-a"]?.book.authors, "Author A")
        XCTAssertEqual(after["book-a"]?.book.summary, "Summary A")
        XCTAssertEqual(writes.steps.filter { $0 == "primary" }.count, 1)
    }

    /// A replaced record keeps its local fields: reading position and fulfillment id.
    func testSync_WhenRecordIsReplaced_KeepsLocationAndFulfillmentId() async {
        let sut = makeSync()
        await seedBySync(sut, shelf)
        store.mutateRegistrySync { registry in
            registry["book-b"]?.fulfillmentId = "fulfillment-b"
            registry["book-b"]?.location = TPPBookLocation(locationString: "{\"page\":3}", renderer: "test")
        }
        var changed = shelf
        changed[1].until = "2026-09-15T00:00:00Z"

        await runSync(sut, feed: Self.feed(changed))

        let record = records()["book-b"]
        XCTAssertEqual(record?.fulfillmentId, "fulfillment-b")
        XCTAssertEqual(record?.location?.locationString, "{\"page\":3}")
    }

    // MARK: - Rebuild flag

    /// After a corrupt load the next authoritative sync must still persist and
    /// clear the rebuild flag, even when the feed matches the in-memory shelf.
    func testSync_WhenRebuildPendingAndFeedUnchanged_SavesAndClearsTheFlag() async {
        let sut = makeSync()
        await seedBySync(sut, shelf)
        sut.needsRebuildFromServer = true

        await runSync(sut, feed: Self.feed(shelf))

        XCTAssertFalse(sut.needsRebuildFromServer)
        XCTAssertEqual(writes.steps.filter { $0 == "primary" }.count, 1)
    }

    /// An empty feed changes nothing and, as before, does not clear the flag.
    func testSync_WhenRebuildPendingAndFeedEmpty_LeavesTheFlagSet() async {
        let sut = makeSync()
        await seedBySync(sut, shelf)
        sut.needsRebuildFromServer = true

        await runSync(sut, feed: Self.feed([]))

        XCTAssertTrue(sut.needsRebuildFromServer)
        XCTAssertEqual(writes.steps, [])
    }

    // MARK: - Record comparison

    /// Duration and contributors are not persisted, so the comparison checks them
    /// beside the persisted form.
    func testRecordsMatch_ComparesFieldsOutsideThePersistedForm() {
        let book = TPPBookMocker.mockBook(identifier: "cmp", title: "Compare", distributorType: .EpubZip)
        let record = TPPBookRegistryRecord(book: book, state: .downloadNeeded)
        let same = TPPBookRegistryRecord(book: book.mergingPreservingMetadata(from: book), state: .downloadNeeded)
        XCTAssertTrue(BookRegistrySync.recordsMatch(record, same))

        let otherState = TPPBookRegistryRecord(book: book, state: .holding)
        XCTAssertFalse(BookRegistrySync.recordsMatch(record, otherState))

        let withDuration = book.mergingPreservingMetadata(from: book)
        withDuration.bookDuration = "3600"
        XCTAssertFalse(BookRegistrySync.recordsMatch(record, TPPBookRegistryRecord(book: withDuration, state: .downloadNeeded)))

        let withContributors = book.mergingPreservingMetadata(from: book)
        withContributors.contributors = ["nrt": ["Narrator"]]
        XCTAssertFalse(BookRegistrySync.recordsMatch(record, TPPBookRegistryRecord(book: withContributors, state: .downloadNeeded)))
    }
}

// MARK: - Test doubles

private final class DiffLoansAccountScope: AccountScopeProviding, @unchecked Sendable {
    let accountID: String?
    let loansURL: URL
    init(accountID: String?, loansURL: URL) {
        self.accountID = accountID
        self.loansURL = loansURL
    }

    var currentAccountID: String? { accountID }
    var accountDidChangePublisher: AnyPublisher<Void, Never> {
        Empty<Void, Never>(completeImmediately: false).eraseToAnyPublisher()
    }
    func hasCredentials(forAccount accountID: String) -> Bool { true }
    func loansURL(forAccount accountID: String, readinessTimeout: TimeInterval) async throws -> URL? { loansURL }
}

/// `@unchecked Sendable` invariant: `feed` is set on the test's main actor
/// before each sync starts and only read during that sync's fetch.
private final class SwappableLoansFeedFetcher: OPDSFeedFetching, @unchecked Sendable {
    var feed: TPPOPDSFeed?
    func fetchFeed(from url: URL) async throws -> TPPOPDSFeed {
        try await fetchFeed(from: url, resetCache: true)
    }
    func fetchFeed(from url: URL, resetCache: Bool) async throws -> TPPOPDSFeed {
        guard let feed else { throw NSError(domain: "SwappableLoansFeedFetcher", code: -1) }
        return feed
    }
}

/// `@unchecked Sendable` invariant: `_steps` is read and written only under `lock`.
private final class WriteStepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _steps: [String] = []
    var steps: [String] { lock.withLock { _steps } }
    func record(_ step: RegistryWriteStep) {
        let name: String
        switch step {
        case .backupStaging: name = "backupStaging"
        case .backupReplace: name = "backupReplace"
        case .primary: name = "primary"
        }
        lock.withLock { _steps.append(name) }
    }
    func reset() { lock.withLock { _steps.removeAll() } }
}

/// `@unchecked Sendable` invariant: `_deleted` is read and written only under `lock`.
private final class DiffDeleteRecordingDownloadService: RegistryDownloadServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var _deleted: [String] = []
    var deletedIdentifiers: [String] { lock.withLock { _deleted } }

    func fileUrl(for book: TPPBook, account: String?) -> URL? { nil }
    func startDownload(for book: TPPBook) {}
    func deleteLocalContent(forBook book: TPPBook, account: String?) {
        lock.withLock { _deleted.append(book.identifier) }
    }
    func redownloadLCPContentFile(for book: TPPBook) {}
    func contentFileSatisfied(for book: TPPBook, account: String) -> Bool { false }
    func lcpContentFileMissing(for book: TPPBook, account: String) -> Bool { false }
    func contentPresence(for book: TPPBook, account: String) -> RegistryContentPresence { .absent }
    func isDownloadInFlight(for book: TPPBook) -> Bool { false }
}

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
        var status: String = "available"
        var author: String?
        var summary: String?
    }

    /// Each loan carries `opds:copies`: without it the parser reads the loan as
    /// unlimited and drops `until`, so a due-date change would not reach the record.
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
                <opds:availability status="\(entry.status)" since="2026-07-01T00:00:00Z" until="\(entry.until)"/>
                <opds:copies available="1" total="1"/>
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

    private func makeSync(afterLoansFeedCompared: @escaping @Sendable () -> Void = {}) -> BookRegistrySync {
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
                beforeRegistryWrite: { step, _ in writes.record(step) },
                afterLoansFeedCompared: afterLoansFeedCompared
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

    // MARK: - Relaunch

    private var registryURL: URL {
        tempDirectory.appendingPathComponent("registry").appendingPathComponent("registry.json")
    }

    /// A cold launch: a new store and engine that read the shelf back from disk.
    private func relaunchAndLoad() async -> BookRegistrySync {
        store = BookRegistryStore()
        let sut = makeSync()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sut.load(account: Self.accountID, setState: { _ in }, completion: { cont.resume() })
        }
        writes.reset()
        return sut
    }

    /// The persisted form of a ready hold has no dates, so after a relaunch the
    /// first sync must restore the pickup deadline the Holds list shows.
    func testSync_AfterRelaunchWithReadyHold_RestoresThePickupDeadline() async {
        let deadline = "2026-08-20T00:00:00Z"
        let readyHold = [Entry(id: "hold-a", until: deadline, status: "ready")]
        await seedBySync(makeSync(), readyHold)
        let sut = await relaunchAndLoad()
        XCTAssertNil(records()["hold-a"]?.book.getExpirationDate(), "precondition: the disk form drops the deadline")

        await runSync(sut, feed: Self.feed(readyHold))

        XCTAssertEqual(records()["hold-a"]?.book.getExpirationDate(),
                       NSDate.date(withRFC3339String: deadline) as Date?)
    }

    /// A corrupt primary recovered from `.bak` is only copied aside, so an
    /// unchanged first sync must rewrite it; otherwise every launch quarantines again.
    func testSync_AfterRecoveryFromBackup_UnchangedSyncRewritesThePrimary() async throws {
        await seedBySync(makeSync(), shelf)
        let backupURL = RegistryFileRecovery.backupURL(for: registryURL)
        let backup = try Data(contentsOf: registryURL)
        try backup.write(to: backupURL)
        try Data("{not json".utf8).write(to: registryURL)
        let sut = await relaunchAndLoad()
        XCTAssertEqual(records().count, 3, "precondition: the shelf is recovered from the backup")

        await runSync(sut, feed: Self.feed(shelf))

        let primary = try Data(contentsOf: registryURL)
        guard case .valid(let saved) = RegistryFileRecovery.classify(data: primary) else {
            return XCTFail("the primary must be valid after the first sync")
        }
        XCTAssertEqual(saved.count, 3)
        XCTAssertEqual(writes.steps.filter { $0 == "primary" }.count, 1)
    }

    /// A legacy file with no schema version is migrated by the first sync even
    /// when the feed matches the shelf.
    func testSync_AfterLoadingLegacyFile_UnchangedSyncWritesTheCurrentSchema() async throws {
        await seedBySync(makeSync(), shelf)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: registryURL)) as? [String: Any])
        json.removeValue(forKey: RegistryFileRecovery.schemaVersionKey)
        try JSONSerialization.data(withJSONObject: json).write(to: registryURL)
        let sut = await relaunchAndLoad()

        await runSync(sut, feed: Self.feed(shelf))

        let primary = try Data(contentsOf: registryURL)
        XCTAssertEqual(RegistryFileRecovery.schemaVersion(from: primary), RegistryFileRecovery.currentSchemaVersion)
    }

    /// Once the primary has been rewritten, a later unchanged sync writes nothing.
    func testSync_AfterRecoveredPrimaryIsRewritten_NextUnchangedSyncWritesNothing() async throws {
        await seedBySync(makeSync(), shelf)
        try Data(contentsOf: registryURL).write(to: RegistryFileRecovery.backupURL(for: registryURL))
        try Data("{not json".utf8).write(to: registryURL)
        let sut = await relaunchAndLoad()
        await runSync(sut, feed: Self.feed(shelf))
        writes.reset()

        await runSync(sut, feed: Self.feed(shelf))

        XCTAssertEqual(writes.steps, [])
    }

    // MARK: - Comparison off the main thread

    /// The feed is compared with the shelf before the sync returns to the main
    /// thread, and the main thread uses that result, so a large shelf does not
    /// hold up the UI.
    func testSync_ComparesTheFeedOffTheMainThread() async {
        let threads = ThreadRecorder()
        let sut = makeSync(afterLoansFeedCompared: { threads.record(Thread.isMainThread) })

        await seedBySync(sut, shelf)
        let comparedBefore = sut.mainThreadComparisonCount

        await runSync(sut, feed: Self.feed(shelf))

        XCTAssertEqual(threads.values, [false, false], "the comparison step must run once per sync, off the main thread")
        XCTAssertEqual(sut.mainThreadComparisonCount, comparedBefore,
                       "with no write after the comparison, the main thread must not compare again")
    }

    /// A state written after the comparison (an async store write) is newer
    /// than the feed, so the sync keeps it instead of the compared result.
    func testSync_WhenStateIsSetAfterTheComparison_KeepsTheLocalState() async {
        let store = self.store!
        let seed = makeSync()
        await seedBySync(seed, shelf)
        let sut = makeSync(afterLoansFeedCompared: {
            store.setState(.downloadSuccessful, for: "book-b")
        })
        var changed = shelf
        changed[1].until = "2026-09-15T00:00:00Z"

        await runSync(sut, feed: Self.feed(changed))

        XCTAssertEqual(sut.mainThreadComparisonCount, shelf.count,
                       "a write after the comparison makes the main thread compare every entry again")
        let record = records()["book-b"]
        XCTAssertEqual(record?.state, .downloadSuccessful, "a local state newer than the feed must be kept")
        XCTAssertEqual(record?.book.defaultAcquisition?.availability.until,
                       NSDate.date(withRFC3339String: "2026-09-15T00:00:00Z") as Date?)
    }

    /// The same rule for a synchronous in-place write.
    func testSync_WhenRecordIsChangedInPlaceAfterTheComparison_KeepsTheLocalState() async {
        let store = self.store!
        let seed = makeSync()
        await seedBySync(seed, shelf)
        let sut = makeSync(afterLoansFeedCompared: {
            store.mutateRegistrySync { $0["book-b"]?.state = .downloadSuccessful }
        })
        var changed = shelf
        changed[1].until = "2026-09-15T00:00:00Z"

        await runSync(sut, feed: Self.feed(changed))

        XCTAssertEqual(records()["book-b"]?.state, .downloadSuccessful)
    }

    /// A feed that lists one book twice ends with the last entry, as each entry
    /// is applied to the record the previous entry left.
    func testSync_WhenFeedListsABookTwice_TheLastEntryWins() async {
        let sut = makeSync()
        await seedBySync(sut, shelf)
        var first = shelf[1]
        first.until = "2026-09-15T00:00:00Z"

        let comparedBefore = sut.mainThreadComparisonCount

        await runSync(sut, feed: Self.feed([shelf[0], first, shelf[1], shelf[2]]))

        XCTAssertEqual(sut.mainThreadComparisonCount - comparedBefore, 1,
                       "only the second entry, whose record the first entry replaced, is compared again")
        XCTAssertEqual(records()["book-b"]?.book.defaultAcquisition?.availability.until,
                       NSDate.date(withRFC3339String: shelf[1].until) as Date?)
    }

    // MARK: - Record comparison

    /// A ready hold read back from disk has no deadline; it must not match the
    /// feed record that carries one, or the sync keeps the dateless record.
    func testRecordsMatch_WhenReadyHoldWasReadFromDisk_DoesNotMatchTheFeedDeadline() throws {
        let until = try XCTUnwrap(NSDate.date(withRFC3339String: "2026-08-20T00:00:00Z") as Date?)
        let book = TPPBookMocker.mockBook(identifier: "ready", title: "Ready", distributorType: .EpubZip)
        let acquisition = try XCTUnwrap(book.defaultAcquisition)
        let ready = TPPOPDSAcquisition(
            relation: acquisition.relation,
            type: acquisition.type,
            hrefURL: acquisition.hrefURL,
            indirectAcquisitions: acquisition.indirectAcquisitions,
            availability: TPPOPDSAcquisitionAvailabilityReady(since: nil, until: until)
        )
        let feedBook = book.mergingPreservingMetadata(from: book)
        feedBook.acquisitions = [ready]
        let feedRecord = TPPBookRegistryRecord(book: feedBook, state: .holding)
        let fromDisk = try XCTUnwrap(TPPBook(dictionary: feedBook.dictionaryRepresentation()))
        XCTAssertNil(fromDisk.getExpirationDate(), "precondition: the disk form drops the deadline")

        XCTAssertFalse(BookRegistrySync.recordsMatch(TPPBookRegistryRecord(book: fromDisk, state: .holding), feedRecord))
    }

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

private final class ThreadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Bool] = []
    func record(_ isMain: Bool) { lock.withLock { recorded.append(isMain) } }
    var values: [Bool] { lock.withLock { recorded } }
}

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

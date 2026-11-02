//
//  LoansFeedUnparsedEntryTests.swift
//  PalaceTests
//
//  Loans-feed reconciliation when the feed holds an entry the OPDS parser
//  rejects (PP-5452). Both sync paths, `BookRegistrySync.sync` and
//  `TPPBookRegistry.syncAsync` (run after every Return), must keep a loan
//  the server still lists, and must not remove books on an empty feed.
//

import XCTest
import Combine
import PalaceCatalog
@testable import Palace
import PalaceBookModel
@_spi(Testing) @testable import PalaceBookRegistry

@MainActor
final class LoansFeedUnparsedEntryTests: XCTestCase {

    private static let accountID = "pp5452-loans-account"
    private static let loansURL = URL(string: "https://unparsed-entry-test.example.com/loans")!

    private var tempDirectory: URL!
    private var downloadSpy: DeleteRecordingDownloadService!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoansFeedUnparsedEntryTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        downloadSpy = DeleteRecordingDownloadService()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
        downloadSpy = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private static func entryXML(id: String?, updated: String = "2026-07-01T00:00:00Z") -> String {
        let idElement = id.map { "<id>\($0)</id>" } ?? ""
        return """
        <entry>
          <title type="text">Book \(id ?? "without id")</title>
          \(idElement)
          <updated>\(updated)</updated>
          <link href="http://example.com/\(UUID().uuidString).epub" type="application/epub+zip" rel="http://opds-spec.org/acquisition/open-access" />
        </entry>
        """
    }

    private static func feed(_ entries: [String]) -> TPPOPDSFeed {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title type="text">Loans</title>
          <id>urn:test:loans</id>
          <updated>2026-07-01T00:00:00Z</updated>
          \(entries.joined(separator: "\n"))
        </feed>
        """
        guard let parsed = TPPXML.xml(withData: Data(xml.utf8)), let feed = TPPOPDSFeed(xml: parsed) else {
            fatalError("loans fixture did not parse")
        }
        return feed
    }

    /// An entry whose `updated` is not RFC 3339, so `TPPOPDSEntry(xml:)` rejects it.
    private static func unparsableEntry(id: String?) -> String {
        entryXML(id: id, updated: "2026-07-01")
    }

    private func makeBook(_ identifier: String) -> TPPBook {
        TPPBookMocker.mockBook(identifier: identifier, title: "Book \(identifier)", distributorType: .EpubZip)
    }

    private func makeDependencies(feed: TPPOPDSFeed, sideloaded: Set<String> = []) -> RegistryExternalDependencies {
        let spy = downloadSpy!
        let fetcher = StaticLoansFeedFetcher(feed: feed)
        let directory = tempDirectory!
        return RegistryExternalDependencies(
            downloadService: { spy },
            loansFeedFetcher: { fetcher },
            sideloadedIdentifiers: { sideloaded },
            registryDirectory: { _ in directory },
            onAvailabilityChange: { _, _ in }
        )
    }

    // MARK: - BookRegistrySync.sync

    private func runSync(
        feed: TPPOPDSFeed,
        held: [String],
        heldState: TPPBookState = .downloadSuccessful,
        sideloaded: Set<String> = []
    ) async -> BookRegistryStore {
        let store = BookRegistryStore()
        for id in held {
            store.addBook(makeBook(id), state: heldState)
        }
        await store._awaitPendingWritesForTesting()

        let sync = BookRegistrySync(
            store: store,
            accountScope: LoansAccountScope(accountID: Self.accountID, loansURL: Self.loansURL),
            dependencies: makeDependencies(feed: feed, sideloaded: sideloaded)
        )
        var states: [TPPBookRegistry.RegistryState] = []
        var completed = false
        sync.sync(currentState: .loaded, setState: { states.append($0) }, completion: { _, _ in completed = true })
        await sync._awaitSyncTasksForTesting()
        XCTAssertTrue(completed, "sync() must call its completion")
        XCTAssertEqual(states.last, .synced, "sync() must reach reconciliation; got \(states)")
        await store._awaitPendingWritesForTesting()
        return store
    }

    /// A held loan whose feed entry fails to parse keeps its record and content.
    func testSync_WhenHeldLoanEntryFailsToParse_KeepsRecordAndContent() async {
        let feed = Self.feed([Self.entryXML(id: "feed-only"), Self.unparsableEntry(id: "live-loan")])

        let store = await runSync(feed: feed, held: ["live-loan"])

        XCTAssertNotNil(store.book(forIdentifier: "live-loan"))
        XCTAssertFalse(downloadSpy.deletedIdentifiers.contains("live-loan"))
    }

    /// Only the unparsed entry's book is protected; a book absent from the feed is still removed.
    func testSync_WhenUnparsedEntryIsIdentified_StillRemovesBookAbsentFromFeed() async {
        let feed = Self.feed([Self.entryXML(id: "feed-only"), Self.unparsableEntry(id: "live-loan")])

        let store = await runSync(feed: feed, held: ["live-loan", "returned"])

        XCTAssertNotNil(store.book(forIdentifier: "live-loan"))
        XCTAssertNil(store.book(forIdentifier: "returned"))
        XCTAssertEqual(downloadSpy.deletedIdentifiers, ["returned"])
    }

    /// An unparsed entry with no readable id could be any held book, so the sync removes nothing.
    func testSync_WhenUnparsedEntryHasNoIdentifier_RemovesNothing() async {
        let feed = Self.feed([Self.entryXML(id: "feed-only"), Self.unparsableEntry(id: nil)])

        let store = await runSync(feed: feed, held: ["held-a", "held-b"])

        XCTAssertNotNil(store.book(forIdentifier: "held-a"))
        XCTAssertNotNil(store.book(forIdentifier: "held-b"))
        XCTAssertEqual(downloadSpy.deletedIdentifiers, [])
        XCTAssertNotNil(store.book(forIdentifier: "feed-only"), "parsed entries are still merged")
    }

    /// A feed whose only entry failed to parse is not an empty feed: absent books are still removed.
    func testSync_WhenOnlyEntryIsUnparsedButIdentified_RemovesBookAbsentFromFeed() async {
        let feed = Self.feed([Self.unparsableEntry(id: "live-loan")])

        let store = await runSync(feed: feed, held: ["live-loan", "returned"])

        XCTAssertNotNil(store.book(forIdentifier: "live-loan"))
        XCTAssertNil(store.book(forIdentifier: "returned"))
        XCTAssertEqual(downloadSpy.deletedIdentifiers, ["returned"])
    }

    /// A well-formed feed that no longer lists a book removes it and deletes its content.
    func testSync_WhenWellFormedFeedOmitsBook_RemovesRecordAndContent() async {
        let feed = Self.feed([Self.entryXML(id: "feed-only")])

        let store = await runSync(feed: feed, held: ["returned"])

        XCTAssertNil(store.book(forIdentifier: "returned"))
        XCTAssertEqual(downloadSpy.deletedIdentifiers, ["returned"])
    }

    /// A returned book that was never downloaded loses its record but has no content to delete.
    func testSync_WhenWellFormedFeedOmitsUndownloadedBook_RemovesRecordWithoutDeletingContent() async {
        let feed = Self.feed([Self.entryXML(id: "feed-only")])

        let store = await runSync(feed: feed, held: ["returned"], heldState: .downloadNeeded)

        XCTAssertNil(store.book(forIdentifier: "returned"))
        XCTAssertEqual(downloadSpy.deletedIdentifiers, [])
    }

    // MARK: - TPPBookRegistry.processLoansSync (syncAsync)

    private func runProcessLoansSync(
        feed: TPPOPDSFeed,
        held: [String],
        sideloaded: Set<String> = []
    ) async -> (registry: TPPBookRegistry, deleted: [String]) {
        // No current account: the facade's mutations skip their disk saves.
        let registry = TPPBookRegistry(
            accountScope: LoansAccountScope(accountID: nil, loansURL: Self.loansURL),
            imageLoader: MockImageLoader(),
            dependencies: makeDependencies(feed: feed, sideloaded: sideloaded)
        )
        for id in held {
            registry.addBook(makeBook(id), state: .downloadSuccessful)
        }
        await registry._awaitPendingWritesForTesting()

        var deleted: [String] = []
        _ = await registry.processLoansSync(
            feed: feed,
            sideloadedIdentifiers: sideloaded,
            deleteLocalContent: { deleted.append($0) }
        )
        await registry._awaitPendingWritesForTesting()
        return (registry, deleted)
    }

    /// An empty loans feed after a Return keeps the shelf instead of deleting every book.
    func testProcessLoansSync_WhenFeedIsEmpty_KeepsBooks() async {
        let result = await runProcessLoansSync(feed: Self.feed([]), held: ["held-a", "held-b"])

        XCTAssertNotNil(result.registry.book(forIdentifier: "held-a"))
        XCTAssertNotNil(result.registry.book(forIdentifier: "held-b"))
        XCTAssertEqual(result.deleted, [])
    }

    /// A sideloaded book never appears in the loans feed and survives the post-Return sync.
    func testProcessLoansSync_WhenBookIsSideloaded_KeepsIt() async {
        let feed = Self.feed([Self.entryXML(id: "feed-only")])

        let result = await runProcessLoansSync(feed: feed, held: ["sideloaded", "returned"], sideloaded: ["sideloaded"])

        XCTAssertNotNil(result.registry.book(forIdentifier: "sideloaded"))
        XCTAssertNil(result.registry.book(forIdentifier: "returned"))
        XCTAssertEqual(result.deleted, ["returned"])
    }

    /// The post-Return sync applies the same unparsed-entry rule as the main sync.
    func testProcessLoansSync_WhenHeldLoanEntryFailsToParse_KeepsRecordAndContent() async {
        let feed = Self.feed([Self.entryXML(id: "feed-only"), Self.unparsableEntry(id: "live-loan")])

        let result = await runProcessLoansSync(feed: feed, held: ["live-loan", "returned"])

        XCTAssertNotNil(result.registry.book(forIdentifier: "live-loan"))
        XCTAssertNil(result.registry.book(forIdentifier: "returned"))
        XCTAssertEqual(result.deleted, ["returned"])
    }

    /// An unidentifiable unparsed entry stops the post-Return sync from removing anything.
    func testProcessLoansSync_WhenUnparsedEntryHasNoIdentifier_RemovesNothing() async {
        let feed = Self.feed([Self.entryXML(id: "feed-only"), Self.unparsableEntry(id: nil)])

        let result = await runProcessLoansSync(feed: feed, held: ["held-a"])

        XCTAssertNotNil(result.registry.book(forIdentifier: "held-a"))
        XCTAssertEqual(result.deleted, [])
    }

    // MARK: - TPPOPDSFeed

    /// The feed reports each rejected entry, with its id when the entry has one.
    func testFeed_WhenEntriesFailToParse_ReportsTheirIdentifiers() {
        let feed = Self.feed([
            Self.entryXML(id: "ok"),
            Self.unparsableEntry(id: "bad-date"),
            Self.unparsableEntry(id: nil)
        ])

        XCTAssertEqual(feed.entries.count, 1)
        XCTAssertEqual(feed.unparsedEntryIdentifiers, ["bad-date", nil])
    }
}

// MARK: - Test doubles

/// Reports one library with credentials and a fixed loans URL.
private final class LoansAccountScope: AccountScopeProviding, @unchecked Sendable {
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

private final class StaticLoansFeedFetcher: OPDSFeedFetching, @unchecked Sendable {
    let feed: TPPOPDSFeed
    init(feed: TPPOPDSFeed) { self.feed = feed }
    func fetchFeed(from url: URL) async throws -> TPPOPDSFeed { feed }
    func fetchFeed(from url: URL, resetCache: Bool) async throws -> TPPOPDSFeed { feed }
}

/// Records content deletes; reports nothing on disk and nothing in flight.
/// `@unchecked Sendable` invariant: `_deleted` is read and written only under `lock`.
private final class DeleteRecordingDownloadService: RegistryDownloadServicing, @unchecked Sendable {
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

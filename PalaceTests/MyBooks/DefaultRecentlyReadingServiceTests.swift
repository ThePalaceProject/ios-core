//
//  DefaultRecentlyReadingServiceTests.swift
//  PalaceTests
//
//  Tests the pure data layer that drives the "Continue Reading" row.
//  Each test pins a specific contract clause from
//  .forgeos/swarms/swarm_0b7616e7/contracts/A-RecentlyReading-ActiveSessions.md.
//
//  No singletons, no network — all collaborators arrive via the SUT init.
//

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class DefaultRecentlyReadingServiceTests: XCTestCase {

    private var registry: TPPBookRegistryMock!

    override func setUp() {
        super.setUp()
        registry = TPPBookRegistryMock()
    }

    override func tearDown() {
        registry = nil
        super.tearDown()
    }

    // MARK: - Test 1: ordering by last-read timestamp descending

    func testRecentlyReading_ordersByLastReadTimestampDescending() {
        // Three EPUBs added to the registry. Each has a saved location
        // whose JSON embeds an ISO8601 `timeStamp`. The service must
        // return them in T2, T1, T0 order (most-recent first).
        let t0 = Date(timeIntervalSince1970: 1_700_000_000) // older
        let t1 = Date(timeIntervalSince1970: 1_700_000_100)
        let t2 = Date(timeIntervalSince1970: 1_700_000_200) // newest

        let bookA = makeEpub(id: "A")
        let bookB = makeEpub(id: "B")
        let bookC = makeEpub(id: "C")

        registry.myBooks = [bookA, bookB, bookC]
        registry.addBook(bookA, location: makeLocation(timestamp: t0), state: .downloadSuccessful)
        registry.addBook(bookB, location: makeLocation(timestamp: t1), state: .downloadSuccessful)
        registry.addBook(bookC, location: makeLocation(timestamp: t2), state: .downloadSuccessful)

        let service = DefaultRecentlyReadingService(bookRegistry: registry)

        let result = service.recentlyReading()

        XCTAssertEqual(result.map { $0.bookId }, ["C", "B", "A"],
                       "Sort comparator MUST be descending by lastReadAt")
    }

    // MARK: - Test 2: excludes samples

    func testRecentlyReading_excludesSamples() {
        // A real EPUB and a sample-flagged book. The sample MUST be omitted.
        let realBook = makeEpub(id: "REAL")
        let sampleBook = makeSample(id: "SAMPLE")

        registry.myBooks = [realBook, sampleBook]
        registry.addBook(realBook, location: makeLocation(timestamp: Date()), state: .downloadSuccessful)
        registry.addBook(sampleBook, location: makeLocation(timestamp: Date()), state: .downloadSuccessful)

        let service = DefaultRecentlyReadingService(bookRegistry: registry)

        let result = service.recentlyReading()

        XCTAssertEqual(result.map { $0.bookId }, ["REAL"],
                       "Sample books MUST NOT appear in Continue Reading")
    }

    // MARK: - Test 3: excludes audiobooks

    func testRecentlyReading_excludesAudiobooks() {
        // An EPUB and an audiobook, both with saved locations. The
        // audiobook MUST be omitted — it belongs on the listening row.
        let epub = makeEpub(id: "E1")
        let audiobook = makeAudiobook(id: "AB1")

        registry.myBooks = [epub, audiobook]
        registry.addBook(epub, location: makeLocation(timestamp: Date()), state: .downloadSuccessful)
        registry.addBook(audiobook, location: makeLocation(timestamp: Date()), state: .downloadSuccessful)

        let service = DefaultRecentlyReadingService(bookRegistry: registry)

        let result = service.recentlyReading()

        XCTAssertEqual(result.map { $0.bookId }, ["E1"],
                       "Audiobooks MUST NOT appear in Continue Reading")
    }

    // MARK: - Test 4: excludes books without a saved location

    func testRecentlyReading_excludesBooksWithoutSavedLocation() {
        // A registered EPUB with NO saved location must not appear —
        // the user hasn't opened it yet.
        let opened = makeEpub(id: "OPENED")
        let neverOpened = makeEpub(id: "NEVER")

        registry.myBooks = [opened, neverOpened]
        registry.addBook(opened, location: makeLocation(timestamp: Date()), state: .downloadSuccessful)
        registry.addBook(neverOpened, location: nil, state: .downloadSuccessful)

        let service = DefaultRecentlyReadingService(bookRegistry: registry)

        let result = service.recentlyReading()

        XCTAssertEqual(result.map { $0.bookId }, ["OPENED"],
                       "Books with no saved location MUST be excluded")
    }

    // MARK: - Test 5: empty registry returns empty (no crash)

    func testRecentlyReading_emptyRegistryReturnsEmpty() {
        // Even when myBooks is empty AND we call repeatedly, the service
        // returns an empty array (not nil, not crash). Re-calling exercises
        // the no-state-mutation contract — every call is a pure function
        // of registry state.
        registry.myBooks = []
        let service = DefaultRecentlyReadingService(bookRegistry: registry)

        let firstCall = service.recentlyReading()
        let secondCall = service.recentlyReading()

        XCTAssertEqual(firstCall.count, 0, "Empty registry MUST yield empty output")
        XCTAssertEqual(secondCall.count, 0, "Re-calling on empty registry MUST stay empty")
        XCTAssertTrue(firstCall.isEmpty)
        XCTAssertTrue(secondCall.isEmpty)
    }

    // MARK: - Test 6: parses lastReadAt from location JSON

    func testRecentlyReading_parsesLastReadTimestampFromLocationJSON() {
        // Given a TPPBookLocation whose JSON contains a known ISO8601
        // `timeStamp`, the parsed `lastReadAt` MUST equal that timestamp.
        let known = Date(timeIntervalSince1970: 1_710_000_000)
        let book = makeEpub(id: "BOOK")
        // Use a stale book.updated to ensure the embedded timestamp wins.
        // We rely on bookA.updated already being unrelated; what matters is
        // that the embedded timestamp is what gets returned.
        registry.myBooks = [book]
        registry.addBook(book, location: makeLocation(timestamp: known), state: .downloadSuccessful)

        let service = DefaultRecentlyReadingService(bookRegistry: registry)

        let result = service.recentlyReading()

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.lastReadAt, known,
                       "Embedded `timeStamp` key MUST be parsed as lastReadAt")
    }

    // MARK: - Test 7a: tiebreaker by bookId ascending

    func testRecentlyReading_breaksTimestampTies_byBookIdAscending() {
        // Two books, identical embedded timestamp. The deterministic
        // tiebreaker must place the lexicographically-smaller bookId
        // first. This kills the `<` → `<=` mutation on the comparator —
        // `<=` would yield false when bookIds are equal-but-different
        // and produce non-deterministic order under `sorted(by:)`.
        let sameTime = Date(timeIntervalSince1970: 1_715_000_000)
        let bookZ = makeEpub(id: "Z")
        let bookA = makeEpub(id: "A")

        registry.myBooks = [bookZ, bookA]
        registry.addBook(bookZ, location: makeLocation(timestamp: sameTime), state: .downloadSuccessful)
        registry.addBook(bookA, location: makeLocation(timestamp: sameTime), state: .downloadSuccessful)

        let service = DefaultRecentlyReadingService(bookRegistry: registry)

        XCTAssertEqual(service.recentlyReading().map { $0.bookId }, ["A", "Z"],
                       "Equal timestamps MUST sort by bookId ascending")
    }

    // MARK: - Test 7: deterministic fallback when JSON lacks timestamp

    func testRecentlyReading_fallsBackDeterministically_whenJSONLacksTimestamp() {
        // Two books, both with EPUB-style locations that DO NOT embed a
        // timestamp. The service must:
        //   1. Not crash.
        //   2. Return them in a deterministic order — same input → same output.
        let updatedDate = Date(timeIntervalSince1970: 1_720_000_000)
        let bookA = makeEpub(id: "A", updated: updatedDate)
        let bookB = makeEpub(id: "B", updated: updatedDate)

        registry.myBooks = [bookA, bookB]
        registry.addBook(bookA, location: makeLocationWithoutTimestamp(), state: .downloadSuccessful)
        registry.addBook(bookB, location: makeLocationWithoutTimestamp(), state: .downloadSuccessful)

        let service = DefaultRecentlyReadingService(bookRegistry: registry)

        let first = service.recentlyReading().map { $0.bookId }
        let second = service.recentlyReading().map { $0.bookId }

        XCTAssertEqual(first, second, "Fallback ordering MUST be deterministic")
        XCTAssertEqual(Set(first), Set(["A", "B"]), "Both books MUST be present")
    }

    // MARK: - Test helpers

    /// Builds an EPUB-typed TPPBook for tests. `updated` lets tests pin
    /// the fallback-timestamp branch of the parser.
    private func makeEpub(id: String, updated: Date = Date()) -> TPPBook {
        return makeBook(id: id, relation: .generic, type: DistributorType.EpubZip.rawValue, updated: updated)
    }

    private func makeAudiobook(id: String, updated: Date = Date()) -> TPPBook {
        return makeBook(id: id, relation: .generic, type: DistributorType.OpenAccessAudiobook.rawValue, updated: updated)
    }

    /// Builds a sample-flagged TPPBook. The `defaultAcquisition.relation`
    /// is `.sample`, which `DefaultRecentlyReadingService.isSample` keys off.
    private func makeSample(id: String, updated: Date = Date()) -> TPPBook {
        return makeBook(id: id, relation: .sample, type: DistributorType.EpubZip.rawValue, updated: updated)
    }

    private func makeBook(id: String,
                          relation: TPPOPDSAcquisitionRelation,
                          type: String,
                          updated: Date) -> TPPBook {
        let url = URL(string: "http://example.com/\(id)")!
        let acquisition = TPPOPDSAcquisition(
            relation: relation,
            type: type,
            hrefURL: url,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        return TPPBook(
            acquisitions: [acquisition],
            authors: [TPPBookAuthor(authorName: "Author \(id)", relatedBooksURL: nil)],
            categoryStrings: ["Fiction"],
            distributor: "Test",
            identifier: id,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: Date(),
            publisher: "Test Publisher",
            subtitle: nil,
            summary: "Test summary",
            title: "Title \(id)",
            updated: updated,
            annotationsURL: nil,
            analyticsURL: nil,
            alternateURL: nil,
            relatedWorksURL: nil,
            previewLink: nil,
            seriesURL: nil,
            revokeURL: nil,
            reportURL: nil,
            timeTrackingURL: nil,
            contributors: [:],
            bookDuration: nil,
            imageCache: MockImageCache()
        )
    }

    /// Builds a TPPBookLocation whose JSON contains an ISO8601 `timeStamp`
    /// key matching the audiobook-bookmark shape. This is the only renderer
    /// in the current codebase that embeds a timestamp; the test pins the
    /// parser against that exact JSON shape.
    private func makeLocation(timestamp: Date) -> TPPBookLocation {
        let formatter = ISO8601DateFormatter()
        let json: [String: Any] = [
            "@type": "LocatorHrefProgression",
            "timeStamp": formatter.string(from: timestamp),
            "progressWithinBook": 0.42,
            "title": "Chapter 3"
        ]
        let data = try? JSONSerialization.data(withJSONObject: json, options: [])
        let jsonString = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        guard let location = TPPBookLocation(locationString: jsonString, renderer: "readium3") else {
            // Test setup must always succeed; if this fails we want a
            // visible crash rather than silently building an empty
            // location and dragging the assertions into confusion.
            preconditionFailure("Test setup: failed to build TPPBookLocation")
        }
        return location
    }

    /// Builds a TPPBookLocation matching the Readium 3.x EPUB JSON shape,
    /// which does NOT include a `timeStamp` key. The parser must fall
    /// back to `book.updated` for these.
    private func makeLocationWithoutTimestamp() -> TPPBookLocation {
        let json: [String: Any] = [
            "href": "OEBPS/chapter1.xhtml",
            "@type": "LocatorHrefProgression",
            "progressWithinChapter": 0.5,
            "progressWithinBook": 0.1,
            "title": "Chapter 1",
            "position": 12,
            "cssSelector": ""
        ]
        let data = try? JSONSerialization.data(withJSONObject: json, options: [])
        let jsonString = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        guard let location = TPPBookLocation(locationString: jsonString, renderer: "readium3") else {
            preconditionFailure("Test setup: failed to build TPPBookLocation")
        }
        return location
    }

    // MARK: - recentlyOpenedAudiobook (cold-launch fallback)

    /// Polish-phase (in-app-nav-polish-2026-06-02): when the registry
    /// holds multiple audiobooks and the open tracker records different
    /// timestamps, the service returns the audiobook with the most
    /// recent wall-clock open. This is the seam the Continue row uses
    /// to surface the right audiobook on cold launch — previous
    /// behavior fell back to the older ebook because no live session
    /// was available.
    func testRecentlyOpenedAudiobook_returnsAudiobookWithLatestOpenTimestamp() {
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_700_000_500)

        let audiobookOlder = makeAudiobook(id: "ab-older")
        let audiobookNewer = makeAudiobook(id: "ab-newer")
        registry.myBooks = [audiobookOlder, audiobookNewer]

        let tracker = StubBookOpenTracker(openTimes: [
            "ab-older": older,
            "ab-newer": newer
        ])
        let service = DefaultRecentlyReadingService(
            bookRegistry: registry,
            bookOpenTracker: tracker
        )

        let result = service.recentlyOpenedAudiobook()
        XCTAssertEqual(result?.book.identifier, "ab-newer",
                       "Most-recent open time MUST win regardless of registry order")
        XCTAssertEqual(result?.openedAt, newer,
                       "openedAt MUST be the tracker's recorded date for the winning book")
    }

    /// Cold-launch contract: ebooks in the registry must NOT be returned
    /// by `recentlyOpenedAudiobook()` even if they have a newer open
    /// time than the only audiobook — the method is audiobook-typed,
    /// and the ActiveSessionsViewModel uses it specifically to populate
    /// the listening row when no live session is active.
    func testRecentlyOpenedAudiobook_excludesEbooks_evenWhenEbookOpenedMoreRecently() {
        let audiobookOpenedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let epubOpenedAt = Date(timeIntervalSince1970: 1_700_000_500) // newer

        let audiobook = makeAudiobook(id: "ab-only")
        let epub = makeEpub(id: "epub-newer")
        registry.myBooks = [audiobook, epub]

        let tracker = StubBookOpenTracker(openTimes: [
            "ab-only": audiobookOpenedAt,
            "epub-newer": epubOpenedAt
        ])
        let service = DefaultRecentlyReadingService(
            bookRegistry: registry,
            bookOpenTracker: tracker
        )

        let result = service.recentlyOpenedAudiobook()
        XCTAssertEqual(result?.book.identifier, "ab-only",
                       "Ebook MUST NOT be returned by audiobook-typed accessor")
    }

    /// When no tracker is injected (legacy callers / older test setups),
    /// the method MUST return nil rather than fall back to registry
    /// order — without an open-time signal there's no honest answer.
    func testRecentlyOpenedAudiobook_returnsNil_whenNoTrackerInjected() {
        let audiobook = makeAudiobook(id: "ab-only")
        registry.myBooks = [audiobook]

        let service = DefaultRecentlyReadingService(bookRegistry: registry)
        XCTAssertNil(service.recentlyOpenedAudiobook(),
                     "MUST return nil without a tracker — no fallback to registry order")
    }

    /// When the tracker is present but has no recorded opens for any
    /// audiobook in the registry, return nil. Validates the compactMap
    /// filter (audiobooks without a recorded open are dropped).
    func testRecentlyOpenedAudiobook_returnsNil_whenNoAudiobookHasRecordedOpen() {
        let audiobook = makeAudiobook(id: "ab-never-opened")
        registry.myBooks = [audiobook]

        let tracker = StubBookOpenTracker(openTimes: [:])
        let service = DefaultRecentlyReadingService(
            bookRegistry: registry,
            bookOpenTracker: tracker
        )

        XCTAssertNil(service.recentlyOpenedAudiobook())
    }
}

// MARK: - StubBookOpenTracker

/// In-memory `BookOpenTracking` stub for the cold-launch fallback tests.
/// `recordOpened(_:)` is a no-op because these tests only exercise the
/// read path — open times come pre-seeded via the initializer.
@MainActor
private final class StubBookOpenTracker: BookOpenTracking {
    private var openTimes: [String: Date]
    init(openTimes: [String: Date]) { self.openTimes = openTimes }
    func recordOpened(_ bookId: String, at date: Date) { openTimes[bookId] = date }
    func lastOpened(_ bookId: String) -> Date? { return openTimes[bookId] }
}

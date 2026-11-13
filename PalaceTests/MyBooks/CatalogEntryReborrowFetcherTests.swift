//
//  CatalogEntryReborrowFetcherTests.swift
//  PalaceTests
//
//  The production fetcher the no-active-loan borrow retry reads a catalog entry
//  with, and the wiring that gives the retry path that capability at all
//  (PP-5397).
//

import PalaceBookModel
import PalaceCatalog
import XCTest
@testable import Palace

final class CatalogEntryReborrowFetcherTests: XCTestCase {

    private static let alternate = URL(string: "https://example.org/works/ISBN/123")!
    private static let catalogBorrowHref = "https://example.org/works/ISBN/123/borrow"

    // MARK: - Fixtures

    /// A single-entry catalog feed carrying a borrow-relation link, which is the
    /// shape the circulation manager serves at a work's `alternate` URL.
    private static func catalogEntryFeed(
        href: String = CatalogEntryReborrowFetcherTests.catalogBorrowHref,
        entries: Int = 1,
        id: String = "pp5397-book"
    ) -> TPPOPDSFeed {
        let entry = """
        <entry>
          <title type="text">A Returned Book</title>
          <id>\(id)</id>
          <updated>2026-10-01T00:00:00Z</updated>
          <link href="\(href)" type="application/atom+xml;type=entry;profile=opds-catalog" \
        rel="http://opds-spec.org/acquisition/borrow" />
        </entry>
        """
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title type="text">A Returned Book</title>
          <id>urn:test:pp5397-entry</id>
          <updated>2026-10-01T00:00:00Z</updated>
          \(String(repeating: entry, count: entries))
        </feed>
        """
        return TPPOPDSFeed(xml: TPPXML.xml(withData: Data(xml.utf8))!)!
    }

    private static func book(alternate: URL?) -> TPPBook {
        TPPBook(
            acquisitions: [
                TPPOPDSAcquisition(
                    relation: .generic,
                    type: "application/epub+zip",
                    hrefURL: URL(string: "https://example.org/loan/fulfill/9")!,
                    indirectAcquisitions: [],
                    availability: TPPOPDSAcquisitionAvailabilityUnlimited()
                )
            ],
            authors: nil,
            categoryStrings: nil,
            distributor: nil,
            identifier: "pp5397-book",
            imageURL: nil,
            imageThumbnailURL: nil,
            published: nil,
            publisher: nil,
            subtitle: nil,
            summary: nil,
            title: "A Returned Book",
            updated: Date(timeIntervalSince1970: 1_000_000),
            annotationsURL: nil,
            analyticsURL: nil,
            alternateURL: alternate,
            relatedWorksURL: nil,
            previewLink: nil,
            seriesURL: nil,
            seriesName: nil,
            revokeURL: nil,
            reportURL: nil,
            timeTrackingURL: nil,
            contributors: nil,
            bookDuration: nil,
            imageCache: MockImageCache()
        )
    }

    // MARK: - Reading the entry

    /// The fetcher reads the entry at the book's alternate URL.
    func test_itReadsTheEntryAtTheBooksAlternateURL() async throws {
        let feed = SpyFeedFetcher(result: .success(Self.catalogEntryFeed()))
        let fetched = await CatalogEntryReborrowFetcher.make(feedFetcher: feed)(Self.book(alternate: Self.alternate))

        XCTAssertEqual(feed.requestedURLs, [Self.alternate],
                       "the catalog entry lives at the alternate URL and nowhere else")
        XCTAssertEqual(
            try XCTUnwrap(fetched).defaultAcquisition?.hrefURL.absoluteString,
            Self.catalogBorrowHref,
            "the entry must come back carrying the catalog's borrow link, which is the point of the read"
        )
    }

    /// The read bypasses the feed cache.
    ///
    /// The retry runs seconds after the download failure, inside the cache's
    /// life, so a cached entry is as likely to carry the dead loan's links as
    /// the stored record is.
    func test_itBypassesTheFeedCache() async throws {
        let feed = SpyFeedFetcher(result: .success(Self.catalogEntryFeed()))
        _ = await CatalogEntryReborrowFetcher.make(feedFetcher: feed)(Self.book(alternate: Self.alternate))

        XCTAssertEqual(feed.resetCacheFlags, [true],
                       "a cached entry can carry the same loan-scoped links the stored record does")
    }

    /// A book with no alternate URL is not fetched for.
    func test_withNoAlternateURL_itDoesNotReachTheFeed() async {
        let feed = SpyFeedFetcher(result: .success(Self.catalogEntryFeed()))
        let fetched = await CatalogEntryReborrowFetcher.make(feedFetcher: feed)(Self.book(alternate: nil))

        XCTAssertNil(fetched)
        XCTAssertEqual(feed.requestedURLs, [], "there is no entry to read without an alternate URL")
    }

    /// A feed that errors yields nil, so the retry falls back to the stored book.
    func test_whenTheFeedErrors_itYieldsNil() async {
        let feed = SpyFeedFetcher(result: .failure(PalaceError.parsing(.opdsFeedInvalid)))
        let fetched = await CatalogEntryReborrowFetcher.make(feedFetcher: feed)(Self.book(alternate: Self.alternate))

        XCTAssertNil(fetched, "a failed read must not cost the patron the borrow attempt")
    }

    /// An entry-less feed yields nil rather than a book with no links.
    func test_whenTheFeedCarriesNoEntries_itYieldsNil() async {
        let feed = SpyFeedFetcher(result: .success(Self.catalogEntryFeed(entries: 0)))
        let fetched = await CatalogEntryReborrowFetcher.make(feedFetcher: feed)(Self.book(alternate: Self.alternate))

        XCTAssertNil(fetched, "an empty feed has no links to merge, so the stored book is the better retry")
    }

    /// An entry for some other work yields nil.
    ///
    /// A redirected alternate URL, or one answering with a lane, hands back a
    /// different title. The merge keeps the stored identifier, so its link would
    /// be borrowed under this book's id.
    func test_whenTheEntryIsForAnotherWork_itYieldsNil() async {
        let feed = SpyFeedFetcher(result: .success(Self.catalogEntryFeed(id: "some-other-work")))
        let fetched = await CatalogEntryReborrowFetcher.make(feedFetcher: feed)(Self.book(alternate: Self.alternate))

        XCTAssertNil(fetched, "another work's borrow link must not be borrowed under this book's identifier")
    }

    // MARK: - Wiring

    /// A production-shaped download centre wires the retry's catalog re-read.
    ///
    /// Without this the seam exists and its tests pass while the shipped app
    /// still retries the dead fulfillment link, which is the state PP-5397 was
    /// filed against.
    @MainActor
    func test_theDownloadCentreWiresTheRetrysCatalogReRead() {
        let centre = MyBooksDownloadCenter(
            userAccount: TPPUserAccountMock(),
            bookRegistry: TPPBookRegistryMock(),
            urlSession: URLSession(configuration: .ephemeral)
        )

        XCTAssertTrue(
            centre.authRetryHandler.canReReadCatalogEntry,
            "the no-active-loan retry has no catalog re-read wired, so it still asks the dead loan's link"
        )
    }
}

/// Records what the production fetcher asked the feed layer for.
///
/// Implements both `OPDSFeedFetching` requirements so `resetCache` is observable
/// — the protocol extension's default would forward it away.
private final class SpyFeedFetcher: OPDSFeedFetching, @unchecked Sendable {
    private let lock = NSLock()
    private let result: Result<TPPOPDSFeed, Error>
    private var _requestedURLs: [URL] = []
    private var _resetCacheFlags: [Bool] = []

    var requestedURLs: [URL] { lock.withLock { _requestedURLs } }
    var resetCacheFlags: [Bool] { lock.withLock { _resetCacheFlags } }

    init(result: Result<TPPOPDSFeed, Error>) {
        self.result = result
    }

    func fetchFeed(from url: URL) async throws -> TPPOPDSFeed {
        try await fetchFeed(from: url, resetCache: false)
    }

    func fetchFeed(from url: URL, resetCache: Bool) async throws -> TPPOPDSFeed {
        lock.withLock {
            _requestedURLs.append(url)
            _resetCacheFlags.append(resetCache)
        }
        return try result.get()
    }
}

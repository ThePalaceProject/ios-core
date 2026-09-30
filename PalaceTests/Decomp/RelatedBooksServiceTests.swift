//
//  RelatedBooksServiceTests.swift
//  PalaceTests
//
//  The related-works lane derivation, extracted from `BookDetailViewModel`.
//  These tests could not be written before the extraction: the
//  derivation's only input was the return value of a concrete `OPDSFeedService`
//  actor constructed inside the view model, so there was nothing to hand it a
//  feed through. `RelatedBooksFeedFetcher` is that seam.
//
//  Both halves are covered — the pure `lanes(from:registry:authorName:)`
//  derivation over parsed feed fixtures, and `fetchLanes`' three outcomes
//  (grouped feed, non-grouped feed, thrown error), which are what decide whether
//  the screen's existing lanes survive.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace
import PalaceBookModel
import PalaceBookRegistry

@MainActor
final class RelatedBooksServiceTests: XCTestCase {

    private var registry: TPPBookRegistryMock!

    override func setUp() {
        super.setUp()
        registry = TPPBookRegistryMock()
    }

    override func tearDown() {
        registry = nil
        super.tearDown()
    }

    // MARK: - The derivation

    /// A grouped feed becomes one lane per grouping-link title, each carrying
    /// the entries that named it and the first `href` seen for that group.
    ///
    /// Mutation: keying the lanes on anything but the group title merges or
    /// splits them and changes the counts; taking the LAST href instead of the
    /// first changes `subsectionURL`.
    func testLanes_groupedFeed_groupsEntriesByGroupTitleAndKeepsTheFirstMoreURL() throws {
        let feed = try makeGroupedFeed(entries: [
            ("Recently Added", "book-1", "https://example.com/group/recent"),
            ("Recently Added", "book-2", "https://example.com/group/recent-DUPLICATE"),
            ("Popular", "book-3", "https://example.com/group/popular")
        ])

        let lanes = try XCTUnwrap(RelatedBooksService.lanes(from: feed, registry: registry, authorName: nil))

        XCTAssertEqual(Set(lanes.keys), ["Recently Added", "Popular"],
                       "One lane per distinct group title")
        XCTAssertEqual(lanes["Recently Added"]?.books.count, 2)
        XCTAssertEqual(lanes["Popular"]?.books.count, 1)
        XCTAssertEqual(lanes["Recently Added"]?.subsectionURL?.absoluteString,
                       "https://example.com/group/recent",
                       "The first href seen for a group is the lane's More destination; a later entry must not replace it")
        XCTAssertEqual(lanes["Recently Added"]?.title, "Recently Added",
                       "A lane's title is its group title, not its key by coincidence")
    }

    /// Books keep the order the feed listed them in within their lane. Pinned
    /// because the derivation appends into `[String: [TPPBook]]` and a switch to
    /// any set-like accumulation would scramble a lane the server ordered.
    func testLanes_booksWithinALane_preserveFeedOrder() throws {
        let feed = try makeGroupedFeed(entries: [
            ("Popular", "first", "https://example.com/group/popular"),
            ("Popular", "second", "https://example.com/group/popular"),
            ("Popular", "third", "https://example.com/group/popular")
        ])

        let lanes = try XCTUnwrap(RelatedBooksService.lanes(from: feed, registry: registry, authorName: nil))

        XCTAssertEqual(lanes["Popular"]?.books.map(\.title),
                       ["Title first", "Title second", "Title third"],
                       "A lane must list its books in feed order")
    }

    /// Two branches of the derivation are unreachable from a PARSED feed, and
    /// this test pins the parser coupling that makes them so — measured, not
    /// assumed, by feeding the parser the inputs that would reach them:
    ///
    ///  - `subsectionURL == nil`: `TPPOPDSLink.init?` requires an `href`, so a
    ///    grouping link without one is dropped before `groupAttributes` sees it.
    ///    The entry is then ungrouped.
    ///  - `guard let group = entry.groupAttributes else { continue }`:
    ///    `TPPOPDSFeed.computeType` returns `.invalid` when entries disagree on
    ///    their implied type, so a feed mixing grouped and ungrouped entries
    ///    never reaches `.acquisitionGrouped` at all.
    ///
    /// Both are therefore defensive rather than exercised. What is asserted
    /// here is the reachable consequence: every lane derived from a parsed
    /// grouped feed carries a More destination.
    func testLanes_everyLaneFromAParsedFeed_carriesAMoreDestination() throws {
        let missingHref = try makeGroupedFeed(entries: [("Staff Picks", "book-9", nil)])
        XCTAssertNil(RelatedBooksService.lanes(from: missingHref, registry: registry, authorName: nil),
                     "A grouping link with no href leaves the entry ungrouped, so the feed is not grouped and has no lanes")

        let mixed = try makeGroupedFeed(
            entries: [("Popular", "grouped-1", "https://example.com/group/popular")],
            ungroupedEntryIDs: ["loose-1"]
        )
        XCTAssertEqual(mixed.type, .invalid,
                       "A feed mixing grouped and ungrouped entries is rejected by the parser, not partially derived")

        let valid = try makeGroupedFeed(entries: [("Popular", "book-1", "https://example.com/group/popular")])
        let lanes = try XCTUnwrap(RelatedBooksService.lanes(from: valid, registry: registry, authorName: nil))
        for (title, lane) in lanes {
            XCTAssertNotNil(lane.subsectionURL,
                            "Lane \(title) came from a parsed link, which cannot exist without an href")
        }
    }

    /// The author hoist re-inserts the lane containing the current book's
    /// author. Pinned as a CONTENT invariant: the derivation is a Dictionary, so
    /// the hoist changes no key and no value, and a reader who assumed it
    /// reorders the rendered lanes would be reading something this code cannot
    /// express. Asserting the content equality is what keeps that honest.
    ///
    /// Mutation: the hoist dropping the author lane instead of re-inserting it
    /// (an easy off-by-one in `removeValue` / `merge`) loses a key here.
    func testLanes_authorHoist_preservesEveryLaneAndItsBooks() throws {
        let feed = try makeGroupedFeed(entries: [
            ("By This Author", "auth-1", "https://example.com/group/author"),
            ("Also Borrowed", "other-1", "https://example.com/group/other")
        ], author: "Hoisted Author")

        let withoutHoist = try XCTUnwrap(RelatedBooksService.lanes(from: feed, registry: registry, authorName: nil))
        let withHoist = try XCTUnwrap(RelatedBooksService.lanes(from: feed, registry: registry, authorName: "Hoisted Author"))

        XCTAssertEqual(Set(withHoist.keys), Set(withoutHoist.keys),
                       "The author hoist must not add or drop a lane")
        for (key, lane) in withHoist {
            XCTAssertEqual(lane.books.map(\.identifier), withoutHoist[key]?.books.map(\.identifier),
                           "Lane \(key) must hold the same books either way")
        }
    }

    /// A feed that is not `.acquisitionGrouped` has no lanes to derive, and the
    /// answer is nil rather than an empty map — the two mean different things to
    /// the caller (leave the current lanes alone vs. apply an empty result).
    ///
    /// Mutation: returning `[:]` here makes an ungrouped feed wipe the screen's
    /// lanes, which is the regression the empty-guard in the view model exists
    /// to prevent.
    func testLanes_ungroupedFeed_isNilAndNotAnEmptyMap() throws {
        let feed = try makeUngroupedFeed()
        XCTAssertEqual(feed.type, .acquisitionUngrouped, "precondition: the fixture must not be grouped")

        XCTAssertNil(RelatedBooksService.lanes(from: feed, registry: registry, authorName: nil))
    }

    // MARK: - fetchLanes outcomes

    /// The happy path: `fetchLanes` fetches the URL it is given and returns the
    /// derivation of what came back.
    func testFetchLanes_fetchesTheGivenURL_andReturnsItsLanes() async throws {
        let feed = try makeGroupedFeed(entries: [("Popular", "book-1", "https://example.com/group/popular")])
        let requested = LockedURLBox()
        let service = RelatedBooksService(fetcher: { url in
            requested.value = url
            return feed
        }, registry: registry)

        let lanes = await service.fetchLanes(from: URL(string: "https://example.com/related")!, authorName: nil)

        XCTAssertEqual(requested.value?.absoluteString, "https://example.com/related",
                       "The fetcher must be called with the related-works URL it was handed")
        XCTAssertEqual(Set((lanes ?? [:]).keys), ["Popular"])
    }

    /// A thrown fetch is nil, not an empty map — the screen keeps whatever lanes
    /// it already had.
    ///
    /// Mutation: returning `[:]` on failure makes a transient network error
    /// blank the related-books section.
    func testFetchLanes_whenTheFetchThrows_isNilSoExistingLanesSurvive() async {
        let service = RelatedBooksService(fetcher: { _ in
            throw NSError(domain: "test", code: -1009)
        }, registry: registry)

        let lanes = await service.fetchLanes(from: URL(string: "https://example.com/related")!, authorName: nil)

        XCTAssertNil(lanes, "A failed related-works fetch must not be reported as 'no lanes'")
    }

    // MARK: - Fixtures

    /// Builds a parsed `TPPOPDSFeed`. Each entry names a group title and an
    /// optional group href; `ungroupedEntryIDs` add entries with an acquisition
    /// link but no grouping link.
    private func makeGroupedFeed(entries: [(group: String, id: String, href: String?)],
                                 ungroupedEntryIDs: [String] = [],
                                 author: String = "Fixture Author") throws -> TPPOPDSFeed {
        let grouped = entries.map { entry -> String in
            let hrefAttribute = entry.href.map { " href=\"\($0)\"" } ?? ""
            return """
            <entry>
              <id>urn:uuid:\(entry.id)</id>
              <title>Title \(entry.id)</title>
              <author><name>\(author)</name></author>
              <updated>2024-01-01T00:00:00Z</updated>
              <link rel="http://opds-spec.org/acquisition/open-access"
                    href="https://example.com/books/\(entry.id).epub"
                    type="application/epub+zip"/>
              <link rel="collection"\(hrefAttribute) title="\(entry.group)"/>
            </entry>
            """
        }.joined(separator: "\n")

        let loose = ungroupedEntryIDs.map { id in
            """
            <entry>
              <id>urn:uuid:\(id)</id>
              <title>Title \(id)</title>
              <updated>2024-01-01T00:00:00Z</updated>
              <link rel="http://opds-spec.org/acquisition/open-access"
                    href="https://example.com/books/\(id).epub"
                    type="application/epub+zip"/>
            </entry>
            """
        }.joined(separator: "\n")

        return try parse(feedXML: grouped + "\n" + loose)
    }

    private func makeUngroupedFeed() throws -> TPPOPDSFeed {
        try parse(feedXML: """
        <entry>
          <id>urn:uuid:ungrouped-1</id>
          <title>Ungrouped</title>
          <updated>2024-01-01T00:00:00Z</updated>
          <link rel="http://opds-spec.org/acquisition/open-access"
                href="https://example.com/books/ungrouped-1.epub"
                type="application/epub+zip"/>
        </entry>
        """)
    }

    private func parse(feedXML: String) throws -> TPPOPDSFeed {
        let document = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom"
              xmlns:opds="http://opds-spec.org/2010/catalog"
              xmlns:dcterms="http://purl.org/dc/terms/"
              xmlns:schema="http://schema.org/">
          <id>urn:uuid:related-fixture</id>
          <title>Related Works</title>
          <updated>2024-01-01T00:00:00Z</updated>
        \(feedXML)
        </feed>
        """
        let xml = try XCTUnwrap(TPPXML.xml(withData: Data(document.utf8)),
                                "fixture XML must parse")
        return try XCTUnwrap(TPPOPDSFeed(xml: xml), "fixture feed must parse")
    }
}

/// Minimal box so the fetch closure can report the URL it was handed back to the
/// test body without capturing a `var` across the async boundary.
private final class LockedURLBox: @unchecked Sendable {
    var value: URL?
}

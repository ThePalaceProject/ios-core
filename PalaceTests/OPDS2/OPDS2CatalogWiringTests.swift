//
//  OPDS2CatalogWiringTests.swift
//  PalaceTests
//
//  Tests for OPDS 2 → Catalog UI wiring: OPDSParser format detection,
//  CatalogFeed OPDS2 init, and CatalogViewModel.mapFeed OPDS2 branch.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

@MainActor
final class OPDS2CatalogWiringTests: XCTestCase {

    // MARK: - OPDSParser Format Detection

    func testParser_detectsOPDS2JSON() throws {
        let json = """
        {
          "metadata": {"title": "Test Library"},
          "links": [{"href": "/self", "rel": "self"}],
          "publications": [
            {
              "metadata": {"id": "b1", "title": "Book One", "updated": "2026-01-01T00:00:00Z"},
              "links": [{"href": "/borrow/b1", "rel": "http://opds-spec.org/acquisition/borrow", "type": "application/epub+zip"}]
            }
          ]
        }
        """
        let data = json.data(using: .utf8)!
        let parser = OPDSParser()
        let feed = try parser.parseFeed(from: data)

        XCTAssertTrue(feed.isOPDS2)
        XCTAssertEqual(feed.title, "Test Library")
        XCTAssertNotNil(feed.opds2Feed)
    }

    func testParser_detectsOPDS1XML() throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom">
          <id>test</id>
          <title>XML Library</title>
          <updated>2026-01-01T00:00:00Z</updated>
        </feed>
        """
        let data = xml.data(using: .utf8)!
        let parser = OPDSParser()
        let feed = try parser.parseFeed(from: data)

        XCTAssertFalse(feed.isOPDS2)
        XCTAssertNil(feed.opds2Feed)
        XCTAssertEqual(feed.title, "XML Library")
    }

    func testParser_invalidJSONThrows() {
        let data = "{invalid json".data(using: .utf8)!
        let parser = OPDSParser()

        XCTAssertThrowsError(try parser.parseFeed(from: data))
    }

    // MARK: - CatalogFeed OPDS2 Init

    func testCatalogFeed_opds2Init_setsTitle() throws {
        let opds2 = makeGroupedFeed(title: "My Library")
        let feed = CatalogFeed(opds2Feed: opds2)

        XCTAssertEqual(feed.title, "My Library")
        XCTAssertTrue(feed.isOPDS2)
    }

    func testCatalogFeed_opds2Init_mapsEntries() throws {
        let opds2 = makeGroupedFeed(title: "Test", groupCount: 1, pubsPerGroup: 3)
        let feed = CatalogFeed(opds2Feed: opds2)

        XCTAssertEqual(feed.entries.count, 3)
    }

    func testCatalogFeed_opds2Init_createsShellOpdsFeed() throws {
        let opds2 = makeGroupedFeed(title: "Test")
        let feed = CatalogFeed(opds2Feed: opds2)

        // Shell feed exists for backward compat
        XCTAssertNotNil(feed.opdsFeed)
    }

    // MARK: - CatalogViewModel.mapFeed with OPDS 2

    func testMapFeed_opds2Grouped_producesLanes() throws {
        let opds2 = makeGroupedFeed(title: "Grouped Library", groupCount: 2, pubsPerGroup: 3)
        let feed = CatalogFeed(opds2Feed: opds2)

        let mapped = CatalogViewModel.mapFeed(feed)

        XCTAssertEqual(mapped.title, "Grouped Library")
        XCTAssertEqual(mapped.lanes.count, 2)
        XCTAssertEqual(mapped.lanes[0].books.count, 3)
        XCTAssertEqual(mapped.lanes[1].books.count, 3)
        XCTAssertTrue(mapped.ungroupedBooks.isEmpty)
    }

    func testMapFeed_opds2Grouped_lanesTitlesMatch() throws {
        let opds2 = makeGroupedFeed(title: "Test", groupTitles: ["New Releases", "Popular"])
        let feed = CatalogFeed(opds2Feed: opds2)

        let mapped = CatalogViewModel.mapFeed(feed)

        XCTAssertEqual(mapped.lanes[0].title, "New Releases")
        XCTAssertEqual(mapped.lanes[1].title, "Popular")
    }

    func testMapFeed_opds2Grouped_lanesHaveMoreURLs() throws {
        let opds2 = makeGroupedFeed(title: "Test", groupCount: 1, pubsPerGroup: 1)
        let feed = CatalogFeed(opds2Feed: opds2)

        let mapped = CatalogViewModel.mapFeed(feed)

        XCTAssertNotNil(mapped.lanes.first?.moreURL)
    }

    func testMapFeed_opds2Publication_producesUngroupedBooks() throws {
        let opds2 = makePublicationFeed(title: "Search Results", pubCount: 5)
        let feed = CatalogFeed(opds2Feed: opds2)

        let mapped = CatalogViewModel.mapFeed(feed)

        XCTAssertTrue(mapped.lanes.isEmpty)
        XCTAssertEqual(mapped.ungroupedBooks.count, 5)
    }

    func testMapFeed_opds2_bookMetadataPreserved() throws {
        let opds2 = makePublicationFeed(title: "Test", pubCount: 1)
        let feed = CatalogFeed(opds2Feed: opds2)

        let mapped = CatalogViewModel.mapFeed(feed)
        let book = mapped.ungroupedBooks.first

        XCTAssertNotNil(book)
        XCTAssertFalse(book!.title.isEmpty)
        XCTAssertFalse(book!.identifier.isEmpty)
        XCTAssertGreaterThan(book!.acquisitions.count, 0)
    }

    func testMapFeed_opds2Navigation_producesEmptyLanesAndBooks() throws {
        let opds2 = OPDS2Feed(
            metadata: OPDS2FeedMetadata(title: "Nav Feed"),
            links: [],
            navigation: [
                OPDS2NavigationLink(href: "/ebooks", title: "Ebooks"),
                OPDS2NavigationLink(href: "/audiobooks", title: "Audiobooks")
            ]
        )
        let feed = CatalogFeed(opds2Feed: opds2)

        let mapped = CatalogViewModel.mapFeed(feed)

        XCTAssertTrue(mapped.lanes.isEmpty)
        XCTAssertTrue(mapped.ungroupedBooks.isEmpty)
    }

    func testMapFeed_opds2Facets_extracted() throws {
        let facets = [
            OPDS2FacetGroup(
                metadata: OPDS2FacetGroupMetadata(title: "Sort By"),
                links: [
                    OPDS2FacetLink(href: "https://example.com/sort-title", title: "Title"),
                    OPDS2FacetLink(href: "https://example.com/sort-date", title: "Date")
                ]
            )
        ]
        let opds2 = OPDS2Feed(
            metadata: OPDS2FeedMetadata(title: "Test"),
            links: [],
            publications: [makeOPDS2Publication(index: 0)],
            facets: facets
        )
        let feed = CatalogFeed(opds2Feed: opds2)
        let mapped = CatalogViewModel.mapFeed(feed)

        XCTAssertEqual(mapped.facetGroups.count, 1)
        XCTAssertEqual(mapped.facetGroups.first?.name, "Sort By")
        XCTAssertEqual(mapped.facetGroups.first?.filters.count, 2)
    }

    // MARK: - End-to-End: JSON → Parser → CatalogFeed → mapFeed

    func testEndToEnd_jsonToLanes() throws {
        let bundle = Bundle(for: type(of: self))
        let url = bundle.url(forResource: "OPDS2CatalogFeed", withExtension: "json", subdirectory: "OPDS2/Fixtures")
            ?? bundle.url(forResource: "OPDS2CatalogFeed", withExtension: "json")
        let data = try XCTUnwrap(url.flatMap { try? Data(contentsOf: $0) })

        let parser = OPDSParser()
        let feed = try parser.parseFeed(from: data)

        XCTAssertTrue(feed.isOPDS2)

        let mapped = CatalogViewModel.mapFeed(feed)

        XCTAssertEqual(mapped.title, "Palace Test Library")
        XCTAssertEqual(mapped.lanes.count, 3)
        XCTAssertEqual(mapped.lanes[0].title, "New & Notable")
        XCTAssertEqual(mapped.lanes[0].books.count, 2)
        XCTAssertEqual(mapped.lanes[1].title, "Popular Audiobooks")
        XCTAssertEqual(mapped.lanes[1].books.count, 1)
        XCTAssertEqual(mapped.lanes[2].title, "Staff Picks")
        XCTAssertEqual(mapped.lanes[2].books.count, 2)

        // Verify facets
        XCTAssertEqual(mapped.facetGroups.count, 1)
        XCTAssertEqual(mapped.facetGroups.first?.name, "Sort By")
    }

    // MARK: - Helpers

    private func makeOPDS2Publication(index: Int) -> OPDS2Publication {
        OPDS2Publication(
            links: [
                OPDS2Link(
                    href: "https://example.com/borrow/\(index)",
                    type: "application/epub+zip",
                    rel: "http://opds-spec.org/acquisition/borrow"
                )
            ],
            metadata: OPDS2Publication.Metadata(
                updated: Date(),
                description: nil,
                id: "pub-\(index)",
                title: "Book \(index)"
            ),
            images: nil
        )
    }

    private func makeGroupedFeed(
        title: String,
        groupCount: Int = 2,
        pubsPerGroup: Int = 2,
        groupTitles: [String]? = nil
    ) -> OPDS2Feed {
        let groups = (0..<groupCount).map { i in
            let groupTitle = groupTitles?[safe: i] ?? "Group \(i)"
            let pubs = (0..<pubsPerGroup).map { j in
                makeOPDS2Publication(index: i * pubsPerGroup + j)
            }
            return OPDS2Group(
                metadata: OPDS2GroupMetadata(title: groupTitle),
                links: [OPDS2Link(href: "https://example.com/group/\(i)", rel: "subsection")],
                publications: pubs
            )
        }
        return OPDS2Feed(
            metadata: OPDS2FeedMetadata(title: title),
            links: [],
            groups: groups
        )
    }

    private func makePublicationFeed(title: String, pubCount: Int) -> OPDS2Feed {
        let pubs = (0..<pubCount).map { makeOPDS2Publication(index: $0) }
        return OPDS2Feed(
            metadata: OPDS2FeedMetadata(title: title),
            links: [],
            publications: pubs
        )
    }
}

// Safe array subscript
private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

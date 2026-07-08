//
//  CatalogLaneAssemblyTests.swift
//  PalaceTests
//
//  Pinning tests for Gap 5: When `CatalogFeed(opds2Feed:)` flattens publications
//  out of an OPDS2 grouped feed, the same publication appearing in multiple
//  groups (e.g. "Featured" and "New Releases") must be deduped by id so the
//  catalog doesn't show the same book twice. First occurrence wins to preserve
//  group ordering.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace
@testable import PalaceCatalog

final class CatalogLaneAssemblyTests: XCTestCase {

    // MARK: - Helpers

    private func makePublication(id: String, title: String? = nil) -> OPDS2Publication {
        OPDS2Publication(
            links: [
                OPDS2Link(
                    href: "https://example.com/borrow/\(id)",
                    type: "application/epub+zip",
                    rel: "http://opds-spec.org/acquisition/borrow"
                )
            ],
            metadata: OPDS2Publication.Metadata(
                id: id,
                title: title ?? "Title for \(id)"
            ),
            images: nil
        )
    }

    private func makeGroup(title: String, pubs: [OPDS2Publication]) -> OPDS2Group {
        OPDS2Group(
            metadata: OPDS2GroupMetadata(title: title),
            links: nil,
            publications: pubs,
            navigation: nil
        )
    }

    // MARK: - Single group: no dedupe behavior change

    func testSingleGroup_unchangedFromFlatten() {
        let pubs = [
            makePublication(id: "a"),
            makePublication(id: "b"),
            makePublication(id: "c")
        ]
        let feed = OPDS2Feed(
            metadata: OPDS2FeedMetadata(title: "Test"),
            groups: [makeGroup(title: "All", pubs: pubs)]
        )

        let catalogFeed = CatalogFeed(opds2Feed: feed)

        XCTAssertEqual(catalogFeed.entries.count, 3)
        XCTAssertEqual(catalogFeed.entries.map(\.id), ["a", "b", "c"])
    }

    // MARK: - Cross-group dedupe pinning

    /// PRIMARY PIN: publication "x" appears in 2 of 3 groups. Total entries
    /// before dedupe = 4 (a, x, x, b). After dedupe should be 3 (a, x, b).
    /// First occurrence wins → ordering preserved.
    func testPublicationInMultipleGroups_dedupedByID_firstOccurrenceWins() {
        let pubA = makePublication(id: "a", title: "Apple")
        let pubX = makePublication(id: "x", title: "Xenon")
        let pubXDuplicate = makePublication(id: "x", title: "Xenon (different title, same id)")
        let pubB = makePublication(id: "b", title: "Banana")

        let feed = OPDS2Feed(
            metadata: OPDS2FeedMetadata(title: "Grouped"),
            groups: [
                makeGroup(title: "Featured", pubs: [pubA, pubX]),
                makeGroup(title: "New Releases", pubs: [pubXDuplicate, pubB])
            ]
        )

        let catalogFeed = CatalogFeed(opds2Feed: feed)

        XCTAssertEqual(
            catalogFeed.entries.count, 3,
            "Cross-group duplicates must be removed: a + x + b, not a + x + x + b"
        )
        XCTAssertEqual(catalogFeed.entries.map(\.id), ["a", "x", "b"],
                       "First occurrence wins; group ordering preserved.")
        // First-wins means the title from the first group's copy of x is kept.
        let xEntry = catalogFeed.entries.first { $0.id == "x" }
        XCTAssertEqual(xEntry?.title, "Xenon",
                       "Keeping the first occurrence preserves the metadata from the earlier group.")
    }

    /// N groups, the SAME publication appears in every group. Result is N
    /// entries (one per uniquely-id'd pub), not N+1.
    func testPublicationInEveryGroup_resultsInNEntriesNotNPlusOne() {
        let pubA = makePublication(id: "a")
        let pubB = makePublication(id: "b")
        // Pub "shared" appears in every group.
        let shared = makePublication(id: "shared")

        let feed = OPDS2Feed(
            metadata: OPDS2FeedMetadata(title: "Grouped"),
            groups: [
                makeGroup(title: "G1", pubs: [pubA, shared]),
                makeGroup(title: "G2", pubs: [pubB, shared]),
                makeGroup(title: "G3", pubs: [shared])
            ]
        )

        let catalogFeed = CatalogFeed(opds2Feed: feed)

        // 3 distinct publications: a, shared, b
        XCTAssertEqual(catalogFeed.entries.count, 3,
                       "N groups containing one shared pub → entries.count must equal distinct id count, not flat sum")
        XCTAssertEqual(Set(catalogFeed.entries.map(\.id)), ["a", "b", "shared"])
    }

    /// Dedupe must not collapse distinct publications that happen to share titles.
    func testDistinctIDs_sameTitle_areNotDeduped() {
        let pub1 = makePublication(id: "id-1", title: "The Sea")
        let pub2 = makePublication(id: "id-2", title: "The Sea")

        let feed = OPDS2Feed(
            metadata: OPDS2FeedMetadata(title: "Test"),
            groups: [makeGroup(title: "Featured", pubs: [pub1, pub2])]
        )

        let catalogFeed = CatalogFeed(opds2Feed: feed)
        XCTAssertEqual(catalogFeed.entries.count, 2,
                       "Distinct ids must NOT be deduped just because titles match.")
    }

    // MARK: - Flat publication feeds: dedupe still applies

    func testFlatPublications_duplicateIDs_areDeduped() {
        let feed = OPDS2Feed(
            metadata: OPDS2FeedMetadata(title: "Flat"),
            publications: [
                makePublication(id: "a"),
                makePublication(id: "b"),
                makePublication(id: "a"), // dupe
                makePublication(id: "c")
            ]
        )

        let catalogFeed = CatalogFeed(opds2Feed: feed)
        XCTAssertEqual(catalogFeed.entries.map(\.id), ["a", "b", "c"])
    }

    // MARK: - Empty / nil feeds

    func testNoGroupsOrPublications_emptyEntries() {
        let feed = OPDS2Feed(metadata: OPDS2FeedMetadata(title: "Empty"))
        let catalogFeed = CatalogFeed(opds2Feed: feed)
        XCTAssertTrue(catalogFeed.entries.isEmpty)
    }

    // MARK: - Ordering invariants

    /// Ordering must be: all of group 0 (in order, deduped), then any new
    /// pubs from group 1 (deduped against earlier groups), etc.
    func testOrdering_groupOrderPreservedAcrossDedupe() {
        let g0 = makeGroup(title: "G0", pubs: [
            makePublication(id: "1"),
            makePublication(id: "2"),
            makePublication(id: "3")
        ])
        let g1 = makeGroup(title: "G1", pubs: [
            makePublication(id: "2"), // dupe of g0
            makePublication(id: "4"),
            makePublication(id: "1")  // dupe of g0
        ])
        let g2 = makeGroup(title: "G2", pubs: [
            makePublication(id: "5"),
            makePublication(id: "4")  // dupe of g1
        ])
        let feed = OPDS2Feed(
            metadata: OPDS2FeedMetadata(title: "Ordered"),
            groups: [g0, g1, g2]
        )

        let catalogFeed = CatalogFeed(opds2Feed: feed)
        XCTAssertEqual(catalogFeed.entries.map(\.id), ["1", "2", "3", "4", "5"])
    }
}

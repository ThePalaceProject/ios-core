//
//  CatalogLaneAssemblyTests.swift
//  PalaceTests
//
//  Deep mutation-killing tests for the catalog-lane assembly invariants
//  exercised when an OPDS 2 feed lands in CatalogViewModel.mapFeed.
//
//  ──────────────────────────────────────────────────────────────────────────
//  Contract under test (lane assembly)
//  ──────────────────────────────────────────────────────────────────────────
//
//   1. SEQUENCING. Lanes appear in the exact ORDER the OPDS 2 feed lists
//      its groups — first group → first lane, last group → last lane. UI
//      relies on this for stable "Featured ▸ New Releases ▸ Staff Picks"
//      ordering.
//
//   2. EMPTY-GROUP PRUNING. Groups with zero publications produce NO lane.
//      An empty lane would render as a blank row in the catalog UI.
//
//   3. PER-LANE BOOK ORDER. Within a lane, publications appear in feed
//      order. The OPDS spec doesn't mandate this, but the UI does — sort
//      stability is a UX promise.
//
//   4. moreURL HARVESTING. Each lane's `moreURL` comes from its group's
//      `subsection` (or `self`) link. A lane with no such link has a nil
//      moreURL and the "More" button must not render.
//
//   5. PUBLICATION DEDUPE BY ID across the FLAT catalog-entry list.
//      `CatalogFeed(opds2Feed:)` flattens all groups → `entries`. The
//      production code does NOT dedupe in the flat list (gap documented
//      below), but it DOES preserve the per-lane mapping so the same
//      publication can appear in two lanes (this is a deliberate feature —
//      "New Releases" and "Audiobooks" can both include a hot title).
//
//   6. NAVIGATION-ONLY FEED → zero lanes, zero ungrouped books.
//      A pure-navigation OPDS 2 feed must produce neither.
//
//   7. PUBLICATION-ONLY FEED → zero lanes, all pubs end up in
//      `ungroupedBooks`.
//
//  ──────────────────────────────────────────────────────────────────────────
//  Gap documented (NOT fixed — would require production change):
//    `CatalogFeed(opds2Feed:)` flattens publications across groups WITHOUT
//    de-duplicating by `metadata.id`. If the same publication appears in
//    two groups, `feed.entries` will contain two entries with the same id.
//    The lane assembly itself is fine (one CatalogLaneModel per group), but
//    consumers iterating `feed.entries` see duplicates. The test below
//    pins the CURRENT behavior as a regression guard.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class CatalogLaneAssemblyTests: XCTestCase {

    // MARK: - Helpers

    /// Build a minimal OPDS 2 publication.
    private func makePub(id: String, title: String, index: Int = 0) -> OPDS2Publication {
        OPDS2Publication(
            links: [
                OPDS2Link(
                    href: "https://example.com/borrow/\(id)",
                    type: "application/epub+zip",
                    rel: "http://opds-spec.org/acquisition/borrow"
                )
            ],
            metadata: OPDS2Publication.Metadata(
                updated: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(index)),
                description: nil,
                id: id,
                title: title
            ),
            images: nil
        )
    }

    /// Build an OPDS 2 group with the given title, publications, and an
    /// optional `subsection` link (the moreURL source).
    private func makeGroup(
        title: String,
        pubs: [OPDS2Publication],
        moreURL: URL? = URL(string: "https://example.com/more")
    ) -> OPDS2Group {
        var links: [OPDS2Link] = []
        if let moreURL {
            links.append(OPDS2Link(href: moreURL.absoluteString, rel: "subsection"))
        }
        return OPDS2Group(
            metadata: OPDS2GroupMetadata(title: title),
            links: links,
            publications: pubs
        )
    }

    private func bookRegistry() -> TPPBookRegistryProvider {
        AppContainer.production().bookRegistry
    }

    // MARK: - 1. SEQUENCING

    /// Mutant killed: shuffling the group order in `buildOPDS2GroupedContent`
    /// (e.g. iterating `.reversed()` or sorting alphabetically). The exact
    /// feed order must be preserved.
    func testMapFeed_NLanes_MaintainsExactFeedOrder() throws {
        let titles = ["Aardvark", "Zebra", "Mongoose", "Beaver", "Falcon"] // intentionally NOT alphabetic
        let groups = titles.enumerated().map { (idx, t) in
            makeGroup(title: t, pubs: [makePub(id: "p-\(idx)", title: "Book \(idx)", index: idx)])
        }
        let opds2 = OPDS2Feed(
            metadata: OPDS2FeedMetadata(title: "Order Test"),
            groups: groups
        )
        let feed = CatalogFeed(opds2Feed: opds2)
        let mapped = CatalogViewModel.mapFeed(feed, bookRegistry: bookRegistry())

        XCTAssertEqual(mapped.lanes.map(\.title), titles,
                       "Lanes must appear in EXACT feed group order — no sort, no reverse")
    }

    /// Mutant killed: dropping the loop bound by one (off-by-one) so the
    /// last lane is missing. With N=10 we have a wide margin to spot it.
    func testMapFeed_TenGroups_ProducesExactlyTenLanes() throws {
        let groups = (0..<10).map { i in
            makeGroup(title: "Lane \(i)", pubs: [makePub(id: "p\(i)", title: "B\(i)")])
        }
        let opds2 = OPDS2Feed(metadata: OPDS2FeedMetadata(title: "Ten Lanes"), groups: groups)
        let feed = CatalogFeed(opds2Feed: opds2)
        let mapped = CatalogViewModel.mapFeed(feed, bookRegistry: bookRegistry())

        XCTAssertEqual(mapped.lanes.count, 10,
                       "Ten non-empty groups must produce exactly ten lanes")
        // Spot-check first and last to defeat off-by-one mutants.
        XCTAssertEqual(mapped.lanes.first?.title, "Lane 0")
        XCTAssertEqual(mapped.lanes.last?.title, "Lane 9")
    }

    // MARK: - 2. EMPTY-GROUP PRUNING

    /// Mutant killed: removing the `guard !books.isEmpty else { continue }`
    /// in `buildOPDS2GroupedContent`. An empty group would otherwise
    /// produce a blank lane, breaking the catalog UI.
    func testMapFeed_GroupWithZeroPublications_IsPrunedFromLanes() throws {
        let groups = [
            makeGroup(title: "Has Books", pubs: [makePub(id: "p1", title: "Real")]),
            makeGroup(title: "Empty Lane", pubs: []),
            makeGroup(title: "Also Has Books", pubs: [makePub(id: "p2", title: "Another")])
        ]
        let opds2 = OPDS2Feed(metadata: OPDS2FeedMetadata(title: "Mixed"), groups: groups)
        let feed = CatalogFeed(opds2Feed: opds2)
        let mapped = CatalogViewModel.mapFeed(feed, bookRegistry: bookRegistry())

        XCTAssertEqual(mapped.lanes.count, 2,
                       "Empty group must be pruned: 3 groups - 1 empty = 2 lanes")
        XCTAssertEqual(mapped.lanes.map(\.title), ["Has Books", "Also Has Books"],
                       "Pruning must preserve the order of the surviving groups")
    }

    /// Mutant killed: pruning ALL groups including non-empty ones (e.g.
    /// flipping `isEmpty` to `!isEmpty`).
    func testMapFeed_AllEmptyGroups_ProducesZeroLanes() throws {
        let groups = (0..<3).map { i in makeGroup(title: "Empty \(i)", pubs: []) }
        let opds2 = OPDS2Feed(metadata: OPDS2FeedMetadata(title: "All Empty"), groups: groups)
        let feed = CatalogFeed(opds2Feed: opds2)
        let mapped = CatalogViewModel.mapFeed(feed, bookRegistry: bookRegistry())

        XCTAssertTrue(mapped.lanes.isEmpty,
                      "All-empty groups must produce zero lanes — never crash or generate phantom lanes")
        XCTAssertTrue(mapped.ungroupedBooks.isEmpty,
                      "Empty grouped feed must not leak publications into ungroupedBooks either")
    }

    // MARK: - 3. PER-LANE BOOK ORDER

    /// Mutant killed: alphabetizing books within a lane, or reversing them.
    /// Feed order is the UX contract for lane content.
    func testMapFeed_BooksWithinLane_PreserveFeedOrder() throws {
        // Deliberately non-alphabetic title order.
        let pubs = [
            makePub(id: "p-z", title: "Z-Book"),
            makePub(id: "p-a", title: "A-Book"),
            makePub(id: "p-m", title: "M-Book")
        ]
        let group = makeGroup(title: "Lane", pubs: pubs)
        let opds2 = OPDS2Feed(metadata: OPDS2FeedMetadata(title: "Order"), groups: [group])
        let feed = CatalogFeed(opds2Feed: opds2)
        let mapped = CatalogViewModel.mapFeed(feed, bookRegistry: bookRegistry())

        let lane = try XCTUnwrap(mapped.lanes.first)
        XCTAssertEqual(lane.books.map(\.title), ["Z-Book", "A-Book", "M-Book"],
                       "Per-lane book order must match the OPDS 2 feed exactly — no sort")
    }

    // MARK: - 4. moreURL HARVESTING

    /// Mutant killed: dropping the `subsection`/`self` lookup so every
    /// lane's moreURL becomes nil — "More" button disappears.
    func testMapFeed_GroupWithSubsectionLink_PopulatesMoreURL() throws {
        let pubs = [makePub(id: "p1", title: "Book")]
        let group = makeGroup(
            title: "Has More",
            pubs: pubs,
            moreURL: URL(string: "https://example.com/lane/full")
        )
        let opds2 = OPDS2Feed(metadata: OPDS2FeedMetadata(title: "T"), groups: [group])
        let feed = CatalogFeed(opds2Feed: opds2)
        let mapped = CatalogViewModel.mapFeed(feed, bookRegistry: bookRegistry())

        XCTAssertEqual(mapped.lanes.first?.moreURL,
                       URL(string: "https://example.com/lane/full"),
                       "Lane moreURL must come from the group's subsection/self link")
    }

    /// Mutant killed: synthesizing a moreURL when none exists. A group
    /// with no subsection link MUST yield a nil moreURL — the "More"
    /// button is suppressed in that case.
    func testMapFeed_GroupWithoutSubsectionLink_HasNilMoreURL() throws {
        let pubs = [makePub(id: "p1", title: "Book")]
        let group = makeGroup(title: "No More", pubs: pubs, moreURL: nil)
        let opds2 = OPDS2Feed(metadata: OPDS2FeedMetadata(title: "T"), groups: [group])
        let feed = CatalogFeed(opds2Feed: opds2)
        let mapped = CatalogViewModel.mapFeed(feed, bookRegistry: bookRegistry())

        XCTAssertNil(mapped.lanes.first?.moreURL,
                     "Group without subsection link must produce nil moreURL — no synthesized URL")
    }

    // MARK: - 5. DEDUPE / SHARED-PUBLICATION SEMANTICS
    //
    // GAP DOCUMENTED: CatalogFeed(opds2Feed:) flattens publications across
    // groups WITHOUT dedupe. We pin the current behavior as a regression
    // guard. A future production change to dedupe should update this test.

    /// Mutant killed: changing the flatten to dedupe by id silently.
    /// Pins current behavior: same publication across two groups produces
    /// two entries in `feed.entries` but ONE book per lane.
    func testMapFeed_SamePublicationInTwoGroups_AppearsInBothLanes() throws {
        let shared = makePub(id: "shared-1", title: "Shared")
        let group1 = makeGroup(title: "New Releases", pubs: [shared])
        let group2 = makeGroup(title: "Staff Picks", pubs: [shared])
        let opds2 = OPDS2Feed(metadata: OPDS2FeedMetadata(title: "Cross"), groups: [group1, group2])
        let feed = CatalogFeed(opds2Feed: opds2)
        let mapped = CatalogViewModel.mapFeed(feed, bookRegistry: bookRegistry())

        XCTAssertEqual(mapped.lanes.count, 2,
                       "A shared publication must NOT collapse the two lanes into one")
        XCTAssertEqual(mapped.lanes[0].books.first?.identifier, "shared-1")
        XCTAssertEqual(mapped.lanes[1].books.first?.identifier, "shared-1",
                       "Both lanes must reference the same shared publication by id")
    }

    /// Mutant killed: deduping in the FLAT entries list. Current code does
    /// NOT dedupe — this is documented behavior. Test pins the current
    /// shape so a silent dedupe doesn't slip in unnoticed.
    func testCatalogFeed_FlatEntries_DoesNotDedupeCrossGroupSharedPublications() throws {
        let shared = makePub(id: "shared-1", title: "Shared")
        let group1 = makeGroup(title: "G1", pubs: [shared])
        let group2 = makeGroup(title: "G2", pubs: [shared])
        let opds2 = OPDS2Feed(metadata: OPDS2FeedMetadata(title: "T"), groups: [group1, group2])
        let feed = CatalogFeed(opds2Feed: opds2)

        let sharedCount = feed.entries.filter { $0.id == "shared-1" }.count
        XCTAssertEqual(sharedCount, 2,
                       "CURRENT BEHAVIOR (documented gap): cross-group duplicates are NOT deduped in feed.entries")
    }

    // MARK: - 6. NAVIGATION-ONLY FEED

    /// Mutant killed: routing a navigation-only feed into the
    /// grouped/publication branches and synthesizing fake lanes.
    func testMapFeed_NavigationOnlyFeed_ProducesNoLanesNoBooks() throws {
        let opds2 = OPDS2Feed(
            metadata: OPDS2FeedMetadata(title: "Top"),
            links: [],
            navigation: [
                OPDS2NavigationLink(href: "/ebooks", title: "Ebooks"),
                OPDS2NavigationLink(href: "/audio", title: "Audiobooks")
            ]
        )
        let feed = CatalogFeed(opds2Feed: opds2)
        let mapped = CatalogViewModel.mapFeed(feed, bookRegistry: bookRegistry())

        XCTAssertTrue(mapped.lanes.isEmpty,
                      "Navigation feed must produce zero lanes")
        XCTAssertTrue(mapped.ungroupedBooks.isEmpty,
                      "Navigation feed must produce zero ungrouped books")
    }

    // MARK: - 7. PUBLICATION-ONLY FEED

    /// Mutant killed: routing a flat publication feed into the lane
    /// builder — pubs would vanish into lanes-by-default and the
    /// ungroupedBooks array would be empty.
    func testMapFeed_PublicationOnlyFeed_AllPubsLandInUngroupedBooks() throws {
        let pubs = (0..<5).map { makePub(id: "p\($0)", title: "Book \($0)", index: $0) }
        let opds2 = OPDS2Feed(
            metadata: OPDS2FeedMetadata(title: "Flat"),
            publications: pubs
        )
        let feed = CatalogFeed(opds2Feed: opds2)
        let mapped = CatalogViewModel.mapFeed(feed, bookRegistry: bookRegistry())

        XCTAssertTrue(mapped.lanes.isEmpty,
                      "Flat publication feed must NOT synthesize lanes")
        XCTAssertEqual(mapped.ungroupedBooks.count, 5,
                       "All 5 publications must land in ungroupedBooks in feed order")
        XCTAssertEqual(mapped.ungroupedBooks.map(\.identifier),
                       ["p0", "p1", "p2", "p3", "p4"],
                       "Ungrouped books must preserve feed order")
    }

    // MARK: - 8. N×M LANE × PUBLICATION CARDINALITY

    /// Mutant killed: a quadratic or off-by-one bug that bleeds books
    /// between lanes (e.g. swapping lane index with publication index).
    func testMapFeed_ThreeGroupsOfFourBooksEach_IsolatesBooksPerLane() throws {
        let groups: [OPDS2Group] = (0..<3).map { groupIdx in
            let pubs = (0..<4).map { pubIdx in
                makePub(
                    id: "g\(groupIdx)-p\(pubIdx)",
                    title: "G\(groupIdx)·P\(pubIdx)",
                    index: groupIdx * 10 + pubIdx
                )
            }
            return makeGroup(title: "Group \(groupIdx)", pubs: pubs)
        }
        let opds2 = OPDS2Feed(metadata: OPDS2FeedMetadata(title: "3x4"), groups: groups)
        let feed = CatalogFeed(opds2Feed: opds2)
        let mapped = CatalogViewModel.mapFeed(feed, bookRegistry: bookRegistry())

        XCTAssertEqual(mapped.lanes.count, 3)
        for (i, lane) in mapped.lanes.enumerated() {
            XCTAssertEqual(lane.books.count, 4,
                           "Lane \(i) must contain exactly 4 books — no bleed from neighbors")
            let ids = lane.books.map(\.identifier)
            let expected = (0..<4).map { "g\(i)-p\($0)" }
            XCTAssertEqual(ids, expected,
                           "Lane \(i) must contain ONLY its own publication ids in order")
        }
        // Flat entries: 3×4 = 12 — pin the total to catch a silent flatten bug.
        XCTAssertEqual(feed.entries.count, 12,
                       "feed.entries must contain 12 (3 groups × 4 pubs) — no dedupe, no loss")
    }
}

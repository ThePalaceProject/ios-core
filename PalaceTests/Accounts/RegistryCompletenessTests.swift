//
//  RegistryCompletenessTests.swift
//  PalaceTests
//
//  PP-5191. The registry's crawlable endpoint pages at 100 over ~1457 libraries.
//  The first-page fast path wrote page 1 VERBATIM over both the on-disk cache and
//  the whole in-memory bucket, so 93% of libraries vanished and a patron whose
//  library sat on page 7 was left with an app that could not name it, could not
//  list it in Settings, and reported them signed out.
//
//  Three pieces answer that, and each is pinned here:
//    - `LibraryCatalogMerger.feedIsPartial`  — is this feed the whole registry?
//    - `AccountRegistryLoader.mergePartialPage` — overlay, never replace
//    - `AccountRegistryStore.replaceBucket` (INV-2) — never lose libraries
//

import XCTest
import PalaceCatalog
@testable import Palace

// `PalaceWiringTestCase` per `TearDownRequiredLintTests`: everything under
// PalaceTests/ takes the base so the tearDown cancel + main-hop flush fire, unless
// explicitly allowlisted with a wall-failure note.
final class RegistryCompletenessTests: PalaceWiringTestCase {

    // MARK: - Fixtures

    private func metadata(count: Int?) -> OPDS2CatalogsFeed.Metadata {
        OPDS2CatalogsFeed.Metadata(adobe_vendor_id: "vendor", title: "Libraries", numberOfItems: count)
    }

    private func publication(_ uuid: String) -> OPDS2Publication {
        OPDS2Publication(links: [], metadata: .init(id: uuid, title: "Library \(uuid)"), images: nil)
    }

    private func account(_ uuid: String) -> Account {
        Account(publication: publication(uuid), imageCache: ImageCache.shared)
    }

    private func feedData(uuids: [String], declaring declared: Int?) -> Data {
        LibraryCatalogMerger.serializeAsCatalogsFeed(
            publications: uuids.map(publication),
            metadata: metadata(count: declared)
        )!
    }

    // MARK: - feedIsPartial

    func testFeedIsPartial_whenCountIsShortOfDeclaredTotal_isPartial() {
        XCTAssertTrue(LibraryCatalogMerger.feedIsPartial(metadata: metadata(count: 1457), catalogCount: 100),
                      "100 rows against a declared 1457 is the exact shape of a page-1 response")
    }

    func testFeedIsPartial_whenCountMatchesDeclaredTotal_isComplete() {
        XCTAssertFalse(LibraryCatalogMerger.feedIsPartial(metadata: metadata(count: 1457), catalogCount: 1457))
    }

    /// The cell that would have emptied the registry for 100% of installs.
    func testFeedIsPartial_whenTotalIsUnknown_isCOMPLETE_notPartial() {
        XCTAssertFalse(LibraryCatalogMerger.feedIsPartial(metadata: metadata(count: nil), catalogCount: 3),
                       "nil must mean COMPLETE. Every already-shipped on-disk cache decodes nil (serializeAsCatalogsFeed did not carry the field), and the direct-GET recovery endpoint never emits it. Reading nil as PARTIAL refuses the app's own cache on the first launch after upgrade.")
    }

    /// Pins the real fixture five Accounts suites are built on, so the rule above
    /// cannot regress without this failing by name.
    func testFeedIsPartial_theCanonicalTestFixtureHasNoDeclaredTotal_andIsTreatedAsComplete() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "OPDS2CatalogsFeed", withExtension: "json"),
                                "OPDS2CatalogsFeed.json must ship in the test bundle")
        let feed = try OPDS2CatalogsFeed.fromData(Data(contentsOf: url))
        XCTAssertNil(feed.metadata.numberOfItems,
                     "Premise: this fixture declares no total")
        XCTAssertFalse(LibraryCatalogMerger.feedIsPartial(feed),
                       "…and must therefore be COMPLETE, or AccountsManagerCacheReadTests / …LaunchSnapshotTests / …StateMachineWiringTests all break")
    }

    // MARK: - mergePartialPage

    func testMergePartialPage_overlaysOntoExisting_keepingLibrariesAbsentFromThePage() throws {
        let existing = feedData(uuids: ["a", "b", "c"], declaring: 3)
        let page = feedData(uuids: ["d"], declaring: 4)

        let merged = try XCTUnwrap(AccountRegistryLoader.mergePartialPage(page, into: existing))
        let feed = try OPDS2CatalogsFeed.fromData(merged)

        XCTAssertEqual(Set(feed.catalogs.map(\.metadata.id)), ["a", "b", "c", "d"],
                       "A partial page must ADD to the registry, never replace it — this is the defect in one assertion")
    }

    func testMergePartialPage_emitsTheNetworkPagesDeclaredTotal_notTheBases() throws {
        // The shipped shape: a 1142-row bundled base (declaring 1142, i.e. complete)
        // overlaid with a page declaring the true 1457.
        let existing = feedData(uuids: ["a", "b", "c"], declaring: 3)
        let page = feedData(uuids: ["d"], declaring: 1457)

        let merged = try XCTUnwrap(AccountRegistryLoader.mergePartialPage(page, into: existing))
        let feed = try OPDS2CatalogsFeed.fromData(merged)

        XCTAssertEqual(feed.metadata.numberOfItems, 1457,
                       "Inheriting the base's total would declare a 4-row feed complete and defeat every downstream completeness check")
        XCTAssertTrue(LibraryCatalogMerger.feedIsPartial(feed),
                      "A merged-but-still-short registry must remain PARTIAL")
    }

    func testMergePartialPage_whenNothingCached_passesThePageThrough() throws {
        let page = feedData(uuids: ["d"], declaring: 1457)
        let merged = try XCTUnwrap(AccountRegistryLoader.mergePartialPage(page, into: nil))
        XCTAssertEqual(try OPDS2CatalogsFeed.fromData(merged).catalogs.count, 1)
    }

    func testMergePartialPage_whenBytesAreMalformed_returnsNilSoCallerFallsBack() {
        XCTAssertNil(AccountRegistryLoader.mergePartialPage(Data("not json".utf8), into: nil))
    }

    // MARK: - INV-2 (AccountRegistryStore.replaceBucket)

    private func store(seeded uuids: [String], hash: String = "h") -> AccountRegistryStore {
        let store = AccountRegistryStore(currentHash: hash)
        if !uuids.isEmpty {
            XCTAssertTrue(store.replaceBucket(hash: hash, accounts: uuids.map(account), isCompleteFeed: true))
        }
        return store
    }

    func testINV2_emptyResident_acceptsEvenAPartialWrite() {
        let store = self.store(seeded: [])
        XCTAssertTrue(store.replaceBucket(hash: "h", accounts: [account("a")], isCompleteFeed: false),
                      "Refusing here would leave the registry EMPTY, which is worse than short")
    }

    /// The cell an earlier revision got wrong: it refused this changeset's own fix.
    func testINV2_supersetOverCompleteResident_isAccepted_evenThoughIncomingIsPartial() {
        let store = self.store(seeded: ["a", "b", "c"])
        XCTAssertTrue(
            store.replaceBucket(hash: "h", accounts: ["a", "b", "c", "d"].map(account), isCompleteFeed: false),
            "The merged page-1 superset declares the network total and so reads PARTIAL — but it removes nothing, and refusing it rejects the fix itself"
        )
        XCTAssertNotNil(store.account("d"))
    }

    func testINV2_lossyPartialWrite_isRefused_andResidentSurvives() {
        let store = self.store(seeded: ["a", "b", "c"])
        XCTAssertFalse(store.replaceBucket(hash: "h", accounts: [account("a")], isCompleteFeed: false),
                       "Page 1 over a populated registry is exactly the defect")
        XCTAssertEqual(store.accounts(forKey: "h").count, 3, "the resident registry must survive intact")
        XCTAssertNotNil(store.account("c"), "a library dropped by the refused write must still resolve")
    }

    func testINV2_lossyWrite_isAppliedWhenTheFeedIsPositivelyComplete() {
        let store = self.store(seeded: ["a", "b", "c"])
        XCTAssertTrue(store.replaceBucket(hash: "h", accounts: ["a", "b"].map(account), isCompleteFeed: true),
                      "A genuine deletion reconcile must still be able to remove libraries")
        XCTAssertNil(store.account("c"))
    }

    /// Equal counts can still drop uuids — which is why the rule is set-based and a
    /// `count >=` proxy was rejected.
    func testINV2_sameSizeWriteThatSwapsALibrary_isRefusedWhenNotComplete() {
        let store = self.store(seeded: ["a", "b", "c"])
        XCTAssertFalse(store.replaceBucket(hash: "h", accounts: ["a", "b", "z"].map(account), isCompleteFeed: false),
                       "Same count, but 'c' is gone — a size comparison would wave this through")
        XCTAssertNotNil(store.account("c"))
    }

    // MARK: - Positive completeness (A-5): what may DELETE

    func testPositivelyComplete_requiresADeclaredTotalThatMatches() {
        XCTAssertTrue(LibraryCatalogMerger.feedIsPositivelyComplete(metadata: metadata(count: 3), catalogCount: 3))
        XCTAssertFalse(LibraryCatalogMerger.feedIsPositivelyComplete(metadata: metadata(count: 4), catalogCount: 3))
    }

    /// The distinction that exists so a nil-metadata feed cannot delete libraries.
    /// `feedIsPartial` says nil is "not known to be short" — correct, and it is why a
    /// legacy cache still hydrates. `feedIsPositivelyComplete` says nil is NOT proof of
    /// completeness — which is what removals require.
    func testPositivelyComplete_isNotTheNegationOfPartial_whenTheTotalIsUnknown() {
        let unknown = metadata(count: nil)
        XCTAssertFalse(LibraryCatalogMerger.feedIsPartial(metadata: unknown, catalogCount: 3),
                       "unknown provenance is trusted for the purpose of not REFUSING")
        XCTAssertFalse(LibraryCatalogMerger.feedIsPositivelyComplete(metadata: unknown, catalogCount: 3),
                       "…but it is NOT proof of completeness, and only proof may license a delete. Collapsing these two into `!feedIsPartial` hands delete authority to the direct-GET recovery endpoint, which carries no numberOfItems at all.")
    }

    func testINV2_nilMetadataFeedMayNotDeleteLibraries() {
        let store = self.store(seeded: ["a", "b", "c"])
        let unknown = metadata(count: nil)
        let complete = LibraryCatalogMerger.feedIsPositivelyComplete(metadata: unknown, catalogCount: 1)

        XCTAssertFalse(store.replaceBucket(hash: "h", accounts: [account("a")], isCompleteFeed: complete),
                       "A feed that never said how big the registry is must not be able to shrink it to one library")
        XCTAssertNotNil(store.account("c"))
    }

    func testINV2_nilMetadataFeedThatRemovesNothing_isStillApplied() {
        let store = self.store(seeded: ["a", "b", "c"])
        let unknown = metadata(count: nil)
        let complete = LibraryCatalogMerger.feedIsPositivelyComplete(metadata: unknown, catalogCount: 4)

        XCTAssertTrue(store.replaceBucket(hash: "h", accounts: ["a", "b", "c", "d"].map(account), isCompleteFeed: complete),
                      "…but it must still be able to ADD. Legacy caches and the 171-row fixture carry no total and must keep hydrating normally.")
        XCTAssertNotNil(store.account("d"))
    }

    // MARK: - mergePartialPage: the page's row wins on conflict

    func testMergePartialPage_pageEntryReplacesTheStaleBaseEntry() throws {
        let stale = try XCTUnwrap(LibraryCatalogMerger.serializeAsCatalogsFeed(
            publications: [OPDS2Publication(links: [], metadata: .init(id: "a", title: "OLD NAME"), images: nil)],
            metadata: metadata(count: 1)))
        let page = try XCTUnwrap(LibraryCatalogMerger.serializeAsCatalogsFeed(
            publications: [OPDS2Publication(links: [], metadata: .init(id: "a", title: "NEW NAME"), images: nil)],
            metadata: metadata(count: 1457)))

        let merged = try XCTUnwrap(AccountRegistryLoader.mergePartialPage(page, into: stale))
        let feed = try OPDS2CatalogsFeed.fromData(merged)

        XCTAssertEqual(feed.catalogs.count, 1)
        XCTAssertEqual(feed.catalogs.first?.metadata.title, "NEW NAME",
                       "page 1 is ordered by `modified` — it exists to carry the FRESH row, so on conflict it must win. Swapping the merge arguments would silently keep the stale one.")
    }

    func testINV2_readsOnlyItsOwnBucket_notTheFlattenedIndex() {
        let store = AccountRegistryStore(currentHash: "h1")
        XCTAssertTrue(store.replaceBucket(hash: "h1", accounts: ["a", "b"].map(account), isCompleteFeed: true))
        XCTAssertTrue(store.replaceBucket(hash: "h2", accounts: [account("z")], isCompleteFeed: false),
                      "h2 is empty; h1's libraries must not be read as h2's resident set (the flattened uuid index spans every bucket)")
    }
}

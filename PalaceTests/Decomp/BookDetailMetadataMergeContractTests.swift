//
//  BookDetailMetadataMergeContractTests.swift
//  PalaceTests
//
//  God-class decomposition — pin-before-extract pack for
//  `Palace/Book/UI/BookDetail/BookDetailViewModel.swift`, MOVING cluster
//  "Metadata hydration" (plan §3a-4 / §5). Per the plan, the metadata-hydration
//  service work (`BookMetadataService`) leaves the VM; these tests lock the
//  field-by-field MERGE PRECEDENCE and the post-fetch decision logic so the
//  extraction cannot silently change which side (current vs freshly-fetched)
//  wins for any book field.
//
//  ADDITIVE — does NOT overlap `PalaceTests/ViewModels/BookDetailMetadataHydrationTests`,
//  which already pins publisher/distributor/category/published/audience/language
//  fill-from-fresh + the trigger guards. This file pins the SEVEN merge fields
//  those tests never assert (summary, subtitle, seriesName, seriesURL,
//  bookDuration) in BOTH directions (empty→take fresh, non-empty→preserve
//  current), the identity-preservation invariant (title/identifier are NEVER
//  taken from fresh), and the two post-fetch branches (hydrator returns nil /
//  throws) that the existing guard-tests never reach because they short-circuit
//  before the fetch.
//
//  SEAM: the DEFAULT hydrator in BookDetailViewModel.init (lines ~216-224) —
//  `opdsFeedService.fetchFeed(...) -> first TPPOPDSEntry -> TPPBook(entry:)` — is
//  the actual network service work being extracted. It captures the CONCRETE
//  `OPDSFeedService` actor + `accountsManager` inside a closure and is not
//  independently unit-pinnable (HTTPStubURLProtocol cannot reliably intercept
//  `TPPOPDSFeed.withURL`'s Obj-C bridge). The `BookMetadataService` extraction
//  should take an `OPDSFeedFetching` protocol so fetch→parse→first-entry→TPPBook
//  is stubbable. These tests pin the deterministic merge/decision core reached
//  via the injectable `metadataHydrator` seam; the raw fetch stays behind the
//  seam.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalacePreferences
import PalaceCatalog
@testable import Palace
import PalaceBookModel

@MainActor
final class BookDetailMetadataMergeContractTests: XCTestCase {

    private let alternateURL = URL(string: "https://example.org/works/merge")!

    private var appContainer: AppContainer!

    override func setUp() {
        super.setUp()
        appContainer = makeTestAppContainer()
    }

    override func tearDown() {
        appContainer = nil
        super.tearDown()
    }

    // MARK: - Merge precedence: empty/nil current → take freshly-fetched value

    /// Every field the existing hydration suite does NOT assert, driven through
    /// its EMPTY-current branch. mergeHydratedMetadata uses two distinct rules —
    /// empty-string check (summary/seriesName/bookDuration) and nil-coalesce
    /// (subtitle/seriesURL). Both must fall to `fresh` when current is blank.
    ///
    /// Mutation: flipping any of these ternaries / `??` operands to keep the
    /// blank current value makes the corresponding assertion fail.
    func testMerge_whenCurrentFieldsBlank_takesFreshValues() async {
        let sparse = makeBook(
            identifier: "merge-empty",
            title: "Current Title",
            summary: "",              // empty-string → empty-check branch
            subtitle: nil,            // nil → nil-coalesce branch
            seriesName: nil,          // nil → empty-check branch (isEmpty ?? true)
            seriesURL: nil,           // nil → nil-coalesce branch
            bookDuration: nil         // nil → empty-check branch
        )
        let fresh = makeBook(
            identifier: "ignored-fresh-id",
            title: "Fresh Title",
            // gate fields populated so `fresh` is a fully-hydrated entry
            published: iso("2015-08-04"),
            publisher: "Fresh Publisher",
            distributor: "Fresh Distributor",
            categoryStrings: ["Fresh Category"],
            summary: "Fresh summary",
            subtitle: "Fresh subtitle",
            seriesName: "Dune",
            seriesURL: URL(string: "https://example.org/series/dune")!,
            bookDuration: "03:20:00"
        )

        let vm = makeVM(book: sparse, hydrator: { _ in fresh })
        await vm.hydrateMetadataIfNeeded()

        XCTAssertEqual(vm.book.summary, "Fresh summary",
                       "Empty current summary must be filled from the fetched entry")
        XCTAssertEqual(vm.book.subtitle, "Fresh subtitle",
                       "Nil current subtitle must be filled from the fetched entry")
        XCTAssertEqual(vm.book.seriesName, "Dune",
                       "Nil current seriesName must be filled — this drives the PP-4775 series row")
        XCTAssertEqual(vm.book.seriesURL, URL(string: "https://example.org/series/dune")!,
                       "Nil current seriesURL must be filled so the series row can become a link")
        XCTAssertEqual(vm.book.bookDuration, "03:20:00",
                       "Nil current bookDuration must be filled from the fetched entry")
    }

    // MARK: - Merge precedence: non-empty current → preserve, ignore fresh

    /// The other direction: when current already holds a value, hydration must
    /// NOT clobber it with the fetched entry — hydration only fills gaps.
    ///
    /// Mutation: swapping any ternary/`??` so `fresh` wins over a non-empty
    /// current value makes the corresponding assertion fail (a real regression:
    /// it would overwrite catalog-provided metadata with lane-feed data).
    func testMerge_whenCurrentFieldsPresent_preservesThemOverFresh() async {
        let origSeriesURL = URL(string: "https://example.org/series/original")!
        let populated = makeBook(
            identifier: "merge-preserve",
            title: "Current Title",
            summary: "Original summary",
            subtitle: "Original subtitle",
            seriesName: "Original Series",
            seriesURL: origSeriesURL,
            bookDuration: "01:00:00"
            // gate fields (published/publisher/distributor/category/audience/
            // language) LEFT EMPTY so needsMetadataHydration still fires
        )
        let fresh = makeBook(
            identifier: "ignored-fresh-id",
            title: "Fresh Title",
            published: iso("2015-08-04"),
            publisher: "Fresh Publisher",
            distributor: "Fresh Distributor",
            categoryStrings: ["Fresh Category"],
            summary: "SHOULD NOT WIN",
            subtitle: "SHOULD NOT WIN",
            seriesName: "SHOULD NOT WIN",
            seriesURL: URL(string: "https://example.org/series/wrong")!,
            bookDuration: "99:99:99"
        )

        let vm = makeVM(book: populated, hydrator: { _ in fresh })
        await vm.hydrateMetadataIfNeeded()

        XCTAssertEqual(vm.book.summary, "Original summary",
                       "Non-empty current summary must survive hydration")
        XCTAssertEqual(vm.book.subtitle, "Original subtitle",
                       "Non-nil current subtitle must survive hydration")
        XCTAssertEqual(vm.book.seriesName, "Original Series",
                       "Non-empty current seriesName must survive hydration")
        XCTAssertEqual(vm.book.seriesURL, origSeriesURL,
                       "Non-nil current seriesURL must survive hydration")
        XCTAssertEqual(vm.book.bookDuration, "01:00:00",
                       "Non-empty current bookDuration must survive hydration")

        // ...but the actually-empty gate fields DID fill from fresh — proving the
        // merge ran and the preserve above is real, not a no-op short-circuit.
        XCTAssertEqual(vm.book.publisher, "Fresh Publisher",
                       "Gate fields that were empty must still fill — the merge did run")
    }

    // MARK: - Identity invariant: title/identifier are NEVER taken from fresh

    /// mergeHydratedMetadata always keeps `current.identifier` and `current.title`
    /// regardless of what the fetched entry carries. A silent extraction that
    /// takes `fresh.identifier` here would corrupt the registry key and mis-route
    /// every subsequent state read — the highest-cost mutation on this path.
    func testMerge_identityFields_neverTakenFromFresh() async {
        let sparse = makeBook(identifier: "keep-this-id", title: "Keep This Title")
        let fresh = makeBook(
            identifier: "WRONG-id",
            title: "WRONG Title",
            published: iso("2015-08-04"),
            publisher: "Fresh Publisher",
            distributor: "Fresh Distributor",
            categoryStrings: ["Fresh Category"]
        )

        let vm = makeVM(book: sparse, hydrator: { _ in fresh })
        await vm.hydrateMetadataIfNeeded()

        XCTAssertEqual(vm.book.identifier, "keep-this-id",
                       "Hydration must NEVER replace the book identifier — it is the registry key")
        XCTAssertEqual(vm.book.title, "Keep This Title",
                       "Hydration must NEVER replace the title from the lane-feed entry")
    }

    // MARK: - Post-fetch decision: hydrator returns nil → no mutation

    /// The `guard let fresh = try await metadataHydrator(url) else { return }`
    /// branch. The existing guard-tests never reach the fetch (they assert the
    /// hydrator is not CALLED). Here the hydrator IS called and returns nil (a
    /// feed with no usable entry); the book must be left untouched.
    ///
    /// Mutation: removing that guard would force-merge a nil `fresh` (crash) or
    /// blank the book — either way this fails.
    func testHydrate_whenHydratorReturnsNil_leavesBookUnchanged() async {
        let sparse = makeBook(identifier: "nil-fetch", title: "Untouched", summary: "keep me")
        var fetched = false

        let vm = makeVM(book: sparse, hydrator: { _ in fetched = true; return nil })
        await vm.hydrateMetadataIfNeeded()

        XCTAssertTrue(fetched, "Precondition: the fetch was actually attempted (guard reached)")
        XCTAssertNil(vm.book.publisher, "A nil fetch result must not populate any field")
        XCTAssertEqual(vm.book.summary, "keep me", "A nil fetch result must not blank existing fields")
        XCTAssertEqual(vm.book.identifier, "nil-fetch")
    }

    // MARK: - Post-fetch decision: hydrator throws → caught, no mutation

    /// The `catch { Log.warn(...) }` branch. A network/parse failure during
    /// hydration must be swallowed and leave the book intact — hydration is
    /// best-effort enrichment, never a hard failure of the detail view.
    ///
    /// Mutation: dropping the do/catch would let the throw escape the async
    /// method and fail the test.
    func testHydrate_whenHydratorThrows_isSwallowedAndBookUnchanged() async {
        let sparse = makeBook(identifier: "throwing-fetch", title: "Still Here", summary: "still summary")

        let vm = makeVM(book: sparse, hydrator: { _ in throw MergeTestError.boom })
        await vm.hydrateMetadataIfNeeded()

        XCTAssertNil(vm.book.publisher, "A thrown fetch must not populate any field")
        XCTAssertEqual(vm.book.summary, "still summary", "A thrown fetch must not blank existing fields")
        XCTAssertEqual(vm.book.identifier, "throwing-fetch", "The book survives a thrown fetch intact")
    }

    // MARK: - Helpers

    private enum MergeTestError: Error { case boom }

    private func makeVM(book: TPPBook, hydrator: @escaping (URL) async throws -> TPPBook?) -> BookDetailViewModel {
        BookDetailViewModel(
            book: book,
            registry: TPPBookRegistryMock(),
            downloadCenter: appContainer.downloadCenter,
            accountsManager: appContainer.accountsManager,
            settings: TPPSettings(),
            opdsFeedService: appContainer.opdsFeedService,
            samplePreviewManager: appContainer.samplePreviewManager,
            readerService: appContainer.readerService,
            metadataHydrator: hydrator
        )
    }

    private func iso(_ s: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.date(from: s)!
    }

    /// Full-fidelity TPPBook factory mirroring the production initializer used by
    /// `mergeHydratedMetadata` (BookDetailViewModel.swift:558-589). Gate fields
    /// (published/publisher/distributor/categoryStrings/audience/language) default
    /// to empty so `needsMetadataHydration` fires unless a test overrides them.
    ///
    /// VERIFY: keep in sync with `TPPBook.init` (TPPBook.swift:122-150) — includes
    /// the `seriesName:` label the existing test helper omits.
    private func makeBook(
        identifier: String,
        title: String,
        published: Date? = nil,
        publisher: String? = nil,
        distributor: String? = nil,
        categoryStrings: [String]? = nil,
        summary: String? = nil,
        subtitle: String? = nil,
        seriesName: String? = nil,
        seriesURL: URL? = nil,
        bookDuration: String? = nil,
        audience: String? = nil,
        language: String? = nil,
        alternateURL: URL? = URL(string: "https://example.org/works/merge")!
    ) -> TPPBook {
        let acquisition = TPPOPDSAcquisition(
            relation: .generic,
            type: "application/epub+zip",
            hrefURL: URL(string: "https://example.org/acq/\(identifier)")!,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        return TPPBook(
            acquisitions: [acquisition],
            authors: [TPPBookAuthor(authorName: "Author", relatedBooksURL: nil)],
            categoryStrings: categoryStrings,
            distributor: distributor,
            identifier: identifier,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: published,
            publisher: publisher,
            subtitle: subtitle,
            summary: summary,
            title: title,
            updated: Date(timeIntervalSince1970: 1_700_000_000),
            annotationsURL: nil,
            analyticsURL: nil,
            alternateURL: alternateURL,
            relatedWorksURL: nil,
            previewLink: nil,
            seriesURL: seriesURL,
            seriesName: seriesName,
            revokeURL: nil,
            reportURL: nil,
            timeTrackingURL: nil,
            contributors: nil,
            bookDuration: bookDuration,
            audience: audience,
            language: language,
            imageCache: MockImageCache()
        )
    }
}

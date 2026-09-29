//
//  BookDetailMetadataHydrationGuardTests.swift
//  PalaceTests
//
//  Wave 5 pin-before-extract — the POST-AWAIT half of
//  `BookDetailViewModel.hydrateMetadataIfNeeded()`, written against the code as
//  it stands BEFORE the `BookMetadataService` extraction (plan §3a-4 / §5).
//
//  WHAT WAS NOT PINNED BEFORE THIS FILE
//
//  `BookDetailMetadataHydrationTests` pins the PRE-fetch guards (already
//  hydrated / no alternateURL) and the field fill-in;
//  `BookDetailMetadataMergeContractTests` pins the merge precedence and the two
//  failure branches. Neither reaches the three effects that happen AFTER the
//  hydrator resumes, all of which the extraction has to carry across:
//
//    1. the merged book is written back through `registry.updatedBookMetadata`
//       (not the current book, and not the freshly-fetched one),
//    2. the identity re-check — a book swapped while the fetch is in flight
//       discards the in-flight merge,
//    3. the needs-hydration re-check — a book that became hydrated while the
//       fetch was in flight is not merged a second time.
//
//  Guards 2 and 3 are the reason `hydrateMetadataIfNeeded` re-evaluates both
//  conditions after the `await`, and nothing held them: a mutant deleting either
//  `guard` line left every metadata test green before this file existed.
//
//  Both are driven with a hydrator that SUSPENDS until the test resumes it, so
//  the interleaving is deterministic rather than raced against a sleep.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import PalacePreferences
import PalaceCatalog
@testable import Palace
import PalaceBookModel
import PalaceBookRegistry

@MainActor
final class BookDetailMetadataHydrationGuardTests: XCTestCase {

    private let alternateURL = URL(string: "https://example.org/works/guarded")!
    private var appContainer: AppContainer!

    override func setUp() {
        super.setUp()
        appContainer = makeTestAppContainer()
    }

    override func tearDown() {
        appContainer = nil
        super.tearDown()
    }

    // MARK: - 1. The registry write-back

    /// A successful hydration must hand the MERGED book to
    /// `registry.updatedBookMetadata`. The distinguishing fixture: the current
    /// book carries a title and acquisitions the fresh entry does not, and the
    /// fresh entry carries a publisher the current book does not — so the
    /// merged value is the only one that has both.
    ///
    /// Mutation: passing `fresh` instead of `merged` loses the title; passing
    /// `book` (the pre-merge value) loses the publisher; deleting the call
    /// leaves `recordedMetadataWrites` empty. All three fail here.
    func testHydrate_onSuccess_writesTheMergedBookBackToTheRegistry() async {
        let sparse = makeSparseBook(identifier: "write-back", title: "Kept Title")
        let fresh = makeHydratedBook(identifier: "write-back", title: "Server Title",
                                     publisher: "Fresh Publisher")

        let registry = RecordingMetadataRegistry()
        registry.addBook(sparse, location: nil, state: .downloadSuccessful,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
        let vm = makeVM(book: sparse, registry: registry) { _ in fresh }

        await vm.hydrateMetadataIfNeeded()

        XCTAssertEqual(registry.recordedMetadataWrites.count, 1,
                       "A successful hydration must write back exactly once")
        let written = registry.recordedMetadataWrites.first
        XCTAssertEqual(written?.title, "Kept Title",
                       "The write-back must carry the CURRENT book's title — the merge never takes identity fields from the fetched entry")
        XCTAssertEqual(written?.publisher, "Fresh Publisher",
                       "The write-back must carry the FETCHED publisher — otherwise the pre-merge book was written and hydration reaches no consumer")
    }

    /// The negative for the same cell: when the pre-fetch guard short-circuits
    /// (the book is already hydrated), nothing is written back.
    ///
    /// Mutation: hoisting the registry write above the guard makes this fail.
    func testHydrate_whenAlreadyHydrated_writesNothingToTheRegistry() async {
        let hydrated = makeHydratedBook(identifier: "no-write", title: "Complete",
                                        publisher: "Publisher")
        let registry = RecordingMetadataRegistry()
        registry.addBook(hydrated, location: nil, state: .downloadSuccessful,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
        var hydratorCalls = 0
        let vm = makeVM(book: hydrated, registry: registry) { _ in
            hydratorCalls += 1
            return nil
        }

        await vm.hydrateMetadataIfNeeded()

        XCTAssertEqual(hydratorCalls, 0, "precondition: the pre-fetch guard must short-circuit")
        XCTAssertTrue(registry.recordedMetadataWrites.isEmpty,
                      "A short-circuited hydration must not touch the registry")
    }

    // MARK: - 2. The identity re-check

    /// If the view model navigates to a DIFFERENT book while the hydrator is
    /// suspended, the resumed merge belongs to a book that is no longer on
    /// screen and must be discarded: `vm.book` stays the newly-selected book and
    /// the registry receives no write.
    ///
    /// Mutation: deleting `guard book.identifier == targetIdentifier` makes the
    /// stale fetch overwrite `vm.book` with the previous title, and both
    /// assertions fail.
    func testHydrate_whenBookChangesDuringFetch_discardsTheInFlightMerge() async {
        let original = makeSparseBook(identifier: "original", title: "Original Title")
        let replacement = makeSparseBook(identifier: "replacement", title: "Replacement Title")
        let fresh = makeHydratedBook(identifier: "original", title: "Original Title",
                                     publisher: "Stale Publisher")

        let registry = RecordingMetadataRegistry()
        for b in [original, replacement] {
            registry.addBook(b, location: nil, state: .downloadSuccessful,
                             fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
        }

        let gate = HydratorGate()
        let vm = makeVM(book: original, registry: registry) { _ in
            await gate.waitForRelease()
            return fresh
        }

        let hydration = Task { await vm.hydrateMetadataIfNeeded() }
        await gate.waitUntilEntered()

        // Swap the book while the fetch is suspended — the exact interleaving
        // the post-await identity guard exists for.
        vm.selectRelatedBook(replacement)
        await gate.release()
        await hydration.value

        XCTAssertEqual(vm.book.identifier, "replacement",
                       "The stale hydration must not replace the newly-selected book")
        XCTAssertEqual(vm.book.title, "Replacement Title",
                       "The stale hydration must not overwrite the newly-selected book's fields")
        XCTAssertTrue(registry.recordedMetadataWrites.isEmpty,
                      "A discarded merge must not be written back to the registry either")
    }

    // MARK: - 3. The needs-hydration re-check

    /// If the book on screen became fully hydrated while the fetch was in
    /// flight — same identifier, different content, e.g. a registry emission
    /// landing mid-fetch — the resumed merge must not run a second time.
    ///
    /// Mutation: deleting the second `guard Self.needsMetadataHydration(book)`
    /// lets the stale fetch re-merge, replacing the already-correct publisher
    /// with the stale one and writing to the registry.
    func testHydrate_whenBookBecomesHydratedDuringFetch_doesNotMergeASecondTime() async {
        let sparse = makeSparseBook(identifier: "racing", title: "Racing Title")
        let staleFresh = makeHydratedBook(identifier: "racing", title: "Racing Title",
                                          publisher: "Stale Publisher")
        let arrivedHydrated = makeHydratedBook(identifier: "racing", title: "Racing Title",
                                               publisher: "Authoritative Publisher")

        let registry = RecordingMetadataRegistry()
        registry.addBook(sparse, location: nil, state: .downloadSuccessful,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        let gate = HydratorGate()
        let vm = makeVM(book: sparse, registry: registry) { _ in
            await gate.waitForRelease()
            return staleFresh
        }

        let hydration = Task { await vm.hydrateMetadataIfNeeded() }
        await gate.waitUntilEntered()

        // Same identifier, now fully populated — the identity guard passes and
        // only the needs-hydration re-check can stop the merge.
        vm.book = arrivedHydrated
        await gate.release()
        await hydration.value

        XCTAssertEqual(vm.book.publisher, "Authoritative Publisher",
                       "A book that became hydrated mid-fetch must keep the value that arrived, not the one the stale fetch carried")
        XCTAssertTrue(registry.recordedMetadataWrites.isEmpty,
                      "A re-check that short-circuits must not write back")
    }

    // MARK: - Helpers

    private func makeVM(book: TPPBook,
                        registry: TPPBookRegistryProvider,
                        hydrator: @escaping BookDetailViewModel.BookMetadataHydrator) -> BookDetailViewModel {
        BookDetailViewModel(
            book: book,
            registry: registry,
            downloadCenter: appContainer.downloadCenter,
            accountsManager: appContainer.accountsManager,
            settings: TPPSettings(),
            opdsFeedService: appContainer.opdsFeedService,
            samplePreviewManager: appContainer.samplePreviewManager,
            readerService: appContainer.readerService,
            metadataHydrator: hydrator
        )
    }

    /// Every field `needsMetadataHydration` inspects is blank, and `alternateURL`
    /// is present — so hydration proceeds.
    private func makeSparseBook(identifier: String, title: String) -> TPPBook {
        makeBook(identifier: identifier, title: title, published: nil, publisher: nil,
                 distributor: nil, categoryStrings: [], audience: nil, language: nil)
    }

    /// Fully populated — `needsMetadataHydration` is false.
    private func makeHydratedBook(identifier: String, title: String, publisher: String) -> TPPBook {
        makeBook(identifier: identifier, title: title, published: Date(timeIntervalSince1970: 0),
                 publisher: publisher, distributor: "Distributor",
                 categoryStrings: ["Fiction"], audience: "Adult", language: "en")
    }

    private func makeBook(identifier: String,
                          title: String,
                          published: Date?,
                          publisher: String?,
                          distributor: String?,
                          categoryStrings: [String],
                          audience: String?,
                          language: String?) -> TPPBook {
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
            subtitle: nil,
            summary: nil,
            title: title,
            updated: Date(timeIntervalSince1970: 0),
            annotationsURL: nil,
            analyticsURL: nil,
            alternateURL: alternateURL,
            relatedWorksURL: nil,
            previewLink: nil,
            seriesURL: nil,
            seriesName: nil,
            revokeURL: nil,
            reportURL: nil,
            timeTrackingURL: nil,
            contributors: [:],
            bookDuration: nil,
            audience: audience,
            language: language,
            imageCache: MockImageCache()
        )
    }
}

// MARK: - Doubles

/// `TPPBookRegistryMock` returns the stored record from `updatedBookMetadata`
/// but records nothing, so the write-back was unobservable. This subclass keeps
/// the mock's behaviour and records the argument.
private final class RecordingMetadataRegistry: TPPBookRegistryMock {
    private(set) var recordedMetadataWrites: [TPPBook] = []

    override func updatedBookMetadata(_ book: TPPBook) -> TPPBook? {
        recordedMetadataWrites.append(book)
        return super.updatedBookMetadata(book)
    }
}

/// Deterministic suspend/resume gate for the hydrator. The test waits until the
/// hydrator has ENTERED (so the interleaving it wants to create is real, not a
/// hoped-for race), mutates the view model, then releases.
///
/// `awaitConditionAsync`-style barriers can be inert when the predicate is
/// already true; this one cannot, because `waitUntilEntered` only completes
/// after the hydrator itself signals entry.
private actor HydratorGate {
    private var enteredContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var hasEntered = false
    private var isReleased = false

    func waitForRelease() async {
        hasEntered = true
        for c in enteredContinuations { c.resume() }
        enteredContinuations.removeAll()
        if isReleased { return }
        await withCheckedContinuation { releaseContinuations.append($0) }
    }

    func waitUntilEntered() async {
        if hasEntered { return }
        await withCheckedContinuation { enteredContinuations.append($0) }
    }

    func release() {
        isReleased = true
        for c in releaseContinuations { c.resume() }
        releaseContinuations.removeAll()
    }
}

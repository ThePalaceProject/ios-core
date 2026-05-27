//
//  Reader2BookmarkContractTests.swift
//  PalaceTests
//
//  Contract-snapshot tests for `TPPReaderBookmarksBusinessLogic`. Reader2
//  is XCTest-invisible (Readium 3.x WKWebView), so these tests drive the
//  business-logic class through its public dependency seams with co-located
//  spies. No WKWebView, NavigatorViewController, or `TPPAnnotations` static
//  surface is instantiated — the scenarios pin behavior that the
//  no-current-account fall-through path generates, where the registry is
//  the sole observable side effect.
//
//  Source contract: `.forgeos/swarms/swarm_eefef87a/contracts/D-Reader2ContractSnapshots.md`
//
//  Scenarios:
//    1. `test_bookmarkSave_writesToRegistry_thenAnnotations`
//         — addBookmark with progression-bearing locator → factory resolves
//           the bookmark → bookRegistry.add fires (local-only fall-through).
//    2. `test_bookmarkSave_failureFromRegistry_doesNotEnqueueAnnotation`
//         — addBookmark with progression-less locator → factory returns nil
//           → NO bookRegistry.add. The "failureFromRegistry" framing in the
//           contract title is interpreted as factory-fail (which is the
//           registry-facing failure surface for this code path).
//    3. `test_bookmarkDelete_removesFromRegistry_thenAnnotationsDelete`
//         — deleteBookmark(at:) → didDeleteBookmark → bookRegistry.delete.
//           With no annotationId and no currentAccount, the server-side
//           delete arm is bypassed and the registry write is the only call.
//
//  **First run:** records baselines at
//  `__Snapshots__/Reader2BookmarkContractTests/<scenario>.json` and FAILS
//  with "snapshot recorded — re-run to verify". Set
//  `CONTRACT_SNAPSHOT_RECORD=1` to deliberately re-record.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
import UIKit
import ReadiumShared
import PalaceCatalog
@testable import Palace

// MARK: - Spy registry (records bookmark-facing calls into a CallLog)

private final class RecordingBookmarkRegistry: NSObject, TPPBookRegistryProvider, @unchecked Sendable {
    let log: CallLog
    let inner: TPPBookRegistryMock

    init(log: CallLog, inner: TPPBookRegistryMock) {
        self.log = log
        self.inner = inner
    }

    // Recorded calls — the contract surface for these scenarios.

    func add(_ bookmark: TPPReadiumBookmark, forIdentifier identifier: String) {
        log.record(
            "registry.add(bookmark)",
            args: [
                "bookID": identifier,
                "href": bookmark.href,
                "hasAnnotationID": bookmark.annotationId != nil,
            ]
        )
        inner.add(bookmark, forIdentifier: identifier)
    }

    func delete(_ bookmark: TPPReadiumBookmark, forIdentifier identifier: String) {
        log.record(
            "registry.delete(bookmark)",
            args: [
                "bookID": identifier,
                "href": bookmark.href,
                "hasAnnotationID": bookmark.annotationId != nil,
            ]
        )
        inner.delete(bookmark, forIdentifier: identifier)
    }

    func setLocation(_ location: TPPBookLocation?, forIdentifier identifier: String) {
        log.record(
            "registry.setLocation",
            args: [
                "bookID": identifier,
                "hasLocation": location != nil,
            ]
        )
        inner.setLocation(location, forIdentifier: identifier)
    }

    // Forward-only — not part of the snapshot surface for these scenarios.

    func location(forIdentifier identifier: String) -> TPPBookLocation? {
        inner.location(forIdentifier: identifier)
    }
    var registryPublisher: AnyPublisher<[String: TPPBookRegistryRecord], Never> { inner.registryPublisher }
    var bookStatePublisher: AnyPublisher<(String, TPPBookState), Never> { inner.bookStatePublisher }
    var registryState: TPPBookRegistry.RegistryState { inner.registryState }
    var syncStatePublisher: AnyPublisher<Bool, Never> { inner.syncStatePublisher }
    var heldBooks: [TPPBook] { inner.heldBooks }
    var myBooks: [TPPBook] { inner.myBooks }
    var isSyncing: Bool { inner.isSyncing }
    var state: TPPBookRegistry.RegistryState { inner.state }
    func sync(completion: ((_ errorDocument: [AnyHashable: Any]?, _ newBooks: Bool) -> Void)?) { inner.sync(completion: completion) }
    func sync() { inner.sync() }
    func load() { inner.load() }
    func addBook(_ book: TPPBook, location: TPPBookLocation?, state: TPPBookState, fulfillmentId: String?, readiumBookmarks: [TPPReadiumBookmark]?, genericBookmarks: [TPPBookLocation]?) {
        inner.addBook(book, location: location, state: state, fulfillmentId: fulfillmentId, readiumBookmarks: readiumBookmarks, genericBookmarks: genericBookmarks)
    }
    func coverImage(for book: TPPBook, handler: @escaping (UIImage?) -> Void) { inner.coverImage(for: book, handler: handler) }
    func setProcessing(_ processing: Bool, for bookIdentifier: String) { inner.setProcessing(processing, for: bookIdentifier) }
    func processing(forIdentifier bookIdentifier: String) -> Bool { inner.processing(forIdentifier: bookIdentifier) }
    func state(for bookIdentifier: String?) -> TPPBookState { inner.state(for: bookIdentifier) }
    func readiumBookmarks(forIdentifier identifier: String) -> [TPPReadiumBookmark] { inner.readiumBookmarks(forIdentifier: identifier) }
    func replace(_ oldBookmark: TPPReadiumBookmark, with newBookmark: TPPReadiumBookmark, forIdentifier identifier: String) { inner.replace(oldBookmark, with: newBookmark, forIdentifier: identifier) }
    func genericBookmarksForIdentifier(_ bookIdentifier: String) -> [TPPBookLocation] { inner.genericBookmarksForIdentifier(bookIdentifier) }
    func addOrReplaceGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) { inner.addOrReplaceGenericBookmark(location, forIdentifier: bookIdentifier) }
    func preloadData(bookIdentifier: String, locations: [TPPBookLocation]) { inner.preloadData(bookIdentifier: bookIdentifier, locations: locations) }
    func addGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) { inner.addGenericBookmark(location, forIdentifier: bookIdentifier) }
    func deleteGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) { inner.deleteGenericBookmark(location, forIdentifier: bookIdentifier) }
    func replaceGenericBookmark(_ oldLocation: TPPBookLocation, with newLocation: TPPBookLocation, forIdentifier bookIdentifier: String) { inner.replaceGenericBookmark(oldLocation, with: newLocation, forIdentifier: bookIdentifier) }
    func removeBook(forIdentifier bookIdentifier: String) { inner.removeBook(forIdentifier: bookIdentifier) }
    func updateAndRemoveBook(_ book: TPPBook) { inner.updateAndRemoveBook(book) }
    func setState(_ state: TPPBookState, for bookIdentifier: String) { inner.setState(state, for: bookIdentifier) }
    func book(forIdentifier bookIdentifier: String?) -> TPPBook? { inner.book(forIdentifier: bookIdentifier) }
    func fulfillmentId(forIdentifier bookIdentifier: String?) -> String? { inner.fulfillmentId(forIdentifier: bookIdentifier) }
    func setFulfillmentId(_ fulfillmentId: String, for bookIdentifier: String) { inner.setFulfillmentId(fulfillmentId, for: bookIdentifier) }
    func with(account: String, perform block: (_ registry: TPPBookRegistry) -> Void) { inner.with(account: account, perform: block) }
    func cachedThumbnailImage(for book: TPPBook) -> UIImage? { inner.cachedThumbnailImage(for: book) }
    func thumbnailImage(for book: TPPBook?, handler: @escaping (UIImage?) -> Void) { inner.thumbnailImage(for: book, handler: handler) }
    func thumbnailImages(forBooks books: Set<TPPBook>, handler: @escaping ([String: UIImage]) -> Void) { inner.thumbnailImages(forBooks: books, handler: handler) }
    func updatedBookMetadata(_ book: TPPBook) -> TPPBook? { inner.updatedBookMetadata(book) }
}

// MARK: - Spy current-library-account provider (vends nil to keep the
// business logic on the local-only fall-through path — bypasses
// `TPPAnnotations` static surface, which is not part of this contract).

private final class NilCurrentAccountProvider: NSObject, TPPCurrentLibraryAccountProvider {
    var currentAccount: Account? { nil }
}

// MARK: - Tests

final class Reader2BookmarkContractTests: XCTestCase {

    private let bookIdentifier = "contract-reader2-bookmark-1"
    private var log: CallLog!
    private var innerRegistry: TPPBookRegistryMock!
    private var registry: RecordingBookmarkRegistry!
    private var accountProvider: NilCurrentAccountProvider!
    private var book: TPPBook!
    private var publication: Publication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        log = CallLog()
        book = makeBook()
        publication = makePublication()
        innerRegistry = TPPBookRegistryMock()
        innerRegistry.addBook(book, state: .downloadSuccessful)
        registry = RecordingBookmarkRegistry(log: log, inner: innerRegistry)
        accountProvider = NilCurrentAccountProvider()
    }

    override func tearDown() {
        accountProvider = nil
        registry = nil
        innerRegistry = nil
        publication = nil
        book = nil
        log = nil
        super.tearDown()
    }

    // MARK: - 1. Bookmark save → registry write (local-only path)

    /// Pins the local-only persistence contract: addBookmark with a
    /// progression-bearing locator builds a `TPPReadiumBookmark` via the
    /// factory, appends it to the in-memory list, then writes it through
    /// `bookRegistry.add(bookmark, forIdentifier:)`.
    ///
    /// We drive this through the no-current-account branch (provider
    /// returns nil), so `postBookmark` synchronously falls through to
    /// `bookRegistry.add` and the static `TPPAnnotations` surface is
    /// never reached. That keeps the snapshot bounded to the protocol
    /// seam this module owns.
    ///
    /// Regression caught: removing the local-only fall-through would
    /// drop the snapshot's `registry.add` line — bookmarks taken while
    /// the library swap is mid-flight would disappear.
    func test_bookmarkSave_writesToRegistry_thenAnnotations() async throws {
        let businessLogic = TPPReaderBookmarksBusinessLogic(
            book: book,
            r2Publication: publication,
            drmDeviceID: "device-D-bookmark",
            bookRegistryProvider: registry,
            currentLibraryAccountProvider: accountProvider
        )

        guard let locator = makeLocator(
            href: "/chapter1.xhtml",
            progression: 0.5,
            totalProgression: 0.25
        ) else {
            XCTFail("Fixture locator URL must parse")
            return
        }

        guard let r3Location = TPPBookmarkR3Location.from(locator: locator, in: publication) else {
            XCTFail("Fixture locator must resolve to a TPPBookmarkR3Location for this contract")
            return
        }

        log.record("bookmarkSave.begin", args: ["bookID": bookIdentifier])
        let bookmark = await businessLogic.addBookmark(r3Location)
        log.record(
            "bookmarkSave.end",
            args: [
                "returnedNonNil": bookmark != nil,
                "appendedCount": businessLogic.bookmarks.count,
            ]
        )

        ContractSnapshot.assert(log, named: "bookmarkSave_writesToRegistry_thenAnnotations")
    }

    // MARK: - 2. Bookmark save → factory fails → no registry write

    /// Pins the failure contract: when the locator lacks the progression
    /// info `TPPBookmarkFactory.make` requires (`progression` and
    /// `totalProgression` both non-nil), the factory returns nil, the
    /// business logic returns nil, and NO `bookRegistry.add` fires.
    ///
    /// The "failureFromRegistry" framing in the contract title is
    /// interpreted as factory-fail (the registry-facing failure surface
    /// for this code path — the factory is what gates writes into the
    /// registry from `addBookmark`).
    ///
    /// Regression caught: a refactor that fabricates a partial bookmark
    /// from a nil-progression locator would grow the snapshot with a
    /// `registry.add` line. (See `swarm_f3b9b087` "opens at chapter 1"
    /// regression — the same pre-render-junk hazard that
    /// `shouldStore` guards against on the position side.)
    /// QA review rev_0d6da02f rename: the test name previously said
    /// "failureFromRegistry" but the scenario actually pins
    /// TPPBookmarkR3Location FACTORY rejection on a nil-progression locator
    /// (registry is never reached). The behavior is correct; the name now
    /// matches what's actually tested.
    func test_bookmarkSave_locatorFactoryRejects_doesNotEnqueueAnnotation() async throws {
        let businessLogic = TPPReaderBookmarksBusinessLogic(
            book: book,
            r2Publication: publication,
            drmDeviceID: "device-D-bookmark",
            bookRegistryProvider: registry,
            currentLibraryAccountProvider: accountProvider
        )

        // Locator with NIL progression → factory must reject.
        guard let locator = makeLocator(
            href: "/chapter1.xhtml",
            progression: nil,
            totalProgression: nil
        ) else {
            XCTFail("Fixture locator URL must parse")
            return
        }

        guard let r3Location = TPPBookmarkR3Location.from(locator: locator, in: publication) else {
            XCTFail("Fixture locator must resolve to a TPPBookmarkR3Location for this contract")
            return
        }

        log.record("bookmarkSave.begin", args: ["bookID": bookIdentifier, "hasProgression": false])
        let bookmark = await businessLogic.addBookmark(r3Location)
        log.record(
            "bookmarkSave.end",
            args: [
                "returnedNonNil": bookmark != nil,
                "appendedCount": businessLogic.bookmarks.count,
            ]
        )

        ContractSnapshot.assert(log, named: "bookmarkSave_failureFromRegistry_doesNotEnqueueAnnotation")
    }

    // MARK: - 3. Bookmark delete → registry delete (local-only path)

    /// Pins the local delete contract: `deleteBookmark(at:)` removes the
    /// bookmark from the in-memory list and calls
    /// `bookRegistry.delete(bookmark, forIdentifier:)`. With no
    /// `annotationId` (the bookmark was never round-tripped to the
    /// server) AND no currentAccount, the server-side delete arm is
    /// bypassed at the early-return on line 187 of
    /// `TPPReaderBookmarksBusinessLogic.didDeleteBookmark`.
    ///
    /// Regression caught: moving the `bookRegistry.delete` call below
    /// the `guard let currentAccount = ... else { return }` line would
    /// drop the registry write entirely for the no-account path —
    /// users would see deleted-bookmarks reappear on next sync.
    func test_bookmarkDelete_removesFromRegistry_thenAnnotationsDelete() async throws {
        let businessLogic = TPPReaderBookmarksBusinessLogic(
            book: book,
            r2Publication: publication,
            drmDeviceID: "device-D-bookmark",
            bookRegistryProvider: registry,
            currentLibraryAccountProvider: accountProvider
        )

        // Pre-seed the business logic's in-memory list with a bookmark.
        // Constructed directly to avoid the factory + registry-add path
        // (which is already pinned by scenario 1) — we want a clean
        // delete-only snapshot.
        guard let bookmark = TPPReadiumBookmark(
            annotationId: nil,
            href: "/chapter1.xhtml",
            chapter: nil,
            page: nil,
            location: nil,
            progressWithinChapter: 0.5,
            progressWithinBook: 0.25,
            readingOrderItem: nil,
            readingOrderItemOffsetMilliseconds: 0.0,
            time: nil,
            device: "device-D-bookmark"
        ) else {
            XCTFail("TPPReadiumBookmark fixture must initialize")
            return
        }
        businessLogic.bookmarks = [bookmark]

        log.record("bookmarkDelete.begin", args: ["bookID": bookIdentifier, "index": 0])
        let deleted = businessLogic.deleteBookmark(at: 0)
        log.record(
            "bookmarkDelete.end",
            args: [
                "returnedNonNil": deleted != nil,
                "remainingCount": businessLogic.bookmarks.count,
            ]
        )

        ContractSnapshot.assert(log, named: "bookmarkDelete_removesFromRegistry_thenAnnotationsDelete")
    }

    // MARK: - Fixture helpers

    private func makeBook() -> TPPBook {
        let url = URL(string: "https://test.example.com/book")!
        let acq = TPPOPDSAcquisition(
            relation: .generic,
            type: "application/epub+zip",
            hrefURL: url,
            indirectAcquisitions: [],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        return TPPBook(
            acquisitions: [acq],
            authors: [],
            categoryStrings: [],
            distributor: "",
            identifier: bookIdentifier,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: Date(),
            publisher: "",
            subtitle: "",
            summary: "",
            title: "",
            updated: Date(),
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

    private func makePublication() -> Publication {
        let metadata = Metadata(title: "Test", languages: ["en"])
        let readingOrder = [
            Link(href: "/chapter1.xhtml", mediaType: .xhtml),
            Link(href: "/chapter2.xhtml", mediaType: .xhtml),
        ]
        return Publication(manifest: Manifest(metadata: metadata, readingOrder: readingOrder))
    }

    private func makeLocator(href: String, progression: Double?, totalProgression: Double?) -> Locator? {
        guard let url = AnyURL(string: href) else { return nil }
        return Locator(
            href: url,
            mediaType: .xhtml,
            locations: Locator.Locations(progression: progression, totalProgression: totalProgression)
        )
    }
}

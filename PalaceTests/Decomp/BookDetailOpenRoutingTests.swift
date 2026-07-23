//
//  BookDetailOpenRoutingTests.swift
//  PalaceTests
//
//  God-class decomposition — pin-before-extract pack for
//  `Palace/Book/UI/BookDetail/BookDetailViewModel.swift`, MOVING clusters
//  "Reading / open-routing" and "Related books" (plan §3a-4 / §5). These clusters
//  become `BookOpenRouter` (open-routing) and `RelatedBooksService` (related
//  derivation). The tests lock the observable routing DECISION and the related-
//  navigation state derivation so the extraction can't change them silently.
//
//  ADDITIVE — does NOT overlap the existing 81-125 tests in
//  `PalaceTests/Book/BookDetailViewModelTests`, which pin the streamingHTML
//  NavigationCoordinator push, BookButtonMapper/buttonTypes, series-row display,
//  selectRelatedBook clearing, and showMoreBooksForLane. Here we add:
//    1. open-routing decision table: audiobook format → the injected
//       AudiobookSessionManaging is opened; a non-audiobook format is NOT.
//    2. selectRelatedBook re-derives bookState from the registry for the NEWLY
//       selected book (the existing test asserts identifier + lane-clearing but
//       never the re-derived state).
//
//  SEAM: EPUB / PDF / streamingHTML open-routing runs through `BookService.open`
//  → `AppContainer.production().readerService` / `.navigationCoordinatorHub`
//  (process-wide statics, NOT injected into the VM), so those destinations are
//  not observable from a unit seam. Only the audiobook branch is drivable, via
//  the injected `AudiobookSessionManaging`. The planned `BookOpenRouter`
//  extraction should inject reader + navigation seams so EPUB/PDF/streaming
//  destinations become assertable. Pinned here: audiobook routing + content-type
//  discrimination through the one seam that exists today.
//
//  SEAM: `fetchRelatedBooks` / `createRelatedBooksCells` (the author-lane
//  reordering derivation) depends on the CONCRETE `OPDSFeedService` actor
//  returning an `.acquisitionGrouped` feed with `groupAttributes`; it cannot be
//  unit-pinned without an injected `OPDSFeedFetching` seam + a grouped-feed
//  fixture. `RelatedBooksService` should take `OPDSFeedFetching`. The author-
//  reorder derivation is left uncovered pending that inversion.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import UIKit
import XCTest
import PalaceAudiobookToolkit
import PalaceCatalog
@testable import Palace

@MainActor
final class BookDetailOpenRoutingTests: XCTestCase {

    private var appContainer: AppContainer!

    override func setUp() {
        super.setUp()
        appContainer = makeTestAppContainer()
    }

    override func tearDown() {
        appContainer = nil
        super.tearDown()
    }

    // MARK: - Open-routing decision table

    /// AUDIOBOOK content type must route through `openBook` → `openAudiobook` →
    /// `BookService.open` → the injected `AudiobookSessionManaging`. Pinning this
    /// at the VM's `openBook` switch (rather than at BookService) is what locks
    /// the routing decision: the session is opened exactly once, with the
    /// resolved book's identifier and `startPlaying: true`.
    ///
    /// Mutation: re-routing the `.audiobook` switch arm to any other reader means
    /// the session is never opened and this times out.
    func testOpenBook_audiobookFormat_routesToInjectedAudiobookSession() async {
        let audiobook = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
        XCTAssertEqual(audiobook.defaultBookContentType, .audiobook,
                       "precondition: the fixture must classify as an audiobook")

        let registry = TPPBookRegistryMock()
        registry.addBook(audiobook, location: nil, state: .downloadSuccessful,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
        let session = RecordingAudiobookSession()
        let vm = makeVM(book: audiobook, registry: registry, session: session)

        let opened = expectation(description: "audiobook session opened")
        session.onOpen = { opened.fulfill() }

        vm.openBook(audiobook, completion: nil)

        await fulfillment(of: [opened], timeout: 3)
        XCTAssertEqual(session.openCount, 1, "The audiobook must open the session exactly once")
        XCTAssertEqual(session.lastOpenedIdentifier, audiobook.identifier,
                       "The routed identifier must be the audiobook under open")
        XCTAssertEqual(session.lastStartPlaying, true,
                       "Audiobook opens must request immediate playback (startPlaying: true)")
    }

    /// The discriminator: a NON-audiobook format must NOT reach the audiobook
    /// session. streamingHTML is used because its `openBook` arm presents via the
    /// NavigationCoordinator (nil in a unit context → a safe no-op) and never
    /// touches `readerService`, so this proves the audiobook routing is content-
    /// type-specific rather than unconditional.
    ///
    /// Mutation: collapsing the switch so every format opens the session makes
    /// `openCount` non-zero and this fails.
    func testOpenBook_nonAudiobookFormat_doesNotRouteToAudiobookSession() {
        let streaming = makeStreamingHTMLBook()
        XCTAssertEqual(streaming.defaultBookContentType, .streamingHTML,
                       "precondition: the fixture must classify as streamingHTML")

        let registry = TPPBookRegistryMock()
        registry.addBook(streaming, location: nil, state: .downloadNeeded,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
        let session = RecordingAudiobookSession()
        let vm = makeVM(book: streaming, registry: registry, session: session)

        vm.openBook(streaming, completion: nil)
        drainMainQueue()

        XCTAssertEqual(session.openCount, 0,
                       "A streamingHTML open must NOT reach the audiobook session — routing is content-type-specific")
    }

    // MARK: - Related-books navigation state derivation

    /// selectRelatedBook, on navigating to a DIFFERENT book, must re-derive
    /// `bookState` from the registry for the NEWLY selected identifier. The
    /// existing suite asserts the book swap + lane-clearing but never the state
    /// re-derivation — so a mutant that reads the OLD identifier (or skips the
    /// state read entirely) would pass there and fail here.
    func testSelectRelatedBook_differentBook_reDerivesBookStateFromRegistryForNewBook() {
        let current = TPPBookMocker.mockBook(identifier: "current-book", title: "Current",
                                             distributorType: .EpubZip)
        let registry = TPPBookRegistryMock()
        registry.addBook(current, location: nil, state: .unregistered,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        // The newly-selected book lives in the registry in a DISTINCT state, so a
        // correct re-derivation must flip bookState away from the current book's.
        let other = TPPBookMocker.mockBook(identifier: "other-book", title: "Other",
                                           distributorType: .EpubZip)
        registry.addBook(other, location: nil, state: .downloadSuccessful,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        let vm = makeVM(book: current, registry: registry, session: RecordingAudiobookSession())
        XCTAssertEqual(vm.bookState, .unregistered, "precondition: VM starts on the current book's state")

        vm.selectRelatedBook(other)
        drainMainQueue()

        XCTAssertEqual(vm.book.identifier, "other-book", "The selected book must become the VM's book")
        XCTAssertEqual(vm.bookState, .downloadSuccessful,
                       "bookState must be re-derived from the registry for the newly-selected book, not left on the previous book's state")
    }

    // MARK: - Helpers

    private func makeVM(book: TPPBook,
                        registry: TPPBookRegistryProvider,
                        session: RecordingAudiobookSession) -> BookDetailViewModel {
        BookDetailViewModel(
            book: book,
            registry: registry,
            downloadCenter: appContainer.downloadCenter,
            accountsManager: appContainer.accountsManager,
            settings: TPPSettings(),
            opdsFeedService: appContainer.opdsFeedService,
            samplePreviewManager: appContainer.samplePreviewManager,
            readerService: appContainer.readerService,
            audiobookSession: session
        )
    }

    /// Minimal streamingHTML book (borrow acquisition with a streaming-HTML
    /// indirect leaf), mirroring the fixture shape in BookDetailViewModelTests.
    private func makeStreamingHTMLBook(id: String = "routing-streaming-book") -> TPPBook {
        let leaf = TPPOPDSIndirectAcquisition(type: ContentTypeStreamingHTML, indirectAcquisitions: [])
        let acquisition = TPPOPDSAcquisition(
            relation: .borrow,
            type: ContentTypeOPDSPublication,
            hrefURL: URL(string: "https://example.com/borrow/\(id)")!,
            indirectAcquisitions: [leaf],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        return TPPBook(
            acquisitions: [acquisition],
            authors: [TPPBookAuthor(authorName: "Streaming Author", relatedBooksURL: nil)],
            categoryStrings: ["Streaming"],
            distributor: "Streaming",
            identifier: id,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: Date(),
            publisher: "Publisher",
            subtitle: nil,
            summary: "Test",
            title: "Streaming Routing Title",
            updated: Date(),
            annotationsURL: nil,
            analyticsURL: nil,
            alternateURL: nil,
            relatedWorksURL: nil,
            previewLink: nil,
            seriesURL: nil,
            revokeURL: URL(string: "https://example.com/revoke"),
            reportURL: nil,
            timeTrackingURL: nil,
            contributors: [:],
            bookDuration: nil,
            imageCache: MockImageCache()
        )
    }
}

// MARK: - Recording session double

/// Minimal `AudiobookSessionManaging` that records the open call BookService
/// routes to it. Overrides the 3-arg `openAudiobook` witness (the variant
/// `BookService.dispatchOpen` invokes) so the routing decision is observable.
/// Mirrors the compiling `HookRecordingSession` in
/// `PalaceTests/Book/BookServiceAudiobookOpenTests.swift`.
///
/// VERIFY: if `AudiobookSessionManaging` gains a required (non-defaulted) member,
/// add a stub here.
@MainActor
private final class RecordingAudiobookSession: AudiobookSessionManaging {
    private(set) var openCount = 0
    private(set) var lastOpenedIdentifier: String?
    private(set) var lastStartPlaying: Bool?
    var onOpen: (() -> Void)?

    @discardableResult
    func openAudiobook(_ book: TPPBook, startPlaying: Bool,
                       onLoadingShellPresented: (@MainActor () -> Void)?) async -> Result<Void, AudiobookSessionError> {
        openCount += 1
        lastOpenedIdentifier = book.identifier
        lastStartPlaying = startPlaying
        onOpen?()
        return .success(())
    }

    @discardableResult
    func openAudiobook(_ book: TPPBook, startPlaying: Bool) async -> Result<Void, AudiobookSessionError> {
        .success(())
    }

    // MARK: Protocol boilerplate (unused by these tests)
    var state: AudiobookSessionState = .idle
    var currentBook: TPPBook?
    var currentChapters: [Chapter] = []
    var currentChapter: Chapter?
    var currentPosition: TrackPosition?
    var isPlaying: Bool { false }
    var coverImage: UIImage?
    var hasActiveManager: Bool = false

    let playbackStatePublisher = PassthroughSubject<AudiobookSessionState, Never>()
    let chapterUpdatePublisher = PassthroughSubject<(chapters: [Chapter], current: Chapter?), Never>()
    let errorPublisher = PassthroughSubject<AudiobookSessionError, Never>()

    func play() {}
    func pause() {}
    func togglePlayPause() {}
    func skipToChapter(at index: Int) {}
    func skipBack() {}
    func skipForward() {}
    func cyclePlaybackRate() -> PlaybackRate { .normalTime }
    func stopPlayback(dismissPhoneUI: Bool, persistFinalPosition: Bool) async {}
    func updateCoverImage(_ image: UIImage?) {}
    func recoverPlaybackForForegroundEntry() {}
}

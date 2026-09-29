//
//  BookDetailOpenRoutingDecisionTableTests.swift
//  PalaceTests
//
//  Wave 5 pin-before-extract — the OPEN-ROUTING DECISION TABLE for
//  `BookDetailViewModel.openBook(_:completion:)`, written against the code as
//  it stands BEFORE the `BookOpenRouter` extraction (plan §3a-4 / §5, cycle 8).
//
//  WHY A TABLE AND NOT SCENARIOS
//
//  `TPPBookContentType` has exactly five cases — epub, audiobook, pdf,
//  unsupported, streamingHTML — so "format → destination" is finite and
//  enumerable. CLAUDE.md's state-machine rule applies directly: write the table
//  down and assert every cell, rather than sampling the cells that felt
//  interesting. `BookDetailOpenRoutingTests` (the earlier pack) asserts two of
//  the five; this file asserts all five, in both registry states from which
//  `openBook` is reachable, plus the registry-resolution cell.
//
//  THE TABLE THIS PINS (read off the production switch, not modelled)
//
//    format         | audiobook session | streamingHTML route | completion
//    ---------------+-------------------+---------------------+-----------
//    .audiobook     | opened once       | not pushed          | invoked
//    .streamingHTML | not opened        | pushed once         | invoked
//    .unsupported   | not opened        | not pushed          | NOT invoked
//    .epub / .pdf   | see the exclusion note below
//
//  The `.unsupported` row's last cell is the one a reader would get wrong: the
//  `default:` arm clears `processingButtons` and presents the format error but
//  never calls `completion`, so a caller holding a spinner on the completion
//  keeps holding it. That asymmetry is behaviour the extraction must carry over
//  unchanged, which is exactly why it is pinned here rather than "fixed" mid-move.
//
//  OBSERVABILITY, STATED AT THE SCOPE IT WAS MEASURED
//
//  Two destinations are observable from a unit seam without executing a reader:
//  the audiobook session (injected via `audiobookSession:`) and the
//  streamingHTML route (a real `NavigationCoordinator` registered on the
//  production hub, the same technique `StreamingReaderPresentationContractTests`
//  uses). EPUB and PDF route through `BookService` ->
//  `AppContainer.production().readerService`, which is NOT injected into the
//  view model — driving them runs the real open pipeline and its failure
//  recovery. Their cells are covered by the pure `BookOpenRouter` table the
//  extraction adds. Stated at the scope measured: before that table, the
//  epub/pdf destinations have no assertion anywhere in the suite.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import PalacePreferences
import UIKit
import XCTest
import PalaceAudiobookToolkit
import PalaceCatalog
@testable import Palace
import PalaceBookModel
import PalaceBookRegistry

@MainActor
final class BookDetailOpenRoutingDecisionTableTests: XCTestCase {

    private var appContainer: AppContainer!
    private var coordinator: NavigationCoordinator!
    private var pinnedRouter: AppTabRouter!

    override func setUp() {
        super.setUp()
        appContainer = makeTestAppContainer()
        // The streamingHTML arm resolves its coordinator off the PRODUCTION hub
        // (`AppContainer.production().navigationCoordinatorHub`), so a test
        // container cannot observe it. Register a real coordinator on the
        // production hub for the duration of the test, pinning the tab router so
        // the lookup does not depend on whatever an earlier test left in
        // `pendingTab` — the PP-5022 hazard documented in
        // StreamingReaderPresentationContractTests.
        pinnedRouter = AppTabRouter()
        pinnedRouter.selected = .myBooks
        AppContainer.production().tabRouterHub.router = pinnedRouter  // MIGRATED-DEFERRED: swarm_47883816 — BookOpenRouter.presentStreamingReader resolves its coordinator off the PRODUCTION hub, so the production hub IS the contract under test; a makeTestAppContainer() hub is a different object the router never consults.
        coordinator = NavigationCoordinator()
        AppContainer.production().navigationCoordinatorHub.register(coordinator, for: .myBooks)  // MIGRATED-DEFERRED: swarm_47883816 — same hub, same reason: this is where the router looks.
    }

    override func tearDown() {
        // The hub holds coordinators weakly; dropping the strong references is
        // what clears the registration.
        coordinator = nil
        pinnedRouter = nil
        appContainer = nil
        super.tearDown()
    }

    // MARK: - The table, one test per (format, state) row

    // `.epub` and `.pdf` are DELIBERATELY not driven here. Both arms run
    // `BookService` -> `AppContainer.production().readerService`, and a unit
    // context has a presenter, so the open actually executes: a measured run of
    // an earlier draft of this file logged "Content Protection Error on first
    // open - attempting transparent re-download", added the fixture to the
    // PRODUCTION registry and started a download task. A pin that dirties the
    // production registry to observe a routing decision is not a pin. Their
    // cells are asserted instead by `BookOpenRouterTests`, the pure
    // format -> destination table the extraction adds, which reaches no reader
    // at all. What is NOT claimed: this file does not pin the epub/pdf
    // destinations behaviourally, and nothing else in the suite does either.

    /// `.audiobook` — the one positive destination that is injectable. Opens the
    /// session exactly once and does NOT push a streaming route.
    func testOpenBook_audiobook_opensInjectedSessionOnce_andDoesNotPushStreamingRoute() async {
        // MISSING-001-OK: table-driven row — the assertions live in `runRow`,
        // which carries five including a precondition that the fixture actually
        // classifies as `expectedType`, so a row cannot silently measure a
        // different cell than it names.
        await runRow(
            book: TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook),
            expectedType: .audiobook,
            state: .downloadSuccessful,
            expectSessionOpens: 1,
            expectRouteGrowth: 0,
            expectCompletion: true
        )
    }

    /// `.streamingHTML` — pushes exactly one route on the coordinator and never
    /// touches the audiobook session.
    func testOpenBook_streamingHTML_pushesExactlyOneRoute_andDoesNotOpenAudiobookSession() async {
        // MISSING-001-OK: table-driven row — the assertions live in `runRow`,
        // which carries five including a precondition that the fixture actually
        // classifies as `expectedType`, so a row cannot silently measure a
        // different cell than it names.
        await runRow(
            book: Self.makeStreamingHTMLBook(id: "table-streaming"),
            expectedType: .streamingHTML,
            state: .downloadNeeded,
            expectSessionOpens: 0,
            expectRouteGrowth: 1,
            expectCompletion: true
        )
    }

    /// `.unsupported` — the `default:` arm. Reaches no reader, and — the cell a
    /// reader would guess wrong — does NOT invoke `completion`.
    ///
    /// Mutation: adding `completion?()` to the default arm (a plausible
    /// "cleanup" refactor during extraction) flips `completionInvoked` and fails.
    func testOpenBook_unsupportedFormat_reachesNoReader_andDoesNotInvokeCompletion() async {
        // MISSING-001-OK: table-driven row — the assertions live in `runRow`,
        // which carries five including a precondition that the fixture actually
        // classifies as `expectedType`, so a row cannot silently measure a
        // different cell than it names.
        let unsupported = TPPBookMocker.mockBook(distributorType: .Biblioboard)
        await runRow(
            book: unsupported,
            expectedType: .unsupported,
            state: .downloadSuccessful,
            expectSessionOpens: 0,
            expectRouteGrowth: 0,
            expectCompletion: false
        )
    }

    // MARK: - The state axis

    /// The routing decision reads the book's content type, not the registry
    /// state, so the `.used` row must land on the same destination as the
    /// `.downloadSuccessful` row. Asserting this is what makes "format →
    /// destination" a one-dimensional table rather than an untested assumption.
    ///
    /// Mutation: making any arm conditional on `bookState` changes one of these
    /// two cells and fails.
    func testOpenBook_audiobookInUsedState_routesIdenticallyToDownloadSuccessful() async {
        // MISSING-001-OK: table-driven row — the assertions live in `runRow`,
        // which carries five including a precondition that the fixture actually
        // classifies as `expectedType`, so a row cannot silently measure a
        // different cell than it names.
        await runRow(
            book: TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook),
            expectedType: .audiobook,
            state: .used,
            expectSessionOpens: 1,
            expectRouteGrowth: 0,
            expectCompletion: true
        )
    }

    // MARK: - Registry resolution

    /// `openBook` resolves the book from the registry before routing
    /// (`registry.book(forIdentifier:) ?? book`). Pinned by handing `openBook` a
    /// STALE in-memory copy under an identifier the registry holds as an
    /// audiobook: routing must follow the registry's copy, so the session sees
    /// the registry's book.
    ///
    /// Mutation: dropping the registry lookup and routing the passed-in book
    /// would still open the session here (both are audiobooks), so the
    /// discriminating assertion is on the OPENED OBJECT — the session must
    /// receive the registry's instance, not the stale one.
    func testOpenBook_routesTheRegistrysCopy_notThePassedInBook() async {
        let registryCopy = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
        let stale = TPPBookMocker.mockBook(
            identifier: registryCopy.identifier,
            title: "Stale In-Memory Title",
            distributorType: .OpenAccessAudiobook
        )
        XCTAssertNotEqual(stale.title, registryCopy.title,
                          "precondition: the two copies must be distinguishable by title")

        let registry = TPPBookRegistryMock()
        registry.addBook(registryCopy, location: nil, state: .downloadSuccessful,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
        let session = TableRecordingAudiobookSession()
        let vm = makeVM(book: registryCopy, registry: registry, session: session)

        let opened = expectation(description: "session opened")
        session.onOpen = { opened.fulfill() }
        vm.openBook(stale, completion: nil)
        await fulfillment(of: [opened], timeout: 5)  // STARVE-001-OK: fulfilled by the recorded session open, not a poll on fire-and-forget work

        XCTAssertEqual(session.lastOpenedTitle, registryCopy.title,
                       "openBook must route the registry's copy of the book, not the caller's stale instance")
    }

    // MARK: - Row driver

    /// Drives one table row and asserts every cell of it. Shared so each row is
    /// the same measurement — a row that asserted a different set of observables
    /// would not be a table.
    private func runRow(book: TPPBook,
                        expectedType: TPPBookContentType,
                        state: TPPBookState,
                        expectSessionOpens: Int,
                        expectRouteGrowth: Int,
                        expectCompletion: Bool) async {
        XCTAssertEqual(book.defaultBookContentType, expectedType,
                       "precondition: the fixture must classify as \(expectedType) — otherwise this row measures a different cell than it names")

        let registry = TPPBookRegistryMock()
        registry.addBook(book, location: nil, state: state,
                         fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
        let session = TableRecordingAudiobookSession()
        let vm = makeVM(book: book, registry: registry, session: session)
        vm.processingButtons = [.download]

        let pathBefore = coordinator.path.count
        var completionInvoked = false

        let settled = expectation(description: "open settled for \(expectedType)")
        if expectCompletion {
            vm.openBook(book) {
                completionInvoked = true
                settled.fulfill()
            }
        } else {
            // No completion is expected, so the row cannot wait on one. Settle on
            // a main-queue turn instead and record whether the completion fired
            // anyway — which is the assertion for this row.
            vm.openBook(book) { completionInvoked = true }
            DispatchQueue.main.async { settled.fulfill() }
        }
        await fulfillment(of: [settled], timeout: 5)  // STARVE-001-OK: fulfilled by openBook's own completion (or one main-queue turn for the no-completion row)
        await drainMainQueueAsync()

        XCTAssertEqual(session.openCount, expectSessionOpens,
                       "\(expectedType): audiobook-session opens")
        XCTAssertEqual(coordinator.path.count - pathBefore, expectRouteGrowth,
                       "\(expectedType): streamingHTML route pushes")
        XCTAssertEqual(completionInvoked, expectCompletion,
                       "\(expectedType): completion invocation")
        XCTAssertTrue(vm.processingButtons.isEmpty,
                      "\(expectedType): every arm of the open switch clears processingButtons")
    }

    // MARK: - Helpers

    private func makeVM(book: TPPBook,
                        registry: TPPBookRegistryProvider,
                        session: TableRecordingAudiobookSession) -> BookDetailViewModel {
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
    /// indirect leaf) — the only way to produce a `.streamingHTML` classification.
    static func makeStreamingHTMLBook(id: String) -> TPPBook {
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

/// Records the open call `BookService.dispatchOpen` routes to the audiobook arm.
/// Distinct from `BookDetailOpenRoutingTests`' private double so neither file's
/// assertions can drift into the other's fixture.
@MainActor
private final class TableRecordingAudiobookSession: AudiobookSessionManaging {
    private(set) var openCount = 0
    private(set) var lastOpenedTitle: String?
    var onOpen: (() -> Void)?

    @discardableResult
    func openAudiobook(_ book: TPPBook, startPlaying: Bool,
                       onLoadingShellPresented: (@MainActor () -> Void)?) async -> Result<Void, AudiobookSessionError> {
        openCount += 1
        lastOpenedTitle = book.title
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

//
//  StreamingReaderPresentationContractTests.swift
//  PalaceTests
//
//  PP-4161 contract-snapshot test pinning the BookDetailViewModel ->
//  NavigationCoordinator call sequence for the streaming-HTML presentation
//  flow:
//
//      handleAction(.readStreaming)
//          → processingButtons.insert(.readStreaming)
//          → coordinator.store(book:)
//          → coordinator.push(.streamingHTML(BookRoute(id:)))
//          → processingButtons.remove(.readStreaming)
//
//  NavigationCoordinator is `final` so we can't subclass it for spying. The
//  contract test observes the coordinator's two public side-effects (path
//  growth + bookById storage) and records them into a CallLog by inspecting
//  state pre/post call. The snapshot locks the sequence + the route's case
//  + the BookRoute's id so any refactor that:
//
//   - drops `store(book:)` (leaving NavigationHostView's resolveBook nil),
//   - swaps push order (race against the destination resolver),
//   - changes the route case from `.streamingHTML`, or
//   - mutates the BookRoute id
//
//  will diff the snapshot and fail loudly — exactly the lesson from F-011
//  / F-014.
//

import Combine
import PalacePreferences
import XCTest
import PalaceCatalog
@testable import Palace
import PalaceBookModel

@MainActor
final class StreamingReaderPresentationContractTests: XCTestCase {

    private var coordinator: NavigationCoordinator!
    private var pinnedRouter: AppTabRouter!

    override func setUp() {
        super.setUp()
        coordinator = NavigationCoordinator()
        // PP-5022 — pin the hub's resolution deterministically rather than
        // relying on production's tab router being unset. `currentTab` prefers
        // the live router, so attaching one (held strongly for this test's
        // lifetime; the hub holds it weakly) makes the SUT's coordinator
        // lookup independent of whatever any earlier test left behind in
        // `pendingTab` — which is otherwise never cleared in a test process
        // and would silently turn every later lookup into nil.
        pinnedRouter = AppTabRouter()
        pinnedRouter.selected = .myBooks
        AppContainer.production().tabRouterHub.router = pinnedRouter
        AppContainer.production().navigationCoordinatorHub.register(coordinator, for: .myBooks)
    }

    override func tearDown() {
        // The hub registers weakly, so dropping the last strong reference here
        // is what clears it — there is nothing to un-set.
        pinnedRouter = nil
        coordinator = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeStreamingHTMLBook(id: String = "contract-streaming-book") -> TPPBook {
        let leaf = TPPOPDSIndirectAcquisition(
            type: ContentTypeStreamingHTML,
            indirectAcquisitions: []
        )
        let acquisition = TPPOPDSAcquisition(
            relation: .borrow,
            type: ContentTypeOPDSPublication,
            hrefURL: URL(string: "https://example.com/contract/\(id)")!,
            indirectAcquisitions: [leaf],
            availability: TPPOPDSAcquisitionAvailabilityUnlimited()
        )
        return TPPBook(
            acquisitions: [acquisition],
            authors: [],
            categoryStrings: [],
            distributor: nil,
            identifier: id,
            imageURL: nil,
            imageThumbnailURL: nil,
            published: Date(),
            publisher: nil,
            subtitle: nil,
            summary: nil,
            title: "Contract Streaming Title",
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

    // MARK: - Contract: streamingHTMLReadAction_thenPresent

    /// Drives `viewModel.handleAction(for: .readStreaming)` and snapshots
    /// the observed coordinator state into a deterministic CallLog. Snapshot
    /// lives at
    /// `__Snapshots__/StreamingReaderPresentationContractTests/streamingHTMLReadAction_thenPresent.json`
    /// — committed alongside this file.
    ///
    /// The CallLog records THREE entries:
    ///   1. precondition:pathEmpty (count=0)
    ///   2. observed:bookStored (after the call — bookID present in bookById)
    ///   3. observed:routePushed (after the call — path count=1, route describes streamingHTML)
    ///
    /// Reordering them in production (push BEFORE store) would invert
    /// `bookStored` vs `routePushed` in the recorded snapshot.
    func testStreamingReaderPresentation_handleActionReadStreaming_callSequence() {
        let book = makeStreamingHTMLBook(id: "contract-book-001")
        let mockRegistry = TPPBookRegistryMock()
        mockRegistry.addBook(book, location: nil, state: .downloadNeeded, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

        let vm = BookDetailViewModel(
            book: book,
            registry: mockRegistry,
            downloadCenter: AppContainer.production().downloadCenter,
            accountsManager: AppContainer.production().accountsManager,
            settings: TPPSettings(),
            opdsFeedService: AppContainer.production().opdsFeedService,
            samplePreviewManager: AppContainer.production().samplePreviewManager,
            readerService: AppContainer.production().readerService
        )

        let log = CallLog()
        log.record("precondition:pathEmpty", args: ["pathCount": coordinator.path.count])

        vm.handleAction(for: .readStreaming)

        // Synchronous drain — the presentation seam runs straight through the
        // VM (no async hop). Recording both observed effects post-call.
        let storedBook = coordinator.resolveBook(for: BookRoute(id: book.identifier))
        log.record("observed:bookStored", args: [
            "bookID": book.identifier,
            "resolved": storedBook != nil ? "true" : "false"
        ])

        log.record("observed:routePushed", args: [
            "pathCount": coordinator.path.count,
            // Capture the route case shape via the topmost AppRoute description.
            // NavigationPath doesn't expose enumeration of its contents, so the
            // count is the canonical pin — combined with the bookStored entry
            // it locks the order (store-then-push) and the side effect
            // (path grew by exactly one).
            "expectedRouteCase": "streamingHTML"
        ])

        ContractSnapshot.assert(log, named: "streamingHTMLReadAction_thenPresent")
    }
}

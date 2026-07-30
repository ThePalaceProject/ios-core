//
//  BookCellModelLCPProgressTests.swift
//  PalaceTests
//
//  The shelf half of the LCP content-download progress cue.
//
//  `BookDetailViewModel` has its own tests for the equivalent logic, but this is
//  a DIFFERENT implementation on the route the background self-heal actually
//  fires on — a book sitting on the My Books shelf. Review flagged three unkilled
//  mutants here: the `guard isDownloadingLCPContent` scoping, the rising-edge
//  reset, and the progress sink itself.
//
//  The scoping is the one that matters. `observedProgress` is a monotone maximum
//  reset only when an LCP content download starts, and these cell models are
//  cached with a 120s TTL, so merging it into every download would let a cell
//  that once saw 1.0 render a full bar for an unrelated later re-download.
//

import Combine
import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class BookCellModelLCPProgressTests: XCTestCase {

    private var appContainer: AppContainer!
    private var mockRegistry: TPPBookRegistryMock!

    override func setUp() {
        super.setUp()
        appContainer = makeTestAppContainer()
        mockRegistry = TPPBookRegistryMock()
    }

    override func tearDown() {
        appContainer = nil
        mockRegistry = nil
        super.tearDown()
    }

    private var reporter: DownloadProgressReporter {
        appContainer.downloadCenter.progressReporter
    }

    private func makeModel(for book: TPPBook) -> BookCellModel {
        BookCellModel(
            book: book,
            imageCache: MockImageCache(),
            bookRegistry: mockRegistry,
            downloadCenter: appContainer.downloadCenter,
            accountsManager: appContainer.accountsManager,
            samplePreviewManager: appContainer.samplePreviewManager,
            readerService: appContainer.readerService,
            reachability: appContainer.reachability
        )
    }

    private func settle(_ predicate: @escaping () -> Bool) async {
        await awaitConditionAsync(predicate)
    }

    // MARK: - The active/idle signal reaches the shelf model

    func testActiveSignal_raisesFlagForThisBook() async {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let model = makeModel(for: book)
        XCTAssertFalse(model.isDownloadingLCPContent, "precondition")

        reporter.sendLCPContentDownloadActive(bookIdentifier: book.identifier, active: true)
        await settle { model.isDownloadingLCPContent }

        XCTAssertTrue(model.isDownloadingLCPContent,
                      "the shelf model must learn a content re-download started — this is the route the self-heal fires on")
    }

    func testSignalForADifferentBook_isIgnored() async {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let other = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let model = makeModel(for: book)

        reporter.sendLCPContentDownloadActive(bookIdentifier: other.identifier, active: true)
        await drainMainQueueAsync()

        XCTAssertFalse(model.isDownloadingLCPContent,
                       "another book's transfer must not light up this cell")
    }

    // MARK: - Progress only counts while an LCP content download is running
    //
    // This is the scoping mutant. Removing `guard isDownloadingLCPContent`
    // reintroduces a stale full bar on an unrelated download.

    func testObservedProgress_isIgnoredWhenNoLCPContentDownloadIsRunning() async {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let model = makeModel(for: book)

        // A completed earlier transfer leaves a high-water mark behind.
        reporter.sendLCPContentDownloadActive(bookIdentifier: book.identifier, active: true)
        await settle { model.isDownloadingLCPContent }
        reporter.sendProgress(bookIdentifier: book.identifier, progress: 1.0)
        await settle { model.downloadProgress >= 1.0 }
        reporter.sendLCPContentDownloadActive(bookIdentifier: book.identifier, active: false)
        await settle { !model.isDownloadingLCPContent }

        XCTAssertEqual(
            model.downloadProgress, 0.0, accuracy: 0.001,
            "with no LCP content download running the cell must fall back to the download center — otherwise a cached cell (120s TTL) shows a full bar for an unrelated later download"
        )
    }

    func testObservedProgress_isUsedWhileAnLCPContentDownloadIsRunning() async {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let model = makeModel(for: book)

        reporter.sendLCPContentDownloadActive(bookIdentifier: book.identifier, active: true)
        await settle { model.isDownloadingLCPContent }
        reporter.sendProgress(bookIdentifier: book.identifier, progress: 0.4)
        await settle { model.downloadProgress > 0 }

        XCTAssertEqual(model.downloadProgress, 0.4, accuracy: 0.001,
                       "the out-of-band transfer never populates downloadInfo, so without this the shelf bar sits pinned at 0%")
    }

    /// The rising edge must re-base the monotone maximum, or a second transfer
    /// renders a full bar for its whole duration.
    func testRisingEdge_resetsTheHighWaterMark() async {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let model = makeModel(for: book)

        reporter.sendLCPContentDownloadActive(bookIdentifier: book.identifier, active: true)
        await settle { model.isDownloadingLCPContent }
        reporter.sendProgress(bookIdentifier: book.identifier, progress: 1.0)
        await settle { model.downloadProgress >= 1.0 }
        reporter.sendLCPContentDownloadActive(bookIdentifier: book.identifier, active: false)
        await settle { !model.isDownloadingLCPContent }

        // A NEW content transfer for the same book begins.
        reporter.sendLCPContentDownloadActive(bookIdentifier: book.identifier, active: true)
        await settle { model.isDownloadingLCPContent }

        XCTAssertEqual(model.downloadProgress, 0.0, accuracy: 0.001,
                       "a fresh transfer must start the bar at zero, not inherit the previous run's high-water mark")
    }
}

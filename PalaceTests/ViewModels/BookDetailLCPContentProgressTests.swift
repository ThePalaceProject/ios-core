//
//  BookDetailLCPContentProgressTests.swift
//  PalaceTests
//
//  Covers the detail view-model's subscription to the LCP `.lcpa` content
//  re-download signal. That download runs against a book which is already
//  `.downloadSuccessful` (only its content package went missing), so the
//  ordinary download-state progress cue cannot see it. Without this wiring the
//  half-sheet showed nothing for the entire multi-gigabyte transfer.
//

import XCTest
import PalaceCatalog
@testable import Palace

@MainActor
final class BookDetailLCPContentProgressTests: XCTestCase {

    private var appContainer: AppContainer!

    override func setUp() {
        super.setUp()
        appContainer = makeTestAppContainer()
    }

    override func tearDown() {
        appContainer = nil
        super.tearDown()
    }

    private func makeViewModel(for book: TPPBook) -> BookDetailViewModel {
        BookDetailViewModel(
            book: book,
            registry: TPPBookRegistryMock(),
            downloadCenter: appContainer.downloadCenter,
            accountsManager: appContainer.accountsManager,
            settings: TPPSettings(),
            opdsFeedService: appContainer.opdsFeedService,
            samplePreviewManager: appContainer.samplePreviewManager,
            readerService: appContainer.readerService,
            metadataHydrator: { _ in nil }
        )
    }

    /// Lets the Combine hop (`receive(on: RunLoop.main)`) land before asserting.
    private func settle() async {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 120_000_000)
        await Task.yield()
    }

    private var reporter: DownloadProgressReporter {
        appContainer.downloadCenter.progressReporter
    }

    func testActiveSignal_raisesFlagForThisBook() async {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let vm = makeViewModel(for: book)
        XCTAssertFalse(vm.isDownloadingLCPContent, "precondition")

        reporter.sendLCPContentDownloadActive(bookIdentifier: book.identifier, active: true)
        await settle()

        XCTAssertTrue(vm.isDownloadingLCPContent,
                      "the view-model must learn that a content re-download started, or the sheet stays blank")
    }

    func testIdleSignal_lowersFlag() async {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let vm = makeViewModel(for: book)

        reporter.sendLCPContentDownloadActive(bookIdentifier: book.identifier, active: true)
        await settle()
        reporter.sendLCPContentDownloadActive(bookIdentifier: book.identifier, active: false)
        await settle()

        XCTAssertFalse(vm.isDownloadingLCPContent,
                       "the cue must close when the transfer ends, on failure as well as success")
    }

    func testSignalForADifferentBook_isIgnored() async {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let other = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let vm = makeViewModel(for: book)

        reporter.sendLCPContentDownloadActive(bookIdentifier: other.identifier, active: true)
        await settle()

        XCTAssertFalse(vm.isDownloadingLCPContent,
                       "a re-download of some other book must not light up this sheet")
    }

    /// The monotonic clamp on `downloadProgress` exists so an ordinary download
    /// bar never slides backwards. It also means a book whose earlier download
    /// reached 1.0 would clamp every fresh sample of a NEW transfer back to 1.0
    /// and render a full bar for the whole wait. The rising edge re-bases it.
    func testRisingEdge_resetsStaleProgressSoTheBarStartsAtZero() async {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let vm = makeViewModel(for: book)

        // Simulate a completed earlier download.
        reporter.sendProgress(bookIdentifier: book.identifier, progress: 1.0)
        await settle()
        XCTAssertEqual(vm.downloadProgress, 1.0, accuracy: 0.001, "precondition")

        reporter.sendLCPContentDownloadActive(bookIdentifier: book.identifier, active: true)
        await settle()

        XCTAssertEqual(vm.downloadProgress, 0.0, accuracy: 0.001,
                       "a new content transfer must re-base the clamp, else the bar sits at 100% for the entire download")
    }

    func testProgressAfterRisingEdge_advancesTheBar() async {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let vm = makeViewModel(for: book)

        reporter.sendProgress(bookIdentifier: book.identifier, progress: 1.0)
        await settle()
        reporter.sendLCPContentDownloadActive(bookIdentifier: book.identifier, active: true)
        await settle()
        reporter.sendProgress(bookIdentifier: book.identifier, progress: 0.35)
        await settle()

        XCTAssertEqual(vm.downloadProgress, 0.35, accuracy: 0.001,
                       "real transfer progress must reach the bar after the reset")
    }

    /// End-to-end through the decision the view actually renders.
    func testCueIsVisibleForTheWholeContentDownload() async {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let vm = makeViewModel(for: book)

        reporter.sendLCPContentDownloadActive(bookIdentifier: book.identifier, active: true)
        await settle()

        let cue = HalfSheetProgressCue.resolve(
            isBorrowProcessing: vm.isBorrowProcessing,
            downloadProgress: vm.downloadProgress,
            bookState: .downloadSuccessful,
            buttonState: .downloadSuccessful,
            isDownloadingLCPContent: vm.isDownloadingLCPContent
        )

        XCTAssertEqual(cue, .downloading,
                       "the sheet must show a bar while the archive transfers — the silence is what patrons read as failure")
    }
}

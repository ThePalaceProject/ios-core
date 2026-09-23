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
import PalaceBookModel
import PalacePreferences
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

    /// Waits for a specific expected outcome rather than sleeping a fixed
    /// interval. Fixed sleeps are both slower than needed and flake-prone under
    /// `-test-iterations 3` with parallel clones, which is the documented
    /// starvation pattern in this suite.
    private func waitUntil(
        _ predicate: @escaping () -> Bool,
        file: StaticString = #file,
        line: UInt = #line
    ) async {
        await awaitConditionAsync(file: file, line: line, predicate)
    }

    /// For assertions that nothing happens, there is no condition to poll for.
    /// Drain the main queue deterministically instead: the Combine delivery this
    /// guards against would have been enqueued by the time the drain returns.
    private func settle() async {
        await drainMainQueueAsync()
        await Task.yield()
        await drainMainQueueAsync()
    }

    private var reporter: DownloadProgressReporter {
        appContainer.downloadCenter.progressReporter
    }

    /// Same ordering case as the shelf model: the half-sheet's view model is built
    /// when the patron opens the book, which for a multi-minute archive is
    /// routinely AFTER the transfer started. The publisher has no replay, so
    /// without seeding the sheet shows no progress for the whole download.
    func testViewModelBuiltWhileATransferIsRunning_showsTheCueImmediately() {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        appContainer.downloadCenter.progressReporter
            .sendLCPContentDownloadActive(bookIdentifier: book.identifier, active: true)
        defer {
            appContainer.downloadCenter.progressReporter
                .clearLCPContentTransfer(for: book.identifier)
        }

        let viewModel = makeViewModel(for: book)

        XCTAssertTrue(viewModel.isDownloadingLCPContent,
                      "opening a book mid-transfer must show its progress, not an idle sheet with a dead Download button")
    }

    func testActiveSignal_raisesFlagForThisBook() async {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let vm = makeViewModel(for: book)
        XCTAssertFalse(vm.isDownloadingLCPContent, "precondition")

        reporter.sendLCPContentDownloadActive(bookIdentifier: book.identifier, active: true)
        await waitUntil { vm.isDownloadingLCPContent }

        XCTAssertTrue(vm.isDownloadingLCPContent,
                      "the view-model must learn that a content re-download started, or the sheet stays blank")
    }

    func testIdleSignal_lowersFlag() async {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let vm = makeViewModel(for: book)

        reporter.sendLCPContentDownloadActive(bookIdentifier: book.identifier, active: true)
        await waitUntil { vm.isDownloadingLCPContent }
        reporter.sendLCPContentDownloadActive(bookIdentifier: book.identifier, active: false)
        await waitUntil { !vm.isDownloadingLCPContent }

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
        await waitUntil { vm.downloadProgress == 1.0 }
        XCTAssertEqual(vm.downloadProgress, 1.0, accuracy: 0.001, "precondition")

        reporter.sendLCPContentDownloadActive(bookIdentifier: book.identifier, active: true)
        await waitUntil { vm.downloadProgress == 0.0 }

        XCTAssertEqual(vm.downloadProgress, 0.0, accuracy: 0.001,
                       "a new content transfer must re-base the clamp, else the bar sits at 100% for the entire download")
    }

    func testProgressAfterRisingEdge_advancesTheBar() async {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let vm = makeViewModel(for: book)

        reporter.sendProgress(bookIdentifier: book.identifier, progress: 1.0)
        await waitUntil { vm.downloadProgress == 1.0 }
        reporter.sendLCPContentDownloadActive(bookIdentifier: book.identifier, active: true)
        await waitUntil { vm.downloadProgress == 0.0 }
        reporter.sendProgress(bookIdentifier: book.identifier, progress: 0.35)
        await waitUntil { vm.downloadProgress == 0.35 }

        XCTAssertEqual(vm.downloadProgress, 0.35, accuracy: 0.001,
                       "real transfer progress must reach the bar after the reset")
    }

    // MARK: - contentRequiredBeforePlayback wiring
    //
    // Added because review found the SAME hole for a FOURTH time in this change:
    // a pure rule covered while the code computing its input was not. Every
    // `resolve` call in the suite passed this argument as a literal, so dropping
    // the `!` in `BookDetailViewModel` inverted the streaming-OFF fix and the
    // whole suite stayed green. The seam's own doc comment claimed it existed
    // "so a test can drive both flag states"; none did.

    func testContentRequiredBeforePlayback_isTrueWhenStreamingIsOff() {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let vm = makeViewModel(for: book)
        vm.downloadCenter.lcpStreamingEnabledProvider = { false }

        XCTAssertTrue(vm.contentRequiredBeforePlayback,
                      "streaming OFF means the archive must land before the book opens — the patron IS waiting")
    }

    func testContentRequiredBeforePlayback_isFalseWhenStreamingIsOn() {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let vm = makeViewModel(for: book)
        vm.downloadCenter.lcpStreamingEnabledProvider = { true }

        XCTAssertFalse(vm.contentRequiredBeforePlayback,
                       "streaming ON means the book plays from its license and the archive is a prefetch")
    }

    /// End to end through the real property rather than a literal: streaming OFF
    /// plus a live content transfer must still show the bar for a playable book.
    func testCue_streamingOff_showsTheBarForAPlayableBook_drivenByTheViewModel() async {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let vm = makeViewModel(for: book)
        vm.downloadCenter.lcpStreamingEnabledProvider = { false }

        reporter.sendLCPContentDownloadActive(bookIdentifier: book.identifier, active: true)
        await waitUntil { vm.isDownloadingLCPContent }

        let cue = HalfSheetProgressCue.resolve(
            isBorrowProcessing: vm.isBorrowProcessing,
            downloadProgress: vm.downloadProgress,
            bookState: .downloadSuccessful,
            buttonState: .downloadSuccessful,
            isDownloadingLCPContent: vm.isDownloadingLCPContent,
            contentRequiredBeforePlayback: vm.contentRequiredBeforePlayback
        )

        XCTAssertEqual(cue, .downloading,
                       "streaming OFF: the patron cannot play until this lands, so the bar is the only signal")
    }

    /// End-to-end through the decision the view actually renders, for the case
    /// where the patron is genuinely waiting: the archive is still required
    /// before playback, so the book has not resolved to an open affordance.
    func testCueIsVisibleForTheWholeContentDownload_whileTheBookIsNotYetPlayable() async {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let vm = makeViewModel(for: book)

        reporter.sendLCPContentDownloadActive(bookIdentifier: book.identifier, active: true)
        await waitUntil { vm.isDownloadingLCPContent }

        let cue = HalfSheetProgressCue.resolve(
            isBorrowProcessing: vm.isBorrowProcessing,
            downloadProgress: vm.downloadProgress,
            bookState: .downloadNeeded,
            buttonState: .downloadNeeded,
            isDownloadingLCPContent: vm.isDownloadingLCPContent,
            contentRequiredBeforePlayback: false
        )

        XCTAssertEqual(cue, .downloading,
                       "the sheet must show a bar while the archive transfers — the silence is what patrons read as failure")
    }

    /// The same live flag, once the book is playable. With PP-4957 streaming on,
    /// `.downloadSuccessful` renders Listen and the archive is a background
    /// prefetch for offline use, so the sheet must NOT draw a bar beside a
    /// button that already works. Drives the real published flag rather than a
    /// literal so the view-model wiring and the cue are pinned together.
    func testCueIsIdleOnceTheBookIsPlayable_evenWhileTheArchiveStillTransfers() async {
        let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
        let vm = makeViewModel(for: book)

        reporter.sendLCPContentDownloadActive(bookIdentifier: book.identifier, active: true)
        await waitUntil { vm.isDownloadingLCPContent }

        let cue = HalfSheetProgressCue.resolve(
            isBorrowProcessing: vm.isBorrowProcessing,
            downloadProgress: vm.downloadProgress,
            bookState: .downloadSuccessful,
            buttonState: .downloadSuccessful,
            isDownloadingLCPContent: vm.isDownloadingLCPContent,
            contentRequiredBeforePlayback: false
        )

        XCTAssertEqual(cue, .idle,
                       "the patron can already listen — a determinate bar here tells them to wait for nothing")
    }
}

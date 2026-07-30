//
//  HalfSheetProgressCueTests.swift
//  PalaceTests
//
//  The half-sheet's progress cue decides whether a patron sees anything at all
//  while a book transfers. With LCP streaming broken upstream
//  (readium/swift-toolkit#579) an LCP audiobook's entire `.lcpa` archive — well
//  over a gigabyte for some Audible-labelled Marketplace titles — must land
//  before playback starts. Choosing `.idle` during that window is what made the
//  sheet look inert and led patrons to back out mid-download.
//
//  The decision is extracted from the SwiftUI body precisely so it can be
//  pinned here.
//

import XCTest
@testable import Palace

final class HalfSheetProgressCueTests: XCTestCase {

    // MARK: - Borrowing

    func testBorrowInFlightBeforeAnyBytes_showsBorrowingSpinner() {
        let cue = HalfSheetProgressCue.resolve(
            isBorrowProcessing: true,
            downloadProgress: 0,
            bookState: .downloading,
            buttonState: .downloadInProgress,
            isDownloadingLCPContent: false
        )
        XCTAssertEqual(cue, .borrowing,
                       "a borrow with no bytes yet must show the indeterminate spinner, not an inert 0% bar")
    }

    func testBorrowFlagSetButBytesFlowing_showsDeterminateBar() {
        // Once real progress arrives the determinate bar is more informative
        // than the spinner, even if the borrow flag has not cleared yet.
        let cue = HalfSheetProgressCue.resolve(
            isBorrowProcessing: true,
            downloadProgress: 0.1,
            bookState: .downloading,
            buttonState: .downloadInProgress,
            isDownloadingLCPContent: false
        )
        XCTAssertEqual(cue, .downloading)
    }

    // MARK: - Ordinary download

    func testDownloadingState_showsDeterminateBar() {
        let cue = HalfSheetProgressCue.resolve(
            isBorrowProcessing: false,
            downloadProgress: 0.42,
            bookState: .downloading,
            buttonState: .downloadInProgress,
            isDownloadingLCPContent: false
        )
        XCTAssertEqual(cue, .downloading)
    }

    /// The `buttonState != .downloadSuccessful` clause: a book whose button has
    /// already resolved to "successful" is finished even if the registry state
    /// lags, and must not keep drawing a bar.
    func testDownloadingStateButButtonAlreadySuccessful_isIdle() {
        let cue = HalfSheetProgressCue.resolve(
            isBorrowProcessing: false,
            downloadProgress: 1.0,
            bookState: .downloading,
            buttonState: .downloadSuccessful,
            isDownloadingLCPContent: false
        )
        XCTAssertEqual(cue, .idle)
    }

    // MARK: - LCP content re-download
    //
    // The case the `bookState` clause cannot reach: the book is legitimately
    // `.downloadSuccessful` from an earlier session and only its `.lcpa` went
    // missing, so a background content re-download is running against a book
    // that is not, by registry state, downloading.

    func testLCPContentDownloadWhileBookIsSuccessful_showsDeterminateBar() {
        let cue = HalfSheetProgressCue.resolve(
            isBorrowProcessing: false,
            downloadProgress: 0.3,
            bookState: .downloadSuccessful,
            buttonState: .downloadSuccessful,
            isDownloadingLCPContent: true
        )
        XCTAssertEqual(cue, .downloading,
                       "an LCP content re-download must be visible — this is the silent-wait patrons backed out of")
    }

    func testLCPContentDownloadAtZeroProgress_stillShowsBar() {
        // The bar must appear on the leading edge, before the first progress
        // sample lands, or there is a visible gap of nothing.
        let cue = HalfSheetProgressCue.resolve(
            isBorrowProcessing: false,
            downloadProgress: 0,
            bookState: .downloadSuccessful,
            buttonState: .downloadSuccessful,
            isDownloadingLCPContent: true
        )
        XCTAssertEqual(cue, .downloading)
    }

    func testLCPContentDownloadFinished_returnsToIdle() {
        let cue = HalfSheetProgressCue.resolve(
            isBorrowProcessing: false,
            downloadProgress: 1.0,
            bookState: .downloadSuccessful,
            buttonState: .downloadSuccessful,
            isDownloadingLCPContent: false
        )
        XCTAssertEqual(cue, .idle,
                       "the cue must close when the transfer ends or the bar would hang at 100% forever")
    }

    /// Borrowing wins over the LCP flag: a borrow with no bytes is the earlier,
    /// more specific phase and has its own label.
    /// REVERSED on device evidence. This previously asserted `.borrowing`, on the
    /// assumption that a processing borrow is the more urgent thing to tell the
    /// patron. A trace of a real Audible LCP borrow disproved it: the borrow stays
    /// "processing" for the entire archive fetch, so that ordering pinned the
    /// half-sheet on a motionless spinner for minutes and then jumped to "Listen".
    ///
    /// A known content transfer is the strictly more specific signal, and it is the
    /// one with a percentage attached, so it wins. `.borrowing` still applies
    /// whenever no content transfer is running — see the companion test.
    func testContentTransfer_outranksBorrowing_evenForAnAlreadySuccessfulBook() {
        let cue = HalfSheetProgressCue.resolve(
            isBorrowProcessing: true,
            downloadProgress: 0,
            bookState: .downloadSuccessful,
            buttonState: .downloadSuccessful,
            isDownloadingLCPContent: true
        )
        XCTAssertEqual(
            cue, .downloading,
            "a book being re-fetched by the self-heal should show that transfer, not a spinner that never moves"
        )
    }

    // MARK: - Idle

    func testNothingInFlight_isIdle() {
        let cue = HalfSheetProgressCue.resolve(
            isBorrowProcessing: false,
            downloadProgress: 0,
            bookState: .downloadSuccessful,
            buttonState: .downloadSuccessful,
            isDownloadingLCPContent: false
        )
        XCTAssertEqual(cue, .idle)
    }

    // MARK: - Precedence over the borrow spinner
    //
    // Reproduces the patron-visible complaint from the 3.2.3 trace: borrowing an
    // Audible LCP title left the half-sheet on a motionless spinner for the whole
    // multi-minute archive fetch, then jumped straight to "Listen".

    func testContentDownload_outranksTheBorrowSpinner() {
        let cue = HalfSheetProgressCue.resolve(
            isBorrowProcessing: true,
            downloadProgress: 0,
            bookState: .downloadNeeded,
            buttonState: .downloadNeeded,
            isDownloadingLCPContent: true
        )

        XCTAssertEqual(
            cue, .downloading,
            "borrow stays 'processing' across the whole .lcpa fetch and that fetch reports 0 until its first byte — checking the spinner first pins the sheet on 'borrowing' for the entire download"
        )
    }

    func testBorrowSpinner_stillShowsWhenNoContentDownloadIsRunning() {
        let cue = HalfSheetProgressCue.resolve(
            isBorrowProcessing: true,
            downloadProgress: 0,
            bookState: .downloadNeeded,
            buttonState: .downloadNeeded,
            isDownloadingLCPContent: false
        )

        XCTAssertEqual(cue, .borrowing,
                       "an ordinary borrow with no content transfer must still show the borrow cue")
    }
}

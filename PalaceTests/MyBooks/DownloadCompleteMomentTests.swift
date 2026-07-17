//
//  DownloadCompleteMomentTests.swift
//  PalaceTests
//
//  PR3 (PP-4746) — download-complete "moment" transition detector.
//
//  Pins `NormalBookCell.shouldPulseReadButton(previous:current:)`: the display-
//  only trigger that fires the success haptic + Read-button pulse ONLY on the
//  transition into `.downloadSuccessful`. Reads button state only — no download
//  machinery is exercised.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

@MainActor
final class DownloadCompleteMomentTests: XCTestCase {

    /// Fires on the transition INTO downloadSuccessful (the celebration moment).
    func test_shouldPulseReadButton_firesOnEntryToDownloadSuccessful() {
        XCTAssertTrue(NormalBookCell.shouldPulseReadButton(previous: .downloadInProgress, current: .downloadSuccessful),
                      "Transition downloadInProgress → downloadSuccessful must pulse the Read button.")
    }

    /// Does NOT re-fire while already in downloadSuccessful (no repeated pulse).
    func test_shouldPulseReadButton_doesNotRefireWhenAlreadySuccessful() {
        XCTAssertFalse(NormalBookCell.shouldPulseReadButton(previous: .downloadSuccessful, current: .downloadSuccessful),
                       "Already-successful → successful must NOT pulse again — kills the drop-`previous != .downloadSuccessful` mutation.")
    }

    /// Does NOT fire for unrelated transitions.
    func test_shouldPulseReadButton_ignoresOtherStates() {
        XCTAssertFalse(NormalBookCell.shouldPulseReadButton(previous: .downloadInProgress, current: .downloadFailed),
                       "A failed download must not pulse the Read button.")
        XCTAssertFalse(NormalBookCell.shouldPulseReadButton(previous: .canBorrow, current: .downloadNeeded),
                       "Unrelated transitions must not pulse — kills the `current == .downloadSuccessful` → true mutation.")
    }

    // MARK: - Progress high-water-mark reset (PP-4748)

    /// Resets the progress display on entry into the downloading state so a
    /// cancel→retry doesn't strand the bar at the previous download's high.
    func test_shouldResetDownloadProgress_resetsOnEntryToDownloading() {
        XCTAssertTrue(NormalBookCell.shouldResetDownloadProgress(wasDownloading: false, isDownloading: true),
                      "false→true (retry after cancel) must reset the progress high-water mark.")
    }

    /// Does NOT reset while a download is already in progress (bar keeps climbing).
    func test_shouldResetDownloadProgress_doesNotResetWhileDownloading() {
        XCTAssertFalse(NormalBookCell.shouldResetDownloadProgress(wasDownloading: true, isDownloading: true),
                       "true→true must NOT reset — kills the drop-`!wasDownloading` mutation that would zero the bar mid-download.")
    }

    /// Does NOT reset when leaving the downloading state or while idle.
    func test_shouldResetDownloadProgress_doesNotResetOutsideEntry() {
        XCTAssertFalse(NormalBookCell.shouldResetDownloadProgress(wasDownloading: true, isDownloading: false),
                       "true→false (finished/cancelled) must not trigger a reset.")
        XCTAssertFalse(NormalBookCell.shouldResetDownloadProgress(wasDownloading: false, isDownloading: false),
                       "false→false (idle) must not reset — kills the always-true and `isDownloading`-only mutations.")
    }
}

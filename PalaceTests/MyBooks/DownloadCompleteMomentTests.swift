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
}

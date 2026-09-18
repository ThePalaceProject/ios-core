//
//  AudiobookDownloadProgressPolicyTests.swift
//  PalaceTests
//
//  The player's download bar is a promise that something is being waited ON.
//  For an LCP audiobook the toolkit's "download" is local decryption of tracks
//  out of the already-present `.lcpa`, and `LCPStreamingPlayer` plays from the
//  license without waiting for it — so the bar kept running beside working
//  transport controls. Device recording, build 505: it read 37% then 62% AFTER
//  the archive had been stored, while the book was playing.
//
//  Two inputs, four cells, all four asserted. The space is finite, so it is
//  enumerated rather than sampled.
//

import XCTest
@testable import Palace

final class AudiobookDownloadProgressPolicyTests: XCTestCase {

    // MARK: - The wait window (the one cell that shows the bar)

    /// The bar's whole remaining job: before audio starts, a transfer IS the
    /// wait, and a silent screen is what the toolkit bar existed to prevent.
    func testDownloadingBeforePlaybackStarts_showsTheBar() {
        XCTAssertTrue(
            AudiobookDownloadProgressPolicy.shouldShowPlayerDownloadBar(
                isDownloading: true,
                hasStartedPlayback: false
            ),
            "before audio starts the patron is genuinely waiting — the bar is the only signal they have"
        )
    }

    // MARK: - The defect

    /// The reported regression: audio is playing and a determinate download bar
    /// sits under it, describing decryption the patron is not blocked on.
    func testDownloadingAfterPlaybackStarted_hidesTheBar() {
        XCTAssertFalse(
            AudiobookDownloadProgressPolicy.shouldShowPlayerDownloadBar(
                isDownloading: true,
                hasStartedPlayback: true
            ),
            "once audio has started the transfer is background plumbing — a bar beside working transport controls tells the patron to wait for nothing"
        )
    }

    // MARK: - Nothing transferring

    func testNotDownloadingBeforePlayback_hidesTheBar() {
        XCTAssertFalse(
            AudiobookDownloadProgressPolicy.shouldShowPlayerDownloadBar(
                isDownloading: false,
                hasStartedPlayback: false
            )
        )
    }

    func testNotDownloadingAfterPlayback_hidesTheBar() {
        XCTAssertFalse(
            AudiobookDownloadProgressPolicy.shouldShowPlayerDownloadBar(
                isDownloading: false,
                hasStartedPlayback: true
            ),
            "the steady state of a playing book — no transfer, no bar"
        )
    }

    // NOTE: a `testPausedAfterPlaying_stillHidesTheBar` case was removed here.
    // It was byte-identical to `testDownloadingAfterPlaybackStarted_hidesTheBar`
    // — same two inputs, same expectation — so it asserted nothing new and only
    // made the table look better covered than it was. The pause SEMANTIC lives
    // where it can actually fail: `AudiobookSessionPresenterTests` drives a real
    // `.playing` then `.idle` and asserts the latch survives.

}

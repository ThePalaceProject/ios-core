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
//  That fix went too far. It hid the bar on `hasStartedPlayback` alone, and
//  `isDownloading` cannot tell LOCAL DECRYPTION from the NETWORK FETCH of the
//  `.lcpa` itself. With streaming on, tapping Listen plays immediately while a
//  0.7-1 GB archive is still transferring — so the bar vanished on the one
//  transfer whose outcome the patron actually depends on. Measured on Moes Max
//  (build 507): 'Dungeon Crawler Carl' read `download-successful` in the
//  registry with NO archive on disk, and would not play in airplane mode.
//
//  The rule, stated as the patron experiences it: if playback would FAIL in
//  airplane mode because the archive is still coming down, show the bar.
//
//  Three inputs, eight cells, all eight asserted.
//

import XCTest
@testable import Palace

final class AudiobookDownloadProgressPolicyTests: XCTestCase {

    // MARK: - The archive fetch (shows regardless of playback)

    /// The defect this policy now exists to prevent. Streaming means audio
    /// starts before the archive lands, so `hasStartedPlayback` is TRUE while
    /// the only transfer that decides offline availability is still running.
    func testFetchingArchive_showsTheBar_evenWhilePlaying() {
        XCTAssertTrue(
            AudiobookDownloadProgressPolicy.shouldShowPlayerDownloadBar(
                isDownloading: true,
                hasStartedPlayback: true,
                isFetchingArchive: true
            ),
            "the .lcpa is still transferring — playback would fail in airplane mode, so the bar must show")
    }

    func testFetchingArchive_showsTheBar_whenToolkitReportsNoDownload() {
        XCTAssertTrue(
            AudiobookDownloadProgressPolicy.shouldShowPlayerDownloadBar(
                isDownloading: false,
                hasStartedPlayback: true,
                isFetchingArchive: true
            ),
            "the archive fetch is a Palace-side transfer the toolkit flag does not see — it alone must summon the bar")
    }

    func testFetchingArchive_showsTheBar_beforePlaybackToo() {
        XCTAssertTrue(
            AudiobookDownloadProgressPolicy.shouldShowPlayerDownloadBar(
                isDownloading: false,
                hasStartedPlayback: false,
                isFetchingArchive: true
            ),
            "an archive fetch before playback is the plainest wait there is")
        XCTAssertTrue(
            AudiobookDownloadProgressPolicy.shouldShowPlayerDownloadBar(
                isDownloading: true,
                hasStartedPlayback: false,
                isFetchingArchive: true
            ),
            "both signals active before playback still shows the bar")
    }

    // MARK: - Local decryption after playback (the 264676c7d fix, PRESERVED)

    /// The original regression must stay fixed: with the archive already on
    /// disk, `isDownloading` describes track decryption the streaming player
    /// does not wait for. That is the 37%/62%-while-playing bar.
    func testDecryptionAfterPlaybackStarted_stillHidesTheBar() {
        XCTAssertFalse(
            AudiobookDownloadProgressPolicy.shouldShowPlayerDownloadBar(
                isDownloading: true,
                hasStartedPlayback: true,
                isFetchingArchive: false
            ),
            "archive is local; this is decryption the patron is not blocked on — the bar would tell them to wait for nothing")
    }

    // MARK: - The wait window (unchanged)

    // MARK: - The wait window (the one cell that shows the bar)

    /// The bar's whole remaining job: before audio starts, a transfer IS the
    /// wait, and a silent screen is what the toolkit bar existed to prevent.
    func testDownloadingBeforePlaybackStarts_showsTheBar() {
        XCTAssertTrue(
            AudiobookDownloadProgressPolicy.shouldShowPlayerDownloadBar(
                isDownloading: true,
                hasStartedPlayback: false,
                isFetchingArchive: false
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
                hasStartedPlayback: true,
                isFetchingArchive: false
            ),
            "once audio has started the transfer is background plumbing — a bar beside working transport controls tells the patron to wait for nothing"
        )
    }

    // MARK: - Nothing transferring

    func testNotDownloadingBeforePlayback_hidesTheBar() {
        XCTAssertFalse(
            AudiobookDownloadProgressPolicy.shouldShowPlayerDownloadBar(
                isDownloading: false,
                hasStartedPlayback: false,
                isFetchingArchive: false
            )
        )
    }

    func testNotDownloadingAfterPlayback_hidesTheBar() {
        XCTAssertFalse(
            AudiobookDownloadProgressPolicy.shouldShowPlayerDownloadBar(
                isDownloading: false,
                hasStartedPlayback: true,
                isFetchingArchive: false
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

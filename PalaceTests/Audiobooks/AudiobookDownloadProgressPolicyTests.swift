//
//  AudiobookDownloadProgressPolicyTests.swift
//
//  For LCP audiobooks the toolkit's "download" may be local decryption of an
//  archive already on disk (build 505 showed the bar running during playback)
//  or the network fetch of a 0.7-1 GB `.lcpa` while streaming plays (build 507:
//  hiding the bar on playback left a book with no archive on disk). Rule: show
//  the bar if playback would fail in airplane mode because the archive is still
//  downloading. Three inputs, eight cells, all asserted.
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
    /// NOTE: this is the same (T,T,F) cell as
    /// `testDownloadingAfterPlaybackStarted_hidesTheBar` below. Kept as a
    /// separate, differently-named assertion because it pins a DIFFERENT
    /// contract on the same input: that narrowing the rule for archive fetches
    /// did not reopen the decryption bar 264676c7d removed. Review flagged the
    /// duplication; it is deliberate and now says so.
    func testDecryptionAfterPlaybackStarted_stillHidesTheBar() {
        XCTAssertFalse(
            AudiobookDownloadProgressPolicy.shouldShowPlayerDownloadBar(
                isDownloading: true,
                hasStartedPlayback: true,
                isFetchingArchive: false
            ),
            "archive is local; this is decryption the patron is not blocked on — the bar would tell them to wait for nothing")
    }

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


    // MARK: - Which number the bar shows

    /// The archive-wins rule, previously inline in the SwiftUI body and so
    /// unassertable. Its failure mode is the defect this policy exists to fix.
    func testBarProgress_prefersTheArchiveNumberWhenAnArchiveIsTransferring() {
        XCTAssertEqual(
            AudiobookDownloadProgressPolicy.barProgress(archiveProgress: 0.6, overallDownloadProgress: 0.0),
            0.6, accuracy: 0.001,
            "with the archive transferring the bar must show the ARCHIVE's number — the toolkit's reads ~0 during that window, which is the frozen bar")
    }

    func testBarProgress_fallsBackToTheToolkitNumberWhenNoArchiveIsTransferring() {
        XCTAssertEqual(
            AudiobookDownloadProgressPolicy.barProgress(archiveProgress: nil, overallDownloadProgress: 0.42),
            0.42, accuracy: 0.001,
            "with no archive fetch the toolkit's decryption progress is the only number there is")
    }

    /// Zero is a REAL archive progress, not an absent one — the seed sets it.
    /// Coalescing on value rather than on nil would show the toolkit's number
    /// at the exact moment an archive fetch begins.
    func testBarProgress_treatsZeroArchiveProgressAsPresent() {
        XCTAssertEqual(
            AudiobookDownloadProgressPolicy.barProgress(archiveProgress: 0, overallDownloadProgress: 0.9),
            0, accuracy: 0.001,
            "a just-seeded archive fetch reads 0 and must not borrow the toolkit's unrelated number")
    }
}

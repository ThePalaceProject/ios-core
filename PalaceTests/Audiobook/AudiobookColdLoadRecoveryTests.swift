//
//  AudiobookColdLoadRecoveryTests.swift
//  PalaceTests
//
//  Regression coverage for PP-4542: the LCP audiobook first-cold-open
//  "Audiobook Unavailable" failure. The toolkit-side fix
//  (LCPResourceLoaderDelegate cold-load retry) is the primary repair; this
//  pins the APP-side belt-and-suspenders guard — a bounded one-shot silent
//  auto-reopen on a cold-load `.playbackFailed` before the alert is shown.
//
//  Like the OverDrive re-fulfill guard, the full handleManagerState ->
//  openAudiobook wiring is auth-gated and validated on device/sim; here we
//  pin the pure decision predicate (the per-session bound
//  and the cold-vs-warm distinction) so the recovery semantics can't drift.
//

import XCTest
@testable import Palace

@MainActor
final class AudiobookColdLoadRecoveryTests: XCTestCase {

    // Cold load (playback never started), a book to reopen, first failure → reopen.
    func testColdLoad_firstFailure_triggersAutoReopen() {
        XCTAssertTrue(AudiobookSessionManager.shouldAutoReopenOnColdLoadFailure(
            hasEverStartedPlayback: false, hasCurrentBook: true, alreadyAttempted: false),
            "A first cold-load failure with a current book must silently auto-reopen once — the regression (rangeOutOfBounds on a not-yet-materialized LCP package) recovers on reopen")
    }

    // Warm failure: playback already started this session → NOT a cold-load reopen.
    func testWarmFailure_afterPlaybackStarted_doesNotAutoReopen() {
        XCTAssertFalse(AudiobookSessionManager.shouldAutoReopenOnColdLoadFailure(
            hasEverStartedPlayback: true, hasCurrentBook: true, alreadyAttempted: false),
            "A failure AFTER playback has started is not a cold-load race — silently reopening would interrupt a real session and mask a genuine mid-playback error")
    }

    // No current book → nothing to reopen.
    func testNoCurrentBook_doesNotAutoReopen() {
        XCTAssertFalse(AudiobookSessionManager.shouldAutoReopenOnColdLoadFailure(
            hasEverStartedPlayback: false, hasCurrentBook: false, alreadyAttempted: false),
            "Without a current book there is nothing to reopen")
    }

    // Bounded: a second cold-load failure in the same session must surface the alert, not loop.
    func testSecondFailure_alreadyAttempted_surfacesAlertNotLoop() {
        XCTAssertFalse(AudiobookSessionManager.shouldAutoReopenOnColdLoadFailure(
            hasEverStartedPlayback: false, hasCurrentBook: true, alreadyAttempted: true),
            "Bounded to one reopen per book per session — a persistent cold-load failure must reach the 'Audiobook Unavailable' alert instead of looping the auto-reopen")
    }

    // MARK: - Reopen when the archive lands

    /// The case the patron hit: a streamed session stalls, the package finishes
    /// downloading, and nothing rebinds the session to the file. Reopening is
    /// what quitting and relaunching does by hand.
    func testLandedArchive_onAStalledStreamedSession_reopens() {
        XCTAssertTrue(AudiobookSessionManager.shouldReopenForLandedArchive(
            sessionIsStreaming: true,
            contentIsLocal: true,
            isPlaying: false,
            hasCurrentBook: true,
            alreadyReopened: false
        ))
    }

    /// A working stream is never interrupted. Reopening audible playback would
    /// trade a stall the patron does not have for a gap they would hear.
    func testLandedArchive_whileAudioIsPlaying_doesNotReopen() {
        XCTAssertFalse(AudiobookSessionManager.shouldReopenForLandedArchive(
            sessionIsStreaming: true,
            contentIsLocal: true,
            isPlaying: true,
            hasCurrentBook: true,
            alreadyReopened: false
        ))
    }

    /// A session already reading the file has nothing to gain and would restart
    /// playback for no reason.
    func testLandedArchive_onALocalSession_doesNotReopen() {
        XCTAssertFalse(AudiobookSessionManager.shouldReopenForLandedArchive(
            sessionIsStreaming: false,
            contentIsLocal: true,
            isPlaying: false,
            hasCurrentBook: true,
            alreadyReopened: false
        ))
    }

    /// A falling transfer edge can arrive without the package being on disk (a
    /// cancelled or failed transfer). Reopening then just rebuilds the same
    /// stalled stream.
    func testLandedArchive_whenTheContentIsNotActuallyLocal_doesNotReopen() {
        XCTAssertFalse(AudiobookSessionManager.shouldReopenForLandedArchive(
            sessionIsStreaming: true,
            contentIsLocal: false,
            isPlaying: false,
            hasCurrentBook: true,
            alreadyReopened: false
        ))
    }

    /// Bounded to one per book, so a transfer that reports several falling edges
    /// cannot reopen repeatedly.
    func testLandedArchive_afterOneReopen_doesNotReopenAgain() {
        XCTAssertFalse(AudiobookSessionManager.shouldReopenForLandedArchive(
            sessionIsStreaming: true,
            contentIsLocal: true,
            isPlaying: false,
            hasCurrentBook: true,
            alreadyReopened: true
        ))
    }

    /// An edge for a book no session holds has nothing to reopen.
    func testLandedArchive_withNoCurrentBook_doesNotReopen() {
        XCTAssertFalse(AudiobookSessionManager.shouldReopenForLandedArchive(
            sessionIsStreaming: true,
            contentIsLocal: true,
            isPlaying: false,
            hasCurrentBook: false,
            alreadyReopened: false
        ))
    }
}

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
//  openAudiobook wiring is auth-gated and proven by SoD review + device/sim
//  validation; here we pin the pure decision predicate (the per-session bound
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
}

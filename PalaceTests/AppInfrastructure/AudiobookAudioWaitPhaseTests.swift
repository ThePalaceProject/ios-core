//
//  AudiobookAudioWaitPhaseTests.swift
//  PalaceTests
//
//  When the audiobook player shows that it is waiting for audio after playback
//  has begun (PP-5399).
//

import XCTest
@testable import Palace

final class AudiobookAudioWaitPhaseTests: XCTestCase {
    private typealias View = AudiobookMorphingPlayerView

    // MARK: - isAwaitingAudio

    /// A chapter change unloads the player until its seek lands.
    func testAwaitingAudio_whenNotLoadedMidSession_isWaiting() {
        XCTAssertTrue(View.isAwaitingAudio(hasStartedPlayback: true, isLoaded: false, transportIsWaitingForData: false))
    }

    /// The player can report loaded before any audio plays; AVFoundation's own
    /// waiting state is what tells the two apart.
    func testAwaitingAudio_whenLoadedButTransportWaiting_isWaiting() {
        XCTAssertTrue(View.isAwaitingAudio(hasStartedPlayback: true, isLoaded: true, transportIsWaitingForData: true))
    }

    /// Playing, or paused with the chapter in place, is not a wait.
    func testAwaitingAudio_whenLoadedAndNotWaiting_isNotWaiting() {
        XCTAssertFalse(View.isAwaitingAudio(hasStartedPlayback: true, isLoaded: true, transportIsWaitingForData: false))
    }

    /// Unloaded and with the transport waiting is still one wait.
    func testAwaitingAudio_whenNotLoadedAndTransportWaiting_isWaiting() {
        XCTAssertTrue(View.isAwaitingAudio(hasStartedPlayback: true, isLoaded: false, transportIsWaitingForData: true))
    }

    /// Before the first playback the loading overlay already covers the wait,
    /// whatever the player reports.
    func testAwaitingAudio_beforePlaybackHasStarted_isNotWaiting() {
        XCTAssertFalse(View.isAwaitingAudio(hasStartedPlayback: false, isLoaded: false, transportIsWaitingForData: true))
        XCTAssertFalse(View.isAwaitingAudio(hasStartedPlayback: false, isLoaded: true, transportIsWaitingForData: true))
        XCTAssertFalse(View.isAwaitingAudio(hasStartedPlayback: false, isLoaded: false, transportIsWaitingForData: false))
    }

    // MARK: - audioWaitPhase

    func testPhase_withNoWait_isNone() {
        XCTAssertEqual(View.audioWaitPhase(waitingFor: nil), .none)
    }

    /// A fast chapter change shows nothing, so it does not flicker.
    func testPhase_belowTheBusyThreshold_isNone() {
        XCTAssertEqual(View.audioWaitPhase(waitingFor: View.audioWaitBusyThreshold - 0.01), .none)
    }

    func testPhase_fromTheBusyThreshold_isBusy() {
        XCTAssertEqual(View.audioWaitPhase(waitingFor: View.audioWaitBusyThreshold), .busy)
        XCTAssertEqual(View.audioWaitPhase(waitingFor: View.audioWaitSlowThreshold - 0.01), .busy)
    }

    /// Past the slow threshold silence reads as a hang, so the wait is put in words.
    func testPhase_fromTheSlowThreshold_isSlow() {
        XCTAssertEqual(View.audioWaitPhase(waitingFor: View.audioWaitSlowThreshold), .slow)
        XCTAssertEqual(View.audioWaitPhase(waitingFor: 60), .slow)
    }

    // MARK: - nextAudioWait

    private let now = Date(timeIntervalSinceReferenceDate: 1_000)

    /// The first waiting sample starts the clock, and shows nothing yet.
    func testNextWait_whenAWaitBegins_startsTheClockAndShowsNothing() {
        let next = View.nextAudioWait(startedAt: nil, waiting: true, now: now)
        XCTAssertEqual(next.startedAt, now)
        XCTAssertEqual(next.phase, .none)
    }

    /// A wait keeps its start, so the phase grows with it. Restarting the clock
    /// on every sample would keep the spinner from ever appearing.
    func testNextWait_whileTheWaitContinues_keepsItsStart() {
        let start = now.addingTimeInterval(-1)
        let next = View.nextAudioWait(startedAt: start, waiting: true, now: now)
        XCTAssertEqual(next.startedAt, start)
        XCTAssertEqual(next.phase, .busy)
    }

    func testNextWait_afterALongWait_isSlow() {
        let next = View.nextAudioWait(startedAt: now.addingTimeInterval(-9), waiting: true, now: now)
        XCTAssertEqual(next.phase, .slow)
    }

    /// The wait ends the moment audio arrives, so no spinner or "Loading…"
    /// stays on screen afterwards.
    func testNextWait_whenTheWaitEnds_clearsIt() {
        let next = View.nextAudioWait(startedAt: now.addingTimeInterval(-9), waiting: false, now: now)
        XCTAssertNil(next.startedAt)
        XCTAssertEqual(next.phase, .none)
    }
}

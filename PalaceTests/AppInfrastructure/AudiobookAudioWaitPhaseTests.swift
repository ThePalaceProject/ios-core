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

    /// Before the first playback the loading overlay already covers the wait.
    func testAwaitingAudio_beforePlaybackHasStarted_isNotWaiting() {
        XCTAssertFalse(View.isAwaitingAudio(hasStartedPlayback: false, isLoaded: false, transportIsWaitingForData: true))
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
}

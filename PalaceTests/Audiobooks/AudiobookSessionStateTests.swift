//
//  AudiobookSessionStateTests.swift
//  PalaceTests
//
//  Tests for AudiobookSessionManager state machine transitions and published state.
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import Combine
import XCTest
@testable import Palace

/// SRS: AUDIO-001 -- Playback state machine transitions correctly
@MainActor
final class AudiobookSessionStateTransitionTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        // AudiobookSessionManager.shared is a singleton — reset before each
        // test so .state assertions see .idle and not pollution from a prior
        // test (same pattern as PlaybackBootstrapperTests).
        await AudiobookSessionManager.shared.stopPlayback(dismissPhoneUI: false)
    }

    // MARK: - State Enum Tests

    /// SRS: AUDIO-001 -- Playback state machine transitions correctly
    func testIdleState_isNotActive() {
        let state = AudiobookSessionState.idle
        XCTAssertFalse(state.isActive)
        XCTAssertNil(state.bookId)
    }

    /// SRS: AUDIO-001 -- Playback state machine transitions correctly
    func testLoadingState_isActive_andHasBookId() {
        let state = AudiobookSessionState.loading(bookId: "book-abc")
        XCTAssertTrue(state.isActive)
        XCTAssertEqual(state.bookId, "book-abc")
    }

    /// SRS: AUDIO-001 -- Playback state machine transitions correctly
    func testPlayingState_isActive_andHasBookId() {
        let state = AudiobookSessionState.playing(bookId: "book-xyz")
        XCTAssertTrue(state.isActive)
        XCTAssertEqual(state.bookId, "book-xyz")
    }

    /// SRS: AUDIO-001 -- Playback state machine transitions correctly
    func testPausedState_isActive_andHasBookId() {
        let state = AudiobookSessionState.paused(bookId: "book-123")
        XCTAssertTrue(state.isActive)
        XCTAssertEqual(state.bookId, "book-123")
    }

    /// SRS: AUDIO-001 -- Playback state machine transitions correctly
    func testErrorState_isNotActive_butHasBookId() {
        let state = AudiobookSessionState.error(bookId: "book-err", message: "fail")
        XCTAssertFalse(state.isActive)
        XCTAssertEqual(state.bookId, "book-err")
    }

    /// SRS: AUDIO-001 -- Playback state machine transitions correctly
    func testStateEquality_sameStates() {
        XCTAssertEqual(AudiobookSessionState.idle, AudiobookSessionState.idle)
        XCTAssertEqual(
            AudiobookSessionState.loading(bookId: "a"),
            AudiobookSessionState.loading(bookId: "a")
        )
        XCTAssertEqual(
            AudiobookSessionState.playing(bookId: "b"),
            AudiobookSessionState.playing(bookId: "b")
        )
        XCTAssertEqual(
            AudiobookSessionState.paused(bookId: "c"),
            AudiobookSessionState.paused(bookId: "c")
        )
        XCTAssertEqual(
            AudiobookSessionState.error(bookId: "d", message: "msg"),
            AudiobookSessionState.error(bookId: "d", message: "msg")
        )
    }

    /// SRS: AUDIO-001 -- Playback state machine transitions correctly
    func testStateEquality_differentStates() {
        XCTAssertNotEqual(AudiobookSessionState.idle, AudiobookSessionState.playing(bookId: "a"))
        XCTAssertNotEqual(
            AudiobookSessionState.loading(bookId: "a"),
            AudiobookSessionState.playing(bookId: "a")
        )
        XCTAssertNotEqual(
            AudiobookSessionState.playing(bookId: "a"),
            AudiobookSessionState.paused(bookId: "a")
        )
    }

    /// SRS: AUDIO-001 -- Playback state machine transitions correctly
    func testStateEquality_differentBookIds() {
        XCTAssertNotEqual(
            AudiobookSessionState.playing(bookId: "a"),
            AudiobookSessionState.playing(bookId: "b")
        )
        // Same bookId must be equal (sanity check against reflexivity)
        XCTAssertEqual(
            AudiobookSessionState.playing(bookId: "a"),
            AudiobookSessionState.playing(bookId: "a"),
            "Same bookId must produce equal states"
        )
    }

    // MARK: - Session Manager Initial State

    /// SRS: AUDIO-001 -- Playback state machine transitions correctly
    @MainActor
    func testSessionManager_initialState_isIdle() async {
        let manager = AudiobookSessionManager.shared
        // Reset to idle in case a previous test modified the singleton
        await manager.stopPlayback(dismissPhoneUI: false)

        XCTAssertEqual(manager.state, .idle)
        XCTAssertNil(manager.currentBook)
        XCTAssertFalse(manager.isPlaying)
        XCTAssertTrue(manager.currentChapters.isEmpty)
        XCTAssertNil(manager.currentChapter)
        XCTAssertNil(manager.currentPosition)
        XCTAssertNil(manager.coverImage)
    }

    /// SRS: AUDIO-001 -- Playback state machine transitions correctly
    func testSessionManager_play_withoutManager_doesNotCrash() {
        let manager = AudiobookSessionManager.shared
        // Should be a no-op when no manager is bound
        manager.play()
        XCTAssertFalse(manager.isPlaying)
        // State must still be .idle (no transition without a manager)
        XCTAssertEqual(manager.state, .idle, "State must remain idle when play() is called without a manager")
    }

    /// SRS: AUDIO-001 -- Playback state machine transitions correctly
    func testSessionManager_pause_withoutManager_doesNotCrash() {
        let manager = AudiobookSessionManager.shared
        // Should be a no-op when no manager is bound
        manager.pause()
        XCTAssertFalse(manager.isPlaying)
        // State must still be .idle (no transition without a manager)
        XCTAssertEqual(manager.state, .idle, "State must remain idle when pause() is called without a manager")
    }

    /// SRS: AUDIO-001 -- Playback state machine transitions correctly
    func testSessionManager_togglePlayPause_withoutManager_doesNotCrash() {
        let manager = AudiobookSessionManager.shared
        manager.togglePlayPause()
        XCTAssertFalse(manager.isPlaying)
        // State must remain idle after toggle without a manager
        XCTAssertEqual(manager.state, .idle, "State must remain idle when togglePlayPause() is called without a manager")
    }

    /// SRS: AUDIO-001 -- Playback state machine transitions correctly
    func testSessionManager_skipToChapter_withoutManager_doesNotCrash() {
        let manager = AudiobookSessionManager.shared
        // Should be a no-op with no manager
        manager.skipToChapter(at: 0)
        manager.skipToChapter(at: -1)
        manager.skipToChapter(at: 999)
        // State must remain idle after all skip calls
        XCTAssertEqual(manager.state, .idle, "State must remain idle after skipToChapter calls without a manager")
    }

    /// SRS: AUDIO-001 -- Playback state machine transitions correctly
    func testSessionManager_cyclePlaybackRate_withoutManager_returnsNormalTime() {
        let manager = AudiobookSessionManager.shared
        let rate = manager.cyclePlaybackRate()
        XCTAssertEqual(rate, .normalTime, "Without a manager, should return normalTime")
        // Calling again must return the same value (deterministic for no-op case)
        let rate2 = manager.cyclePlaybackRate()
        XCTAssertEqual(rate2, .normalTime,
                       "Repeated cyclePlaybackRate without a manager must always return normalTime")
    }

    /// SRS: AUDIO-001 -- Playback state machine transitions correctly
    func testSessionManager_stopPlayback_resetsState() async {
        let manager = AudiobookSessionManager.shared
        await manager.stopPlayback()

        XCTAssertEqual(manager.state, .idle)
        XCTAssertNil(manager.currentBook)
        XCTAssertNil(manager.manager)
        XCTAssertNil(manager.audiobook)
        XCTAssertFalse(manager.isPlaying)
        XCTAssertTrue(manager.currentChapters.isEmpty)
        XCTAssertNil(manager.currentChapter)
        XCTAssertNil(manager.currentPosition)
        XCTAssertNil(manager.coverImage)
    }

    /// SRS: AUDIO-001 -- Playback state machine transitions correctly
    func testSessionManager_updateCoverImage_setsImage() {
        let manager = AudiobookSessionManager.shared
        let testImage = UIImage()
        manager.updateCoverImage(testImage)
        XCTAssertNotNil(manager.coverImage)
        // Updating with nil must clear the image
        manager.updateCoverImage(nil)
        XCTAssertNil(manager.coverImage, "updateCoverImage(nil) must clear the coverImage property")
    }

    /// SRS: AUDIO-001 -- Playback state machine transitions correctly
    func testSessionManager_updateCoverImage_nil_clearsImage() {
        let manager = AudiobookSessionManager.shared
        manager.updateCoverImage(UIImage())
        manager.updateCoverImage(nil)
        XCTAssertNil(manager.coverImage)
        // Setting a new image after clearing must work
        manager.updateCoverImage(UIImage())
        XCTAssertNotNil(manager.coverImage, "Setting image after clearing must make coverImage non-nil again")
    }

    // MARK: - Publisher Tests

    /// SRS: AUDIO-001 -- Playback state machine transitions correctly
    func testSessionManager_stopPlayback_publishesIdleState() async {
        let manager = AudiobookSessionManager.shared
        var receivedStates: [AudiobookSessionState] = []
        let cancellable = manager.playbackStatePublisher
            .sink { state in
                receivedStates.append(state)
            }

        await manager.stopPlayback()

        XCTAssertTrue(receivedStates.contains(.idle), "Should publish idle state after stop")
        cancellable.cancel()
    }
}

// MARK: - AudiobookSessionError Tests

@MainActor
final class AudiobookSessionErrorDescriptionTests: XCTestCase {

    /// SRS: AUDIO-001 -- Playback state machine transitions correctly
    func testAllErrorCases_haveNonEmptyDescriptions() {
        let errors: [AudiobookSessionError] = [
            .notAuthenticated,
            .notDownloaded,
            .networkUnavailable,
            .manifestLoadFailed,
            .playerCreationFailed,
            .alreadyLoading,
            .unknown("custom")
        ]

        for error in errors {
            XCTAssertFalse(error.localizedDescription.isEmpty,
                           "\(error) should have a non-empty description")
        }
    }

    /// SRS: AUDIO-001 -- Playback state machine transitions correctly
    func testUnknownError_preservesCustomMessage() {
        let msg = "Something specific went wrong"
        let error = AudiobookSessionError.unknown(msg)
        XCTAssertEqual(error.localizedDescription, msg)
        // A different message must produce a different description
        let otherError = AudiobookSessionError.unknown("Different error")
        XCTAssertNotEqual(error.localizedDescription, otherError.localizedDescription,
                          "Unknown errors with different messages must have different descriptions")
    }

    /// SRS: AUDIO-001 -- Playback state machine transitions correctly
    func testErrorEquatable_sameTypes() {
        XCTAssertEqual(AudiobookSessionError.notAuthenticated, .notAuthenticated)
        XCTAssertEqual(AudiobookSessionError.unknown("x"), .unknown("x"))
    }

    /// SRS: AUDIO-001 -- Playback state machine transitions correctly
    func testErrorEquatable_differentTypes() {
        XCTAssertNotEqual(AudiobookSessionError.notAuthenticated, .notDownloaded)
        XCTAssertNotEqual(AudiobookSessionError.unknown("a"), .unknown("b"))
    }
}

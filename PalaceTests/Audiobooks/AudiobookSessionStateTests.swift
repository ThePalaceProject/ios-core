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

    /// Locally-constructed session manager — Module B replaced the singleton,
    /// so each test gets a fresh instance with no pollution to reset.
    private var manager: AudiobookSessionManager!
    /// Per-test isolated container — built via `makeTestAppContainer()` so
    /// each test method gets a fresh service graph (no cross-test pollution
    /// through `AppContainer._cached`).
    private var appContainer: AppContainer!

    override func setUp() async throws {
        try await super.setUp()
        appContainer = makeTestAppContainer()
        manager = AudiobookSessionManager(appContainer: appContainer)
    }

    override func tearDown() async throws {
        manager = nil
        appContainer = nil
        try await super.tearDown()
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
    func testSessionManager_initialState_isIdle() {
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
        // Should be a no-op when no manager is bound
        manager.play()
        XCTAssertFalse(manager.isPlaying)
        // State must still be .idle (no transition without a manager)
        XCTAssertEqual(manager.state, .idle, "State must remain idle when play() is called without a manager")
    }

    /// SRS: AUDIO-001 -- Playback state machine transitions correctly
    func testSessionManager_pause_withoutManager_doesNotCrash() {
        // Should be a no-op when no manager is bound
        manager.pause()
        XCTAssertFalse(manager.isPlaying)
        // State must still be .idle (no transition without a manager)
        XCTAssertEqual(manager.state, .idle, "State must remain idle when pause() is called without a manager")
    }

    /// SRS: AUDIO-001 -- Playback state machine transitions correctly
    func testSessionManager_togglePlayPause_withoutManager_doesNotCrash() {
        manager.togglePlayPause()
        XCTAssertFalse(manager.isPlaying)
        // State must remain idle after toggle without a manager
        XCTAssertEqual(manager.state, .idle, "State must remain idle when togglePlayPause() is called without a manager")
    }

    /// SRS: AUDIO-001 -- Playback state machine transitions correctly
    func testSessionManager_skipToChapter_withoutManager_doesNotCrash() {
        // Defensive contract: skipToChapter must be a no-op when there is no
        // underlying audiobook manager. Pair-assert that state stays `.idle`
        // AND that isPlaying does not spuriously flip to true (which would
        // indicate the call went deeper than a guard early-return).
        let initialState = manager.state
        let initialPlaying = manager.isPlaying

        manager.skipToChapter(at: 0)
        manager.skipToChapter(at: -1)
        manager.skipToChapter(at: 999)

        XCTAssertEqual(manager.state, .idle,
                       "State must remain idle after skipToChapter calls without a manager")
        XCTAssertEqual(manager.state, initialState,
                       "State must equal the initial state — skip is a no-op without a manager")
        XCTAssertEqual(manager.isPlaying, initialPlaying,
                       "isPlaying must not spuriously flip — skip-without-manager must early-return cleanly")
    }

    /// SRS: AUDIO-001 -- Playback state machine transitions correctly
    func testSessionManager_cyclePlaybackRate_withoutManager_returnsNormalTime() {
        let rate = manager.cyclePlaybackRate()
        XCTAssertEqual(rate, .normalTime, "Without a manager, should return normalTime")
        // Calling again must return the same value (deterministic for no-op case)
        let rate2 = manager.cyclePlaybackRate()
        XCTAssertEqual(rate2, .normalTime,
                       "Repeated cyclePlaybackRate without a manager must always return normalTime")
    }

    /// SRS: AUDIO-001 -- Playback state machine transitions correctly
    func testSessionManager_stopPlayback_resetsState() async {
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
        let testImage = UIImage()
        manager.updateCoverImage(testImage)
        XCTAssertNotNil(manager.coverImage)
        // Updating with nil must clear the image
        manager.updateCoverImage(nil)
        XCTAssertNil(manager.coverImage, "updateCoverImage(nil) must clear the coverImage property")
    }

    /// SRS: AUDIO-001 -- Playback state machine transitions correctly
    func testSessionManager_updateCoverImage_nil_clearsImage() {
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
        var receivedStates: [AudiobookSessionState] = []
        let cancellable = manager.playbackStatePublisher
            .sink { state in
                receivedStates.append(state)
            }

        await manager.stopPlayback()

        XCTAssertTrue(receivedStates.contains(.idle), "Should publish idle state after stop")
        cancellable.cancel()
    }

    // MARK: - PP-4632: stop playback when the playing book is returned

    /// The currently-playing book becoming `.unregistered` (returned / removed /
    /// expired) MUST trigger teardown — the exact PP-4632 condition (a returned
    /// audiobook kept playing because the session never observed the registry).
    func testShouldStopPlayback_currentBookUnregistered_returnsTrue() {
        XCTAssertTrue(AudiobookSessionManager.shouldStopPlaybackOnRegistryChange(
            state: .unregistered, changedIdentifier: "book-1", currentBookIdentifier: "book-1"))
    }

    /// Returning a DIFFERENT book must NOT stop the active player.
    func testShouldStopPlayback_differentBookUnregistered_returnsFalse() {
        XCTAssertFalse(AudiobookSessionManager.shouldStopPlaybackOnRegistryChange(
            state: .unregistered, changedIdentifier: "other-book", currentBookIdentifier: "book-1"))
    }

    /// A non-removal state change for the current book (e.g. `.downloadSuccessful`)
    /// must NOT stop playback — only `.unregistered` (return/expire) does.
    func testShouldStopPlayback_currentBookNonUnregistered_returnsFalse() {
        XCTAssertFalse(AudiobookSessionManager.shouldStopPlaybackOnRegistryChange(
            state: .downloadSuccessful, changedIdentifier: "book-1", currentBookIdentifier: "book-1"))
    }

    /// Nothing playing → never stop. (During account switch, currentBook is
    /// already niled by cleanupActiveContentBeforeAccountSwitch, so the mass
    /// `.unregistered` emissions must no-op here.)
    func testShouldStopPlayback_noCurrentBook_returnsFalse() {
        XCTAssertFalse(AudiobookSessionManager.shouldStopPlaybackOnRegistryChange(
            state: .unregistered, changedIdentifier: "book-1", currentBookIdentifier: nil))
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

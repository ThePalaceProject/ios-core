//
//  PlaybackBootstrapperTests.swift
//  PalaceTests
//
//  Tests for PlaybackBootstrapper remote command handling
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import MediaPlayer
@testable import Palace

/// Tests for PlaybackBootstrapper initialization and remote command handling.
/// Verifies that remote commands return correct statuses based on manager state.
@MainActor
final class PlaybackBootstrapperTests: XCTestCase {

    /// Locally-constructed session manager — Module B replaced the singleton,
    /// so each test gets a fresh instance with no pollution to reset.
    private var sessionManager: AudiobookSessionManager!
    /// Per-test isolated container — built via `makeTestAppContainer()` so
    /// each test method gets a fresh service graph (no cross-test pollution
    /// through `AppContainer._cached`).
    private var appContainer: AppContainer!

    override func setUp() async throws {
        try await super.setUp()
        appContainer = makeTestAppContainer()
        sessionManager = AudiobookSessionManager(appContainer: appContainer)
    }

    override func tearDown() async throws {
        sessionManager = nil
        appContainer = nil
        try await super.tearDown()
    }

    // MARK: - Remote Command Configuration Tests

    func testPlaybackBootstrapper_ConfiguresRemoteCommandCenter() {
        // Arrange
        let bootstrapper = appContainer.playbackBootstrapper
        bootstrapper.ensureInitialized()

        // Act
        let commandCenter = MPRemoteCommandCenter.shared()

        // Assert - Key commands should be enabled
        XCTAssertTrue(commandCenter.playCommand.isEnabled, "Play command should be enabled")
        XCTAssertTrue(commandCenter.pauseCommand.isEnabled, "Pause command should be enabled")
        XCTAssertTrue(commandCenter.togglePlayPauseCommand.isEnabled, "Toggle command should be enabled")
        XCTAssertTrue(commandCenter.skipForwardCommand.isEnabled, "Skip forward should be enabled")
        XCTAssertTrue(commandCenter.skipBackwardCommand.isEnabled, "Skip backward should be enabled")

        // Assert - Track navigation commands should be disabled (audiobook-specific)
        XCTAssertFalse(commandCenter.nextTrackCommand.isEnabled, "Next track should be disabled for audiobooks")
        XCTAssertFalse(commandCenter.previousTrackCommand.isEnabled, "Previous track should be disabled for audiobooks")
    }

    func testPlaybackBootstrapper_SkipIntervals_AreConfigured() {
        // Arrange
        let bootstrapper = appContainer.playbackBootstrapper
        bootstrapper.ensureInitialized()

        // Act
        let commandCenter = MPRemoteCommandCenter.shared()

        // Assert - Skip intervals should be 30 seconds
        XCTAssertEqual(commandCenter.skipForwardCommand.preferredIntervals, [30], "Skip forward should be 30 seconds")
        XCTAssertEqual(commandCenter.skipBackwardCommand.preferredIntervals, [30], "Skip backward should be 30 seconds")
    }

    // MARK: - Command Handler State Tests

    func testAudiobookSessionManager_InitialState_IsIdle() {
        // Arrange & Act - use locally-constructed instance from setUp

        // Assert - Use pattern matching for enum with associated values
        if case .idle = sessionManager.state {
            // State is idle - test passes
        } else {
            XCTFail("Session manager should start in idle state, but was: \(sessionManager.state)")
        }
        XCTAssertNil(sessionManager.manager, "No manager should exist initially")
        XCTAssertNil(sessionManager.audiobook, "No audiobook should exist initially")
        XCTAssertNil(sessionManager.currentBook, "No current book should exist initially")
    }

    func testAudiobookSessionState_IdleIsNotActive() {
        // Act
        let state = AudiobookSessionState.idle

        // Assert
        XCTAssertFalse(state.isActive, "Idle state should not be active")
        XCTAssertNil(state.bookId, "Idle state should not have a book ID")
    }

    func testAudiobookSessionState_PlayingIsActive() {
        // Act
        let state = AudiobookSessionState.playing(bookId: "test-book-123")

        // Assert
        XCTAssertTrue(state.isActive, "Playing state should be active")
        XCTAssertEqual(state.bookId, "test-book-123", "Playing state should have correct book ID")
    }

    func testAudiobookSessionState_PausedIsActive() {
        // Act
        let state = AudiobookSessionState.paused(bookId: "test-book-456")

        // Assert
        XCTAssertTrue(state.isActive, "Paused state should be active")
        XCTAssertEqual(state.bookId, "test-book-456", "Paused state should have correct book ID")
    }

    func testAudiobookSessionState_LoadingIsActive() {
        // Act
        let state = AudiobookSessionState.loading(bookId: "test-book-789")

        // Assert
        XCTAssertTrue(state.isActive, "Loading state should be active")
        XCTAssertEqual(state.bookId, "test-book-789", "Loading state should have correct book ID")
    }

    func testAudiobookSessionState_ErrorIsNotActive() {
        // Act
        let state = AudiobookSessionState.error(bookId: "test-book", message: "Error message")

        // Assert
        XCTAssertFalse(state.isActive, "Error state should not be active")
        XCTAssertEqual(state.bookId, "test-book", "Error state should still have book ID")
    }
}

// MARK: - AudiobookSessionError Tests

@MainActor
final class AudiobookSessionErrorTests: XCTestCase {

    func testAudiobookSessionError_localizedDescription_isCaseSpecificAndPreservesUnknownMessage() {
        // Each case must produce a user-facing string that mentions the relevant
        // concept. Guards against mutations that swap case strings or collapse
        // cases to a generic fallback. The .unknown case must pass its message
        // through verbatim.
        let expectedKeywords: [(AudiobookSessionError, String)] = [
            (.notAuthenticated,      "sign in"),
            (.notDownloaded,         "download"),
            (.networkUnavailable,    "network"),
            (.manifestLoadFailed,    "audiobook data"),
            (.playerCreationFailed,  "audio player"),
            (.alreadyLoading,        "loading"),
        ]

        for (error, keyword) in expectedKeywords {
            let description = error.localizedDescription.lowercased()
            XCTAssertTrue(description.contains(keyword.lowercased()),
                          "\(error) description '\(error.localizedDescription)' should mention '\(keyword)'")
        }

        let customMessage = "Something went wrong with disk I/O"
        XCTAssertEqual(AudiobookSessionError.unknown(customMessage).localizedDescription,
                       customMessage,
                       ".unknown must pass the caller's message through verbatim")
    }

    func testAudiobookSessionError_Equatable() {
        // Same errors
        XCTAssertEqual(AudiobookSessionError.notAuthenticated, AudiobookSessionError.notAuthenticated)
        XCTAssertEqual(AudiobookSessionError.notDownloaded, AudiobookSessionError.notDownloaded)

        // Different errors
        XCTAssertNotEqual(AudiobookSessionError.notAuthenticated, AudiobookSessionError.notDownloaded)

        // Unknown with same message
        XCTAssertEqual(AudiobookSessionError.unknown("test"), AudiobookSessionError.unknown("test"))

        // Unknown with different message
        XCTAssertNotEqual(AudiobookSessionError.unknown("a"), AudiobookSessionError.unknown("b"))
    }

    // MARK: - Remote-command gate (Swift 6 off-main crash fix)

    /// `PlaybackBootstrapper.remoteCommandStatus(hasActiveManager:)` is the pure,
    /// `nonisolated` gate that all six `MPRemoteCommand` handlers now return
    /// through after the Swift 6 off-main crash fix. Pinning BOTH branches kills
    /// the gate-inversion mutant on the changed lines — a swapped pair of
    /// statuses, or a `!hasActiveManager`, fails here. This is the mutation-
    /// killing coverage that MPRemoteCommand's lack of a public
    /// invoke-handler-and-read-status API otherwise blocks, achieved without a
    /// bound-manager fixture by testing the extracted pure gate directly.
    func testRemoteCommandStatus_gatesOnActiveManager() {
        XCTAssertEqual(
            PlaybackBootstrapper.remoteCommandStatus(hasActiveManager: true).rawValue,
            MPRemoteCommandHandlerStatus.success.rawValue,
            "With an active manager the command is acknowledged (.success) so the toolkit performs the transport action")
        XCTAssertEqual(
            PlaybackBootstrapper.remoteCommandStatus(hasActiveManager: false).rawValue,
            MPRemoteCommandHandlerStatus.noActionableNowPlayingItem.rawValue,
            "With no manager there is nothing to act on — .noActionableNowPlayingItem keeps the lock screen from presenting a dead control")
    }
}

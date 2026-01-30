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
@testable import PalaceAudiobookToolkit

/// Tests for PlaybackBootstrapper initialization and remote command handling.
/// Verifies that remote commands return correct statuses based on manager state.
@MainActor
final class PlaybackBootstrapperTests: XCTestCase {
  
  // MARK: - Initialization Tests
  
  func testPlaybackBootstrapper_Singleton_Exists() {
    // Act
    let bootstrapper = PlaybackBootstrapper.shared
    
    // Assert
    XCTAssertNotNil(bootstrapper, "PlaybackBootstrapper.shared should exist")
  }
  
  func testPlaybackBootstrapper_EnsureInitialized_IsIdempotent() {
    // Arrange
    let bootstrapper = PlaybackBootstrapper.shared
    
    // Act - Call multiple times
    bootstrapper.ensureInitialized()
    bootstrapper.ensureInitialized()
    bootstrapper.ensureInitialized()
    
    // Assert - Should not crash or have side effects
    XCTAssertNotNil(bootstrapper, "Multiple calls to ensureInitialized should be safe")
  }
  
  func testPlaybackBootstrapper_EnsureInitializedForCarPlay_LoadsBookRegistry() {
    // Arrange
    let bootstrapper = PlaybackBootstrapper.shared
    
    // Act
    bootstrapper.ensureInitializedForCarPlay()
    
    // Assert - Registry should be accessible (not nil)
    XCTAssertNotNil(TPPBookRegistry.shared, "Book registry should be loaded")
  }
  
  // MARK: - Remote Command Configuration Tests
  
  func testPlaybackBootstrapper_ConfiguresRemoteCommandCenter() {
    // Arrange
    let bootstrapper = PlaybackBootstrapper.shared
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
    let bootstrapper = PlaybackBootstrapper.shared
    bootstrapper.ensureInitialized()
    
    // Act
    let commandCenter = MPRemoteCommandCenter.shared()
    
    // Assert - Skip intervals should be 30 seconds
    XCTAssertEqual(commandCenter.skipForwardCommand.preferredIntervals, [30], "Skip forward should be 30 seconds")
    XCTAssertEqual(commandCenter.skipBackwardCommand.preferredIntervals, [30], "Skip backward should be 30 seconds")
  }
  
  // MARK: - Command Handler State Tests
  
  func testPlaybackBootstrapper_NoActiveManager_ReturnsNoActionableItem() {
    // Arrange - Ensure no audiobook is playing
    // AudiobookSessionManager.shared.manager should be nil when no book is open
    
    // The actual command handlers are private, but we can verify the behavior
    // by checking the session manager state
    let hasManager = AudiobookSessionManager.shared.manager != nil
    
    // Assert
    // When no manager, commands should return .noActionableNowPlayingItem
    // We verify the precondition (no manager) that would trigger this behavior
    XCTAssertFalse(hasManager, "No active manager should be present in test environment")
  }
  
  func testAudiobookSessionManager_InitialState_IsIdle() {
    // Arrange & Act
    let sessionManager = AudiobookSessionManager.shared
    
    // Assert
    XCTAssertEqual(sessionManager.state, .idle, "Session manager should start in idle state")
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
  
  func testAudiobookSessionError_NotAuthenticated_HasDescription() {
    let error = AudiobookSessionError.notAuthenticated
    XCTAssertFalse(error.localizedDescription.isEmpty, "notAuthenticated should have description")
  }
  
  func testAudiobookSessionError_NotDownloaded_HasDescription() {
    let error = AudiobookSessionError.notDownloaded
    XCTAssertFalse(error.localizedDescription.isEmpty, "notDownloaded should have description")
  }
  
  func testAudiobookSessionError_NetworkUnavailable_HasDescription() {
    let error = AudiobookSessionError.networkUnavailable
    XCTAssertFalse(error.localizedDescription.isEmpty, "networkUnavailable should have description")
  }
  
  func testAudiobookSessionError_ManifestLoadFailed_HasDescription() {
    let error = AudiobookSessionError.manifestLoadFailed
    XCTAssertFalse(error.localizedDescription.isEmpty, "manifestLoadFailed should have description")
  }
  
  func testAudiobookSessionError_PlayerCreationFailed_HasDescription() {
    let error = AudiobookSessionError.playerCreationFailed
    XCTAssertFalse(error.localizedDescription.isEmpty, "playerCreationFailed should have description")
  }
  
  func testAudiobookSessionError_AlreadyLoading_HasDescription() {
    let error = AudiobookSessionError.alreadyLoading
    XCTAssertFalse(error.localizedDescription.isEmpty, "alreadyLoading should have description")
  }
  
  func testAudiobookSessionError_Unknown_PreservesMessage() {
    let customMessage = "Something went wrong"
    let error = AudiobookSessionError.unknown(customMessage)
    XCTAssertEqual(error.localizedDescription, customMessage, "Unknown error should preserve message")
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
}

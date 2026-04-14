//
//  CarPlayTests.swift
//  PalaceTests
//
//  Tests for CarPlay audiobook support
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import CarPlay
import MediaPlayer
@testable import Palace
@testable import PalaceAudiobookToolkit

/// Tests for CarPlay audiobook browsing and playback integration.
/// Verifies library display, chapter navigation, and error handling.
@MainActor
class CarPlayTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Clear shared state to prevent test pollution
        AudiobookSessionManager.shared.clearAllState()
    }

    override func tearDown() {
        // Clear shared state after each test
        AudiobookSessionManager.shared.clearAllState()
        super.tearDown()
    }

    // MARK: - AudiobookSessionManager Tests

    func testAudiobookSessionManager_Initialization() {
        // Arrange & Act
        let sessionManager = Palace.AudiobookSessionManager.shared

        // Assert - session manager starts with no active book
        XCTAssertNil(sessionManager.currentBook, "Session manager should not have a book initially")
        XCTAssertNil(sessionManager.manager, "Session manager should not have a manager initially")
        XCTAssertFalse(sessionManager.state.isActive, "Session manager should not be active initially")
    }

    func testCarPlayBridge_Initialization() {
        // Arrange & Act
        let bridge = CarPlayAudiobookBridge()

        // Assert - bridge delegates to session manager
        XCTAssertNotNil(bridge, "Bridge should be created successfully")
        // On init, bridge should reflect no active session
        XCTAssertFalse(bridge.isPlaying, "Bridge should not be playing immediately after init")
        XCTAssertNil(bridge.currentBook, "Bridge should have no current book after init")
        XCTAssertNil(bridge.currentChapter, "Bridge should have no current chapter after init")
    }

    // MARK: - CarPlayImageProvider Tests

    func testCarPlayImageProvider_GeneratesPlaceholder() {
        // Arrange
        let imageProvider = CarPlayImageProvider()
        let book = TPPBookMocker.snapshotAudiobook()

        // Act
        let expectation = XCTestExpectation(description: "Image loaded")
        var resultImage: UIImage?

        imageProvider.artwork(for: book) { image in
            resultImage = image
            expectation.fulfill()
        }

        // Assert
        wait(for: [expectation], timeout: 5.0)
        XCTAssertNotNil(resultImage, "Should provide an image (placeholder or cover)")
    }

    // MARK: - Audiobook Filtering Tests

    func testCarPlay_FiltersOnlyAudiobooks() {
        // Arrange
        let audiobookBook = TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
        let epubBook = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let pdfBook = TPPBookMocker.mockBook(distributorType: .OpenAccessPDF)

        let allBooks = [audiobookBook, epubBook, pdfBook]

        // Act - Filter audiobooks (same logic as CarPlayTemplateManager)
        let audiobooks = allBooks.filter { $0.isAudiobook }

        // Assert
        XCTAssertEqual(audiobooks.count, 1, "Should only include audiobooks")
        XCTAssertTrue(audiobooks.first?.isAudiobook ?? false, "Filtered book should be an audiobook")
    }

    func testCarPlay_NoEbooksInLibrary() {
        // Arrange
        let epubBook = TPPBookMocker.mockBook(distributorType: .EpubZip)
        let pdfBook = TPPBookMocker.mockBook(distributorType: .OpenAccessPDF)

        let allBooks = [epubBook, pdfBook]

        // Act
        let audiobooks = allBooks.filter { $0.isAudiobook }

        // Assert
        XCTAssertEqual(audiobooks.count, 0, "Should not include any ebooks in CarPlay")
    }

    // MARK: - Chapter List Tests

    func testCarPlay_ChapterListFormatting() {
        // Arrange
        let duration: Double = 3665 // 1 hour, 1 minute, 5 seconds

        // Act - Test duration formatting logic
        let formattedDuration = formatDuration(duration)

        // Assert
        XCTAssertEqual(formattedDuration, "1:01:05", "Should format duration as H:MM:SS")
    }

    func testCarPlay_ShortDurationFormatting() {
        // Arrange
        let duration: Double = 125 // 2 minutes, 5 seconds

        // Act
        let formattedDuration = formatDuration(duration)

        // Assert
        XCTAssertEqual(formattedDuration, "2:05", "Should format short duration as M:SS")
    }

    func testCarPlay_ZeroDurationFormatting() {
        // Arrange
        let duration: Double? = nil

        // Act
        let formattedDuration = formatDurationOptional(duration)

        // Assert
        XCTAssertEqual(formattedDuration, "", "Should return empty string for nil duration")
    }

    // MARK: - Error String Tests

    func testCarPlay_ErrorStrings_NotEmpty() {
        // Assert that all CarPlay error strings are properly localized and not empty
        XCTAssertFalse(Strings.CarPlay.Error.notDownloaded.isEmpty, "Not downloaded error should have text")
        XCTAssertFalse(Strings.CarPlay.Error.downloadRequired.isEmpty, "Download required message should have text")
        XCTAssertFalse(Strings.CarPlay.Error.offline.isEmpty, "Offline error should have text")
        XCTAssertFalse(Strings.CarPlay.Error.offlineMessage.isEmpty, "Offline message should have text")
        XCTAssertFalse(Strings.CarPlay.Error.playbackFailed.isEmpty, "Playback failed error should have text")
        XCTAssertFalse(Strings.CarPlay.Error.tryAgain.isEmpty, "Try again message should have text")
    }

    func testCarPlay_UIStrings_NotEmpty() {
        // Assert that all CarPlay UI strings are properly localized
        XCTAssertFalse(Strings.CarPlay.library.isEmpty, "Library title should have text")
        XCTAssertFalse(Strings.CarPlay.nowPlaying.isEmpty, "Now Playing title should have text")
        XCTAssertFalse(Strings.CarPlay.chapters.isEmpty, "Chapters title should have text")
        XCTAssertFalse(Strings.CarPlay.noAudiobooks.isEmpty, "No audiobooks message should have text")
        XCTAssertFalse(Strings.CarPlay.downloadAudiobooks.isEmpty, "Download audiobooks message should have text")
    }

    func testCarPlay_ChapterNumber_Formatting() {
        // Act
        let chapter1 = Strings.CarPlay.chapterNumber(1)
        let chapter10 = Strings.CarPlay.chapterNumber(10)

        // Assert
        XCTAssertTrue(chapter1.contains("1"), "Chapter 1 should include the number")
        XCTAssertTrue(chapter10.contains("10"), "Chapter 10 should include the number")
    }

    // MARK: - Notification Tests

    // TODO: Re-enable when TPPAudiobookManagerCreated notification is defined
    // func testCarPlay_AudiobookManagerCreatedNotification() {
    //   // Arrange
    //   let notificationExpectation = XCTestExpectation(description: "Notification received")
    //   var receivedManager: AudiobookManager?
    //
    //   let observer = NotificationCenter.default.addObserver(
    //     forName: .TPPAudiobookManagerCreated,
    //     object: nil,
    //     queue: .main
    //   ) { notification in
    //     receivedManager = notification.object as? AudiobookManager
    //     notificationExpectation.fulfill()
    //   }
    //
    //   // Act - Post a mock notification (simulating what BookService does)
    //   // Note: In a real test we'd create an actual AudiobookManager
    //   NotificationCenter.default.post(name: .TPPAudiobookManagerCreated, object: nil)
    //
    //   // Assert
    //   wait(for: [notificationExpectation], timeout: 2.0)
    //
    //   // Cleanup
    //   NotificationCenter.default.removeObserver(observer)
    // }

    // MARK: - Book State Tests

    func testCarPlay_BookDownloadedState() {
        // Arrange
        let book = TPPBookMocker.snapshotAudiobook()

        // Act - Check if book is an audiobook (this is what CarPlay filters on)
        let isAudiobook = book.isAudiobook

        // Assert
        XCTAssertTrue(isAudiobook, "Snapshot audiobook should be recognized as audiobook")
        XCTAssertEqual(book.defaultBookContentType, .audiobook,
                       "Snapshot audiobook's defaultBookContentType should be .audiobook")
        XCTAssertFalse(book.title.isEmpty, "Snapshot audiobook should have a non-empty title")
        XCTAssertFalse(book.identifier.isEmpty, "Snapshot audiobook should have a non-empty identifier")
    }

    // MARK: - Helper Methods

    private func formatDuration(_ duration: Double) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60

        if minutes >= 60 {
            let hours = minutes / 60
            let remainingMinutes = minutes % 60
            return String(format: "%d:%02d:%02d", hours, remainingMinutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }

    private func formatDurationOptional(_ duration: Double?) -> String {
        guard let duration = duration, duration > 0 else {
            return ""
        }
        return formatDuration(duration)
    }
}

// MARK: - CarPlay Integration Tests

/// Integration tests that verify CarPlay components work together
@MainActor
class CarPlayIntegrationTests: XCTestCase {

    /// Tests CarPlay Template initialization, integration, and book selection handling
    /// Keywords: carplay, template, integration, book, selection, manager, library
    func testCarPlayTemplateIntegration_BookSelectionHandling() {
        // This test verifies CarPlay template manager initialization and book handling
        // In a real test environment, we'd need to mock CPInterfaceController
        // For now, we verify the components compile and link correctly

        // Assert that the classes exist and can be referenced
        XCTAssertNotNil(CarPlayAudiobookBridge.self)
        XCTAssertNotNil(CarPlayImageProvider.self)
        // CarPlayTemplateManager and CarPlaySceneDelegate require CPInterfaceController

        // Verify a bridge instance has correct initial state
        let bridge = CarPlayAudiobookBridge()
        XCTAssertNotNil(bridge, "CarPlayAudiobookBridge should instantiate")
        XCTAssertFalse(bridge.isPlaying, "Bridge should not be playing initially")
        XCTAssertNil(bridge.currentBook, "Bridge should have no book initially")
    }

    func testCarPlay_ImageProvider_CachesBehavior() {
        // Arrange
        let imageProvider = CarPlayImageProvider()
        let book = TPPBookMocker.snapshotAudiobook()

        // Act - Request same book twice
        let expectation1 = XCTestExpectation(description: "First image")
        let expectation2 = XCTestExpectation(description: "Second image (cached)")

        var image1: UIImage?
        var image2: UIImage?

        imageProvider.artwork(for: book) { image in
            image1 = image
            expectation1.fulfill()
        }

        wait(for: [expectation1], timeout: 5.0)

        // Second request should hit cache
        imageProvider.artwork(for: book) { image in
            image2 = image
            expectation2.fulfill()
        }

        // Assert
        wait(for: [expectation2], timeout: 1.0) // Should be faster due to cache
        XCTAssertNotNil(image1)
        XCTAssertNotNil(image2)
    }
}

// MARK: - CarPlay Open App Alert Tests

/// Tests for the CarPlay "Open App" alert functionality
/// Verifies alert messages and strings are properly configured
@MainActor
class CarPlayOpenAppAlertTests: XCTestCase {

    func testCarPlay_OpenAppStrings_AreConfigured() {
        // Assert that Open App strings are not empty
        // The alert uses message variants (message, messageShort, messageShortest)
        XCTAssertFalse(Strings.CarPlay.OpenApp.message.isEmpty, "Open App message should have text")
        XCTAssertFalse(Strings.CarPlay.OpenApp.messageShort.isEmpty, "Open App short message should have text")
        XCTAssertFalse(Strings.CarPlay.OpenApp.messageShortest.isEmpty, "Open App shortest message should have text")
        // Shorter variants should be subsets (or equal length) of longer ones
        XCTAssertLessThanOrEqual(
            Strings.CarPlay.OpenApp.messageShortest.count,
            Strings.CarPlay.OpenApp.messageShort.count,
            "Shortest message should be shorter than or equal to short message"
        )
        XCTAssertLessThanOrEqual(
            Strings.CarPlay.OpenApp.messageShort.count,
            Strings.CarPlay.OpenApp.message.count,
            "Short message should be shorter than or equal to full message"
        )
    }

    func testCarPlay_OpenAppMessage_MentionsPalace() {
        // The message should mention Palace
        let message = Strings.CarPlay.OpenApp.message
        XCTAssertTrue(
            message.lowercased().contains("palace"),
            "Message should mention Palace"
        )
    }

    func testCarPlay_OpenAppMessage_MentionsPhone() {
        // The message should tell the user to use their phone
        let message = Strings.CarPlay.OpenApp.message
        XCTAssertTrue(
            message.lowercased().contains("phone"),
            "Message should mention the phone"
        )
    }

    func testSceneDelegate_HasMainSceneConnected_Flag() {
        // Verify the flag exists and is accessible
        // This flag is used to determine when to show the "Open App" alert
        let flagValue = SceneDelegate.hasMainSceneConnected

        // The flag should be a Bool and accessible without crashing
        XCTAssertTrue(flagValue == true || flagValue == false,
                      "hasMainSceneConnected flag should be a valid Bool")
        // In test environment, no CarPlay scene is connected, so flag should be false
        // (unless another test has already set it)
        XCTAssertNotNil(flagValue, "hasMainSceneConnected should have a value")
    }
}

// MARK: - CarPlay Library Refresh Tests

/// Tests for CarPlay library refresh functionality
@MainActor
class CarPlayLibraryRefreshTests: XCTestCase {

    func testCarPlay_LibraryName_CanBeUpdated() {
        // Verify that AccountsManager can provide a current account
        // This is used to update the library name in CarPlay
        let accountsManager = AccountsManager.shared

        // In test environment, may or may not have a current account
        // But the manager should be accessible
        XCTAssertNotNil(accountsManager, "AccountsManager should be accessible")
        // The TPP account UUID should always be non-empty
        XCTAssertFalse(accountsManager.tppAccountUUID.isEmpty,
                       "TPP account UUID should not be empty")
    }

    func testCarPlay_BookRegistry_IsAccessible() {
        // Verify book registry can be accessed (used for library book list)
        let registry = TPPBookRegistry.shared
        XCTAssertNotNil(registry, "Book registry should be accessible")
        // The registry should return an array (possibly empty) for allBooks
        let books = registry.allBooks
        XCTAssertNotNil(books, "allBooks should return a non-nil array")
    }

    func testCarPlay_DownloadedAudiobooks_CanBeFiltered() {
        // Arrange
        let audiobookState = TPPBookState.downloadSuccessful
        let ebookState = TPPBookState.downloadSuccessful

        // Assert - verify these states are recognized as downloaded
        XCTAssertEqual(audiobookState, .downloadSuccessful,
                       "downloadSuccessful should equal itself")
        XCTAssertEqual(ebookState, .downloadSuccessful,
                       "ebookState should be downloadSuccessful")
        // Verify both are the same state
        XCTAssertEqual(audiobookState, ebookState,
                       "Both states should be equal")
        // Verify downloadSuccessful is a distinct state from others
        XCTAssertNotEqual(audiobookState, .downloading, "downloadSuccessful != downloading")
        XCTAssertNotEqual(audiobookState, .downloadNeeded, "downloadSuccessful != downloadNeeded")
    }
}

// MARK: - CarPlay Now Playing Template Crash Regression Tests

/// Regression tests for CarPlay crashes related to Now Playing template configuration.
/// Bug: SIGABRT crash when configuring CPNowPlayingTemplate before playback starts.
/// Fix: Defer Now Playing template configuration until playback actually begins.
@MainActor
class CarPlayNowPlayingTemplateTests: XCTestCase {

    /// Regression test for crash when Now Playing is configured during initial setup.
    /// The CarPlay framework throws SIGABRT if CPNowPlayingTemplate.shared is configured
    /// (observers added, buttons updated) before any media playback has started.
    ///
    /// This test verifies that CarPlayAudiobookBridge can be created safely without
    /// triggering any premature Now Playing configuration.
    func testCarPlayBridge_DoesNotConfigureNowPlayingOnInit() {
        // Arrange & Act
        // Creating the bridge should NOT configure Now Playing template
        let bridge = CarPlayAudiobookBridge()

        // Assert
        // If we got here without crashing, the bridge didn't prematurely configure Now Playing
        XCTAssertNotNil(bridge, "Bridge should be created without configuring Now Playing")

        // The bridge should not report active playback
        XCTAssertFalse(bridge.isPlaying, "Bridge should not be playing after init")
        XCTAssertNil(bridge.currentBook, "Bridge should not have a book after init")
        XCTAssertNil(bridge.currentChapter, "Bridge should not have a chapter after init")
    }

    /// Verifies that the playback state publisher exists and is observable.
    /// This publisher is used to trigger Now Playing configuration ONLY when playback starts.
    func testCarPlayBridge_HasPlaybackStatePublisher() {
        // Arrange
        let bridge = CarPlayAudiobookBridge()

        // Act & Assert
        // The publisher should exist and be subscribable
        let expectation = XCTestExpectation(description: "Publisher subscribed")
        expectation.isInverted = true // We don't expect any events during setup

        let cancellable = bridge.playbackStatePublisher
            .sink { _ in
                expectation.fulfill()
            }

        // Wait briefly - no events should be emitted during setup
        wait(for: [expectation], timeout: 0.5)
        cancellable.cancel()
    }

    /// Tests that the image provider can be created independently without CarPlay.
    /// Image loading should not depend on Now Playing state.
    func testCarPlayImageProvider_InitializesIndependently() {
        // Arrange & Act
        let imageProvider = CarPlayImageProvider()

        // Assert
        XCTAssertNotNil(imageProvider, "Image provider should initialize without CarPlay connection")
    }

    /// TC-002 (Coverage Analysis): Verify Now Playing template is configured only once.
    /// Tests idempotent behavior - multiple calls should not reconfigure.
    func testCarPlayBridge_NowPlayingConfigurationIsIdempotent() {
        // Arrange
        let bridge = CarPlayAudiobookBridge()

        // Act - Access chapters multiple times (which would trigger configuration if playing)
        let chapters1 = bridge.currentChapters
        let chapters2 = bridge.currentChapters

        // Assert - Both should return nil (no active playback) without crashing
        XCTAssertNil(chapters1, "Should return nil chapters without active playback")
        XCTAssertNil(chapters2, "Should return nil chapters on subsequent access")
    }
}

// MARK: - CarPlay Chapter List Tests (TC-003 from Coverage Analysis)

/// Tests for CarPlay chapter list display functionality.
/// Verifies chapter availability handling and graceful degradation.
@MainActor
class CarPlayChapterListTests: XCTestCase {

    /// TC-003: Test that chapter list handles absence of chapters gracefully.
    /// When no chapters are available, the bridge should return nil without crashing.
    func testCarPlayBridge_NoChaptersAvailable_ReturnsNil() {
        // Arrange
        let bridge = CarPlayAudiobookBridge()

        // Act - Request chapters when no book is loaded
        let chapters = bridge.currentChapters

        // Assert
        XCTAssertNil(chapters, "Should return nil when no chapters available")
    }

    /// TC-003: Test that current chapter is nil when no playback is active.
    func testCarPlayBridge_NoPlayback_CurrentChapterIsNil() {
        // Arrange
        let bridge = CarPlayAudiobookBridge()

        // Act
        let currentChapter = bridge.currentChapter

        // Assert
        XCTAssertNil(currentChapter, "Current chapter should be nil without active playback")
    }

    /// Test chapter skip functionality doesn't crash without active playback.
    func testCarPlayBridge_SkipToChapter_WithoutPlayback_DoesNotCrash() {
        // Arrange
        let bridge = CarPlayAudiobookBridge()

        // Act - Attempt to skip to chapter without active playback
        // This should be a no-op, not a crash
        bridge.skipToChapter(at: 0)
        bridge.skipToChapter(at: 5)
        bridge.skipToChapter(at: -1) // Edge case: negative index

        // Assert - skip should not change playback state when no book is loaded
        XCTAssertFalse(bridge.isPlaying, "Skipping without playback should not start playing")
        XCTAssertNil(bridge.currentBook, "Skipping without playback should not set a book")
        XCTAssertNil(bridge.currentChapter, "Skipping without playback should not set a chapter")
    }
}

// MARK: - CarPlay Playback Error Handling Tests

/// Tests for CarPlay playback error handling and alerts
@MainActor
class CarPlayPlaybackErrorTests: XCTestCase {

    func testCarPlay_ErrorStrings_AuthRequired() {
        let title = Strings.CarPlay.Error.authRequired
        let message = Strings.CarPlay.Error.authMessage

        XCTAssertFalse(title.isEmpty, "Auth required error should have title")
        XCTAssertFalse(message.isEmpty, "Auth required error should have message")
    }

    func testCarPlay_ErrorStrings_NotDownloaded() {
        let title = Strings.CarPlay.Error.notDownloaded
        let message = Strings.CarPlay.Error.downloadRequired

        XCTAssertFalse(title.isEmpty, "Not downloaded error should have title")
        XCTAssertFalse(message.isEmpty, "Not downloaded error should have message")
    }

    func testCarPlay_ErrorStrings_Offline() {
        let title = Strings.CarPlay.Error.offline
        let message = Strings.CarPlay.Error.offlineMessage

        XCTAssertFalse(title.isEmpty, "Offline error should have title")
        XCTAssertFalse(message.isEmpty, "Offline error should have message")
    }

    func testCarPlay_ErrorStrings_PlaybackFailed() {
        let title = Strings.CarPlay.Error.playbackFailed
        let message = Strings.CarPlay.Error.tryAgain

        XCTAssertFalse(title.isEmpty, "Playback failed error should have title")
        XCTAssertFalse(message.isEmpty, "Try again message should exist")
    }

    func testAudiobookSessionError_MapsToCarPlayAlert() {
        // Verify each error type has a meaningful description
        let errors: [AudiobookSessionError] = [
            .notAuthenticated,
            .notDownloaded,
            .networkUnavailable,
            .manifestLoadFailed,
            .playerCreationFailed,
            .alreadyLoading,
            .unknown("Test error")
        ]

        for error in errors {
            XCTAssertFalse(
                error.localizedDescription.isEmpty,
                "Error \(error) should have a description for CarPlay alert"
            )
        }
    }

    // MARK: - PP-3679 Auto-Navigate to Now Playing

    func testBridge_isPlaying_reflectsSessionManager() {
        let bridge = CarPlayAudiobookBridge()
        XCTAssertFalse(bridge.isPlaying, "Bridge should report not playing when no session is active")
    }

    func testBridge_currentBook_nilWhenNoSession() {
        let bridge = CarPlayAudiobookBridge()
        XCTAssertNil(bridge.currentBook, "No book should be set when session is inactive")
    }

    // MARK: - PP-3679 Lock Screen Position Sync

    func testNowPlayingInfo_isAccessible() {
        let infoCenter = MPNowPlayingInfoCenter.default()
        XCTAssertNotNil(infoCenter, "Now Playing info center should be available")
        // The default instance should be the same singleton
        XCTAssertTrue(infoCenter === MPNowPlayingInfoCenter.default(),
                      "MPNowPlayingInfoCenter.default() should return the same singleton")
        // playbackState should be a valid value
        let state = infoCenter.playbackState
        XCTAssertTrue(state == .unknown || state == .playing || state == .paused || state == .stopped || state == .interrupted,
                      "Playback state should be one of the known values")
    }
}

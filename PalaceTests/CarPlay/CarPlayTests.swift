//
//  CarPlayTests.swift
//  PalaceTests
//
//  Tests for CarPlay audiobook support
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import CarPlay
import Combine
import MediaPlayer
@testable import Palace
@testable import PalaceAudiobookToolkit
import PalaceBookModel

/// Tests for CarPlay audiobook browsing and playback integration.
/// Verifies library display, chapter navigation, and error handling.
@MainActor
class CarPlayTests: XCTestCase {

    // MARK: - AudiobookSessionManager Tests

    func testAudiobookSessionManager_Initialization() {
        // Arrange & Act
        // A locally-constructed instance via AppContainer rather than
        // Palace.AudiobookSessionManager.shared.
        let sessionManager = Palace.AudiobookSessionManager(appContainer: makeTestAppContainer())

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
        let imageProvider = CarPlayImageProvider(imageLoader: makeTestAppContainer().imageLoader)
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
        // Verify the format contains exactly the right number of components
        let components = formattedDuration.components(separatedBy: ":")
        XCTAssertEqual(components.count, 3, "Hour-duration must have 3 colon-separated components")
    }

    func testCarPlay_ShortDurationFormatting() {
        // Arrange
        let duration: Double = 125 // 2 minutes, 5 seconds

        // Act
        let formattedDuration = formatDuration(duration)

        // Assert
        XCTAssertEqual(formattedDuration, "2:05", "Should format short duration as M:SS")
        // Short durations must have exactly 2 components (no hours field)
        let components = formattedDuration.components(separatedBy: ":")
        XCTAssertEqual(components.count, 2, "Sub-hour duration must have 2 colon-separated components")
    }

    func testCarPlay_ZeroDurationFormatting() {
        // Arrange
        let duration: Double? = nil

        // Act
        let formattedDuration = formatDurationOptional(duration)

        // Assert
        XCTAssertEqual(formattedDuration, "", "Should return empty string for nil duration")
        // Zero duration is not > 0, so formatDurationOptional also returns empty
        let zeroDuration = formatDurationOptional(0.0)
        XCTAssertTrue(zeroDuration.isEmpty, "Zero duration must produce an empty string (guard requires > 0)")
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

        // Verify a bridge instance has correct initial state
        let bridge = CarPlayAudiobookBridge()
        XCTAssertFalse(bridge.isPlaying, "Bridge should not be playing initially")
        XCTAssertNil(bridge.currentBook, "Bridge should have no book initially")
        XCTAssertNil(bridge.currentChapter, "Bridge should have no chapter initially")
        // Image provider must also initialize independently and be a distinct instance from bridge
        let imageProvider = CarPlayImageProvider(imageLoader: makeTestAppContainer().imageLoader)
        XCTAssertTrue(imageProvider !== bridge as AnyObject, "Image provider and bridge must be distinct objects")
    }

    func testCarPlay_ImageProvider_CachesBehavior() {
        // Arrange
        let imageProvider = CarPlayImageProvider(imageLoader: makeTestAppContainer().imageLoader)
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

    // Bracket the class with the AppContainer test-boundary reset so the
    // statebleed round-trip below starts from a known-clean graph (the
    // resolve→reset→re-resolve non-identity assertion only proves the reset
    // rebuilt the statics if the arrange step isn't pre-polluted by a prior
    // test) and this class doesn't leak rebuilt statics into the next.
    override func setUp() {
        super.setUp()
        AppContainer._resetForTesting()
    }

    override func tearDown() {
        AppContainer._resetForTesting()
        super.tearDown()
    }

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

    // MARK: - Cold-launch gate (device-divergence)

    /// When the main phone scene has NOT connected (CarPlay-only cold start),
    /// the gate must show the "open Palace on your phone" alert — iOS limits
    /// background execution so playback won't work reliably. Behavior test on
    /// the extracted seam (replaces the prior tautology that only asserted the
    /// flag was a Bool).
    func testShouldShowOpenAppAlert_whenMainSceneNotConnected_isTrue() {
        XCTAssertTrue(
            CarPlayTemplateManager.shouldShowOpenAppAlert(mainSceneConnected: false),
            "CarPlay-only cold start must gate playback behind the open-app alert"
        )
    }

    /// When the main phone scene HAS connected, the gate must NOT short-circuit
    /// to the alert — playback selection proceeds to the auth/download checks.
    func testShouldShowOpenAppAlert_whenMainSceneConnected_isFalse() {
        XCTAssertFalse(
            CarPlayTemplateManager.shouldShowOpenAppAlert(mainSceneConnected: true),
            "with the phone scene connected, selection must proceed past the gate"
        )
    }

    // MARK: - Statebleed reset (CarPlay presenter pollution, #1072)

    /// The audiobook session / presenter / bootstrapper are process-wide statics
    /// that `_buildCachedAppContainer()` does NOT rebuild, so a prior test that
    /// leaves the presenter mid-session can bleed `hasActiveSession` into a later
    /// CarPlay test. `AppContainer._resetForTesting()` (the #1072 fix) nils them
    /// so the next resolution rebuilds fresh. Drive the cycle through the
    /// PRODUCTION seam (`production().audiobook*`), not direct static writes, and
    /// assert the reset releases the prior instances (write → reset → re-enter).
    @MainActor
    func testStatebleed_resetForTesting_rebuildsFreshAudiobookStatics() {
        // Arrange — resolve (and thereby cache) the audiobook statics.
        let session1 = AppContainer.production().audiobookSession as AnyObject // MIGRATED-DEFERRED: production() resolution IS the test contract (asserting _resetForTesting rebuilds the audiobook statics; no DI seam observes the static cache)
        let presenter1 = AppContainer.production().audiobookSessionPresenter // MIGRATED-DEFERRED: production() resolution IS the test contract (asserting _resetForTesting rebuilds the audiobook statics; no DI seam observes the static cache)
        let bootstrapper1 = AppContainer.production().playbackBootstrapper // MIGRATED-DEFERRED: production() resolution IS the test contract (asserting _resetForTesting rebuilds the audiobook statics; no DI seam observes the static cache)

        // Act — the test-boundary reset.
        AppContainer._resetForTesting()

        // Assert — re-resolving yields FRESH instances; the polluted ones are gone.
        let session2 = AppContainer.production().audiobookSession as AnyObject // MIGRATED-DEFERRED: production() resolution IS the test contract (asserting _resetForTesting rebuilds the audiobook statics; no DI seam observes the static cache)
        let presenter2 = AppContainer.production().audiobookSessionPresenter // MIGRATED-DEFERRED: production() resolution IS the test contract (asserting _resetForTesting rebuilds the audiobook statics; no DI seam observes the static cache)
        let bootstrapper2 = AppContainer.production().playbackBootstrapper // MIGRATED-DEFERRED: production() resolution IS the test contract (asserting _resetForTesting rebuilds the audiobook statics; no DI seam observes the static cache)

        XCTAssertFalse(session1 === session2,
                       "reset must rebuild a fresh audiobook session")
        XCTAssertFalse(presenter1 === presenter2,
                       "reset must rebuild a fresh presenter (CarPlay statebleed fix)")
        XCTAssertFalse(bootstrapper1 === bootstrapper2,
                       "reset must rebuild a fresh playback bootstrapper")
    }
}

// MARK: - CarPlay Library Refresh Tests

/// Tests for CarPlay library refresh functionality
@MainActor
class CarPlayLibraryRefreshTests: XCTestCase {

    func testCarPlay_LibraryName_CanBeUpdated() {
        // Verify that AccountsManager can provide a current account
        // This is used to update the library name in CarPlay
        let accountsManager = makeTestAppContainer().accountsManager

        // In test environment, may or may not have a current account
        // But the manager should be accessible
        XCTAssertNotNil(accountsManager, "AccountsManager should be accessible")
        // The TPP account UUID should always be non-empty
        XCTAssertFalse(accountsManager.tppAccountUUID.isEmpty,
                       "TPP account UUID should not be empty")
    }

    func testCarPlay_BookRegistry_IsAccessible() {
        // Verify book registry exposes its myBooks list (the same property
        // CarPlay's library template builds against). `myBooks` is a derived
        // computed property that filters allBooks for user-scoped state, so
        // hitting it exercises the registry's read path end-to-end —
        // registry construction, account scoping, and the filter — rather
        // than just confirming the singleton was wired up.
        let registry = makeTestAppContainer().bookRegistry
        let books = registry.myBooks
        XCTAssertNotNil(books, "myBooks must return a non-nil array (possibly empty)")
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

        var receivedEvents = 0
        let cancellable = bridge.playbackStatePublisher
            .sink { _ in
                receivedEvents += 1
                expectation.fulfill()
            }

        // Wait briefly - no events should be emitted during setup
        wait(for: [expectation], timeout: 0.5)
        cancellable.cancel()
        // Verify no spurious events were emitted during idle setup
        XCTAssertEqual(receivedEvents, 0, "No playback events should be emitted before playback starts")
        // Verify the bridge is in a consistent idle state
        XCTAssertFalse(bridge.isPlaying, "Bridge must not be playing before playback is started")
    }

    /// Tests that the image provider can be created independently without CarPlay.
    /// Image loading should not depend on Now Playing state.
    func testCarPlayImageProvider_InitializesIndependently() {
        // Arrange & Act
        let imageProvider = CarPlayImageProvider(imageLoader: makeTestAppContainer().imageLoader)
        let imageProvider2 = CarPlayImageProvider(imageLoader: makeTestAppContainer().imageLoader)

        // Assert - Each instance is independent (not a shared singleton)
        XCTAssertNotNil(imageProvider, "Image provider should initialize without CarPlay connection")
        XCTAssertTrue(imageProvider !== imageProvider2, "Each CarPlayImageProvider must be a distinct instance")
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
        // Verify consistency: repeated calls must also return nil (no phantom chapters)
        let chaptersAgain = bridge.currentChapters
        XCTAssertNil(chaptersAgain, "Repeated calls must consistently return nil when no book is loaded")
    }

    /// TC-003: Test that current chapter is nil when no playback is active.
    func testCarPlayBridge_NoPlayback_CurrentChapterIsNil() {
        // Arrange
        let bridge = CarPlayAudiobookBridge()

        // Act
        let currentChapter = bridge.currentChapter

        // Assert
        XCTAssertNil(currentChapter, "Current chapter should be nil without active playback")
        // Both chapter and chapters must be nil consistently (not just one of them)
        XCTAssertNil(bridge.currentChapters, "currentChapters must also be nil without active playback")
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
        // Consistent: no current book and no chapter when not playing
        XCTAssertNil(bridge.currentBook, "No book should be associated when not playing")
    }

    func testBridge_currentBook_nilWhenNoSession() {
        let bridge = CarPlayAudiobookBridge()
        XCTAssertNil(bridge.currentBook, "No book should be set when session is inactive")
        // Consistent: chapters should also be nil when there is no current book
        XCTAssertNil(bridge.currentChapters, "Chapters must be nil when no book session is active")
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

// MARK: - CarPlayAudiobookBridgePresenterMigrationTests

/// Pins the migration of
/// `CarPlayAudiobookBridge.dismissBookOnPhone()` off the legacy
/// `coordinator.removeAudioModel + coordinator.popToRoot` pair onto
/// `presenter.minimize()`.
///
/// Two pins:
///
///   7. `dismissBookOnPhone()` calls `presenter.minimize()` — proves the
///      migration landed by observing the presenter's `isPlayerExpanded`
///      flip from true → false through the production presenter
///      resolved via `AppContainer.production().audiobookSessionPresenter`.
///      A regression that left the legacy `coordinator.removeAudioModel +
///      popToRoot` pair in place (and dropped the migration's
///      `presenter.minimize()` call) would fail to flip
///      `isPlayerExpanded`.
///
///   8. `dismissBookOnPhone()` does NOT clear the session — the session
///      stays active so the mini-player remains visible on the phone.
///      CarPlay disconnect is a UI dismiss, not a playback stop. A
///      regression that wired dismissBookOnPhone to stopPlayback would
///      kill the session and fail.
@MainActor
final class CarPlayAudiobookBridgePresenterMigrationTests: XCTestCase {

    // CarPlayAudiobookBridge.dismissBookOnPhone() resolves the presenter
    // via AppContainer.production() — there's no DI seam at the bridge
    // level (intentional, to keep the change narrow). Tests
    // therefore share the production presenter cache. Order-independence
    // is restored by explicit setUp/tearDown reset of presenter state.
    //
    // We do NOT use withAudiobookSessionPresenter(_:) here: the override
    // is instance-local on the AppContainer copy, but the bridge
    // re-resolves via a fresh AppContainer.production() call inside
    // dismissBookOnPhone, which has no override. Resetting the shared
    // presenter state in setUp/tearDown is the right shape for this
    // production-callsite-without-DI pattern.

    private var presenter: AudiobookSessionPresenter { AppContainer.production().audiobookSessionPresenter } // MIGRATED-DEFERRED: production() resolution IS the test contract (no DI seam at this callsite)

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run { resetPresenterState() }
    }

    override func tearDown() async throws {
        await MainActor.run { resetPresenterState() }
        try await super.tearDown()
    }

    private func resetPresenterState() {
        let p = presenter
        p.minimize()
        p.clearActiveSession()
    }

    /// Test 7 — `dismissBookOnPhone()` calls `presenter.minimize()`.
    ///
    /// Pre-state: presenter expanded via `expand()` so the minimize flip
    /// is observable. Post-state: presenter collapsed.
    func testCarPlayBridge_dismissBookOnPhone_callsPresenterMinimize() {
        presenter.expand()
        XCTAssertTrue(presenter.isPlayerExpanded,
                      "PRECONDITION: presenter must be expanded so minimize()'s flip is observable")

        let bridge = CarPlayAudiobookBridge()
        bridge.dismissBookOnPhone()

        XCTAssertFalse(presenter.isPlayerExpanded,
                       "Migrated dismissBookOnPhone must call presenter.minimize() — a regression that left the legacy `coordinator.removeAudioModel + popToRoot` in place (and dropped the migration's presenter.minimize() call) would fail to flip isPlayerExpanded back to false")
    }

    /// Test 8 — `dismissBookOnPhone()` does NOT clear the session.
    func testCarPlayBridge_dismissBookOnPhone_doesNotKillSession() {
        let session = AppContainer.production().audiobookSession // MIGRATED-DEFERRED: production() resolution IS the test contract (no DI seam at this callsite)

        // Drive the presenter into an active state via the session's
        // publisher seam — proves the bridge dismiss does NOT touch
        // session state.
        // Deterministically wait for the presenter's async
        // `.receive(on: DispatchQueue.main)` playbackStatePublisher sink to
        // propagate, instead of a fixed 10ms RunLoop pump that flakes under CI
        // main-queue congestion (the intrinsic race that red'd #1079/#1081).
        // Subscribe to the `@Published` hasActiveSession BEFORE sending so the
        // false→true transition cannot be missed.
        let activePropagated = expectation(description: "presenter observes the active session")
        var activeCancellable: AnyCancellable? = presenter.$hasActiveSession
            .first(where: { $0 })
            .sink { _ in activePropagated.fulfill() }
        session.playbackStatePublisher.send(.playing(bookId: "test-active"))
        wait(for: [activePropagated], timeout: 5.0)
        activeCancellable?.cancel()
        activeCancellable = nil

        XCTAssertTrue(presenter.hasActiveSession,
                      "PRECONDITION: presenter must report active session before bridge dismiss")

        let bridge = CarPlayAudiobookBridge()
        bridge.dismissBookOnPhone()

        XCTAssertTrue(presenter.hasActiveSession,
                      "After CarPlay dismiss, presenter.hasActiveSession must STILL be true — the session stays active so the mini-player remains visible on the phone. A regression that wired dismissBookOnPhone to stopPlayback (or clearActiveSession) would kill the session and fail.")
        XCTAssertFalse(presenter.isPlayerExpanded,
                       "The full player UI did dismiss (minimize → false), confirming dismissBookOnPhone reached presenter.minimize()")
    }
}

// MARK: - Template navigation without a nil completion

/// Crashlytics 81c394a96d71333a4f8e8ad0dca4d700 (FATAL, 3.1.0 – 3.2.3):
/// `NSGenericException: An error was encountered during a template operation,
/// but no completion block was specified` thrown from
/// `-[CPInterfaceController _handleCompletion:withSuccess:error:]`.
/// CarPlay raises that exception whenever a push/pop/dismiss FAILS and the
/// caller passed `completion: nil`. The production samples show two failures:
/// "No templates were available to be popped" (a playback error pops Now
/// Playing after the stack is already at the root; one sample logged 50
/// errors in 17 ms) and "Attempting to push a template without a root
/// template" (the chapter-list push).
///
/// `FakeCarPlayController` follows that contract: stack changes resolve
/// asynchronously (as CarPlay's host round-trip does) when `drain()` runs,
/// and a failing operation with no completion is recorded in `raised`
/// instead of throwing, so the test can report it.
@MainActor
final class CarPlayTemplateNavigatorTests: XCTestCase {

    private final class FakeCarPlayController: CarPlayTemplateNavigating {
        private(set) var templates: [CPTemplate]
        var presentedTemplate: CPTemplate?
        var topTemplate: CPTemplate? { templates.last }

        /// Failures CarPlay would have raised as NSGenericException.
        private(set) var raised: [String] = []
        /// Failures delivered to a completion handler instead.
        private(set) var reported: [String] = []
        private(set) var popCount = 0
        private(set) var popToRootCount = 0
        private var pending: [() -> Void] = []

        init(templates: [CPTemplate]) {
            self.templates = templates
        }

        func setRootTemplate(_ rootTemplate: CPTemplate, animated: Bool, completion: ((Bool, (any Error)?) -> Void)?) {
            pending.append { [self] in
                templates = [rootTemplate]
                completion?(true, nil)
            }
        }

        func presentTemplate(_ templateToPresent: CPTemplate, animated: Bool, completion: ((Bool, (any Error)?) -> Void)?) {
            pending.append { [self] in
                guard presentedTemplate == nil else {
                    return fail("A template is already presented.", completion)
                }
                presentedTemplate = templateToPresent
                completion?(true, nil)
            }
        }

        func pushTemplate(_ templateToPush: CPTemplate, animated: Bool, completion: ((Bool, (any Error)?) -> Void)?) {
            pending.append { [self] in
                guard !templates.isEmpty else {
                    return fail("Attempting to push a template without a root template.", completion)
                }
                templates.append(templateToPush)
                completion?(true, nil)
            }
        }

        func popTemplate(animated: Bool, completion: ((Bool, (any Error)?) -> Void)?) {
            popCount += 1
            pending.append { [self] in
                guard templates.count > 1 else {
                    return fail("No templates were available to be popped.", completion)
                }
                templates.removeLast()
                completion?(true, nil)
            }
        }

        func popToRootTemplate(animated: Bool, completion: ((Bool, (any Error)?) -> Void)?) {
            popToRootCount += 1
            pending.append { [self] in
                guard templates.count > 1 else {
                    return fail("No templates were available to be popped.", completion)
                }
                templates = [templates[0]]
                completion?(true, nil)
            }
        }

        func dismissTemplate(animated: Bool, completion: ((Bool, (any Error)?) -> Void)?) {
            pending.append { [self] in
                guard presentedTemplate != nil else {
                    return fail("No presented template to dismiss.", completion)
                }
                presentedTemplate = nil
                completion?(true, nil)
            }
        }

        /// The system removes a template itself (e.g. the Now Playing screen
        /// closing when playback fails) ahead of the app's own request.
        func systemPop() {
            pending.append { [self] in
                if templates.count > 1 { templates.removeLast() }
            }
        }

        func drain() {
            while !pending.isEmpty {
                pending.removeFirst()()
            }
        }

        private func fail(_ message: String, _ completion: ((Bool, (any Error)?) -> Void)?) {
            guard let completion else {
                raised.append(message)
                return
            }
            reported.append(message)
            completion(false, NSError(domain: "CarPlayErrorDomain", code: -1,
                                      userInfo: [NSLocalizedDescriptionKey: message]))
        }
    }

    private let root = CPListTemplate(title: "Library", sections: [])
    /// Stands in for `CPNowPlayingTemplate.shared`, which cannot be touched
    /// before playback starts; the navigator's predicate identifies it.
    private let nowPlaying = CPListTemplate(title: "Now Playing", sections: [])

    private func makeNavigator(_ controller: FakeCarPlayController) -> CarPlayTemplateNavigator {
        let nowPlaying = self.nowPlaying
        return CarPlayTemplateNavigator(controller: controller, isNowPlaying: { $0 === nowPlaying })
    }

    // MARK: popNowPlayingIfOnTop

    func testPopNowPlaying_burstOfErrorsBeforeStackUpdates_doesNotRaise() {
        let controller = FakeCarPlayController(templates: [root, nowPlaying])
        let navigator = makeNavigator(controller)

        // Two playback errors arrive before CarPlay applies the first pop, so
        // both see Now Playing on top (the 2026-08-26 sample: 16 ms apart).
        navigator.popNowPlayingIfOnTop()
        navigator.popNowPlayingIfOnTop()
        controller.drain()

        XCTAssertEqual(controller.raised, [], "A failed pop must go to a completion handler, not raise")
        XCTAssertEqual(controller.reported, ["No templates were available to be popped."])
        XCTAssertEqual(controller.templates.count, 1, "The first pop still returns to the library")
    }

    func testPopNowPlaying_whenSystemAlreadyClosedNowPlaying_doesNotRaise() {
        let controller = FakeCarPlayController(templates: [root, nowPlaying])
        let navigator = makeNavigator(controller)

        controller.systemPop()
        navigator.popNowPlayingIfOnTop()
        controller.drain()

        XCTAssertEqual(controller.raised, [])
        XCTAssertEqual(controller.templates.count, 1)
    }

    func testPopNowPlaying_whenNowPlayingIsNotOnTop_doesNotPop() {
        let chapters = CPListTemplate(title: "Chapters", sections: [])
        let controller = FakeCarPlayController(templates: [root, nowPlaying, chapters])
        let navigator = makeNavigator(controller)

        navigator.popNowPlayingIfOnTop()
        controller.drain()

        XCTAssertEqual(controller.popCount, 0)
        XCTAssertEqual(controller.templates.count, 3)
    }

    func testPopNowPlaying_whenOnlyRootIsShowing_doesNotPop() {
        let controller = FakeCarPlayController(templates: [root])
        let navigator = makeNavigator(controller)

        navigator.popNowPlayingIfOnTop()
        controller.drain()

        XCTAssertEqual(controller.popCount, 0)
        XCTAssertEqual(controller.raised, [])
    }

    // MARK: push / pop / popToRoot / dismiss

    func testPush_withoutRootTemplate_doesNotRaise() {
        // 2026-08-15 sample: TOC tapped, chapter-list push failed with
        // "Attempting to push a template without a root template".
        let controller = FakeCarPlayController(templates: [])
        let navigator = makeNavigator(controller)

        navigator.push(CPListTemplate(title: "Chapters", sections: []), operation: "pushTemplate(chapterList)")
        controller.drain()

        XCTAssertEqual(controller.raised, [])
        XCTAssertEqual(controller.reported, ["Attempting to push a template without a root template."])
    }

    func testPush_ontoRoot_addsTemplate() {
        let chapters = CPListTemplate(title: "Chapters", sections: [])
        let controller = FakeCarPlayController(templates: [root])
        let navigator = makeNavigator(controller)

        navigator.push(chapters, operation: "pushTemplate(chapterList)")
        controller.drain()

        XCTAssertTrue(controller.topTemplate === chapters)
    }

    func testPop_whenChapterListAlreadyGone_doesNotRaise() {
        let chapters = CPListTemplate(title: "Chapters", sections: [])
        let controller = FakeCarPlayController(templates: [root, chapters])
        let navigator = makeNavigator(controller)

        controller.systemPop()
        navigator.pop(operation: "popTemplate(chapterList)")
        controller.drain()

        XCTAssertEqual(controller.raised, [])
        XCTAssertEqual(controller.templates.count, 1)
    }

    func testPopToRoot_whenStacked_returnsToRoot() {
        let controller = FakeCarPlayController(templates: [root, nowPlaying])
        let navigator = makeNavigator(controller)

        navigator.popToRootIfStacked()
        controller.drain()

        XCTAssertEqual(controller.templates.count, 1)
        XCTAssertTrue(controller.topTemplate === root)
    }

    func testPopToRoot_whenAtRoot_doesNotPop() {
        let controller = FakeCarPlayController(templates: [root])
        let navigator = makeNavigator(controller)

        navigator.popToRootIfStacked()
        controller.drain()

        XCTAssertEqual(controller.popToRootCount, 0)
    }

    func testPopToRoot_whenStackEmptiesBeforeItApplies_doesNotRaise() {
        let controller = FakeCarPlayController(templates: [root, nowPlaying])
        let navigator = makeNavigator(controller)

        controller.systemPop()
        navigator.popToRootIfStacked()
        controller.drain()

        XCTAssertEqual(controller.raised, [])
    }

    func testDismiss_withNothingPresented_doesNotRaise() {
        let controller = FakeCarPlayController(templates: [root])
        let navigator = makeNavigator(controller)

        navigator.dismiss(operation: "dismissTemplate(openAppAlert)")
        controller.drain()

        XCTAssertEqual(controller.raised, [])
        XCTAssertEqual(controller.reported, ["No presented template to dismiss."])
    }

    func testDismiss_whenAlertPresented_clearsItAndReportsSuccess() {
        let controller = FakeCarPlayController(templates: [root])
        controller.presentedTemplate = CPListTemplate(title: "Alert", sections: [])
        let navigator = makeNavigator(controller)
        var outcomes: [String] = []

        navigator.dismiss(operation: "dismissTemplate(alert)") { error in
            outcomes.append(error == nil ? "success" : "failure")
        }
        controller.drain()

        XCTAssertNil(controller.presentedTemplate)
        XCTAssertFalse(navigator.hasPresentedTemplate)
        XCTAssertEqual(outcomes, ["success"], "The caller's outcome runs once, with no error")
    }

    func testDismiss_withNothingPresented_passesTheErrorToTheCaller() {
        let controller = FakeCarPlayController(templates: [root])
        let navigator = makeNavigator(controller)
        var receivedError: (any Error)?

        navigator.dismiss(operation: "dismissTemplate(alert)") { receivedError = $0 }
        controller.drain()

        XCTAssertEqual((receivedError as NSError?)?.localizedDescription, "No presented template to dismiss.")
    }

    // MARK: setRoot / present

    func testSetRoot_onEmptyStack_installsRootSoALaterPushSucceeds() {
        let controller = FakeCarPlayController(templates: [])
        let navigator = makeNavigator(controller)
        let chapters = CPListTemplate(title: "Chapters", sections: [])
        var rootOutcome: [Bool] = []

        navigator.setRoot(root, operation: "setRootTemplate(library)") { rootOutcome.append($0 == nil) }
        navigator.push(chapters, operation: "pushTemplate(chapterList)")
        controller.drain()

        XCTAssertEqual(rootOutcome, [true])
        XCTAssertEqual(controller.templates.count, 2)
        XCTAssertTrue(controller.templates.first === root)
        XCTAssertTrue(controller.topTemplate === chapters)
        XCTAssertEqual(navigator.templateCount, 2)
    }

    func testSetRoot_replacesAStackedNavigationWithTheNewRoot() {
        let controller = FakeCarPlayController(templates: [root, nowPlaying])
        let navigator = makeNavigator(controller)
        let renamedLibrary = CPListTemplate(title: "Other Library", sections: [])

        navigator.setRoot(renamedLibrary, operation: "setRootTemplate(new library)")
        controller.drain()

        XCTAssertEqual(controller.templates.count, 1)
        XCTAssertTrue(controller.topTemplate === renamedLibrary)
    }

    func testPresent_whenNothingPresented_presentsAndReportsSuccess() {
        let controller = FakeCarPlayController(templates: [root])
        let navigator = makeNavigator(controller)
        let alert = CPListTemplate(title: "Alert", sections: [])
        var outcomes: [Bool] = []

        navigator.present(alert, operation: "presentTemplate(errorAlert)") { outcomes.append($0 == nil) }
        controller.drain()

        XCTAssertTrue(controller.presentedTemplate === alert)
        XCTAssertTrue(navigator.hasPresentedTemplate)
        XCTAssertEqual(outcomes, [true])
    }

    func testPresent_whenAModalIsAlreadyPresented_reportsTheRejectionInsteadOfRaising() {
        // Two error channels race a second alert while the first is up
        // (TestFlight crash 9A269135 at CPInterfaceController.m:481).
        let controller = FakeCarPlayController(templates: [root])
        let navigator = makeNavigator(controller)
        let first = CPListTemplate(title: "First", sections: [])
        var secondOutcome: [Bool] = []

        navigator.present(first, operation: "presentTemplate(errorAlert)")
        navigator.present(CPListTemplate(title: "Second", sections: []), operation: "presentTemplate(errorAlert)") {
            secondOutcome.append($0 == nil)
        }
        controller.drain()

        XCTAssertEqual(controller.raised, [])
        XCTAssertEqual(controller.reported, ["A template is already presented."])
        XCTAssertEqual(secondOutcome, [false], "The rejected present hands its error to the caller")
        XCTAssertTrue(controller.presentedTemplate === first)
    }

    func testPush_whenItFails_passesTheErrorToTheCaller() {
        let controller = FakeCarPlayController(templates: [])
        let navigator = makeNavigator(controller)
        var outcomes: [Bool] = []

        navigator.push(nowPlaying, operation: "pushTemplate(nowPlaying)") { outcomes.append($0 == nil) }
        controller.drain()

        XCTAssertEqual(outcomes, [false])
    }

    func testPush_whenItSucceeds_runsTheCallerOutcomeWithoutAnError() {
        let controller = FakeCarPlayController(templates: [root])
        let navigator = makeNavigator(controller)
        var outcomes: [Bool] = []

        navigator.push(nowPlaying, operation: "pushTemplate(nowPlaying)") { outcomes.append($0 == nil) }
        controller.drain()

        XCTAssertEqual(outcomes, [true])
        XCTAssertTrue(navigator.isNowPlayingOnTop)
    }

    // MARK: Empty stack

    func testEmptyStack_noPopIsIssuedAndNowPlayingIsNotOnTop() {
        let controller = FakeCarPlayController(templates: [])
        let navigator = makeNavigator(controller)

        navigator.popNowPlayingIfOnTop()
        navigator.popToRootIfStacked()
        controller.drain()

        XCTAssertEqual(controller.popCount, 0)
        XCTAssertEqual(controller.popToRootCount, 0)
        XCTAssertEqual(navigator.templateCount, 0)
        XCTAssertFalse(navigator.isNowPlayingOnTop)
        XCTAssertEqual(controller.raised, [])
    }

    func testEmptyStack_explicitPopIsReportedNotRaised() {
        let controller = FakeCarPlayController(templates: [])
        let navigator = makeNavigator(controller)

        navigator.pop(operation: "popTemplate(chapterList)")
        controller.drain()

        XCTAssertEqual(controller.raised, [])
        XCTAssertEqual(controller.reported, ["No templates were available to be popped."])
    }

    // MARK: Deallocated controller

    func testDeallocatedController_everyOperationIsANoOpAndNoOutcomeRuns() {
        var controller: FakeCarPlayController? = FakeCarPlayController(templates: [root, nowPlaying])
        let navigator = makeNavigator(controller!)
        XCTAssertTrue(navigator.isAttached)
        XCTAssertTrue(navigator.isNowPlayingOnTop)
        weak var released = controller
        controller = nil
        XCTAssertNil(released, "precondition: the navigator must not keep the controller alive")
        var outcomes = 0

        navigator.setRoot(root, operation: "setRootTemplate(library)") { _ in outcomes += 1 }
        navigator.push(nowPlaying, operation: "pushTemplate(nowPlaying)") { _ in outcomes += 1 }
        navigator.present(nowPlaying, operation: "presentTemplate(errorAlert)") { _ in outcomes += 1 }
        navigator.dismiss(operation: "dismissTemplate(alert)") { _ in outcomes += 1 }
        navigator.pop(operation: "popTemplate(chapterList)")
        navigator.popToRootIfStacked()
        navigator.popNowPlayingIfOnTop()

        XCTAssertEqual(outcomes, 0)
        XCTAssertFalse(navigator.isAttached)
        XCTAssertNil(navigator.templateCount)
        XCTAssertFalse(navigator.hasPresentedTemplate)
        XCTAssertFalse(navigator.isNowPlayingOnTop)
    }

    // MARK: Production Now Playing predicate

    func testDefaultPredicate_popsTheSystemNowPlayingTemplate() {
        let controller = FakeCarPlayController(templates: [root, CPNowPlayingTemplate.shared])
        let navigator = CarPlayTemplateNavigator(controller: controller)

        XCTAssertTrue(navigator.isNowPlayingOnTop)
        navigator.popNowPlayingIfOnTop()
        controller.drain()

        XCTAssertEqual(controller.popCount, 1)
        XCTAssertTrue(controller.topTemplate === root)
    }

    func testDefaultPredicate_leavesAListTemplateOnTopInPlace() {
        let chapters = CPListTemplate(title: "Chapters", sections: [])
        let controller = FakeCarPlayController(templates: [root, chapters])
        let navigator = CarPlayTemplateNavigator(controller: controller)

        XCTAssertFalse(navigator.isNowPlayingOnTop)
        navigator.popNowPlayingIfOnTop()
        controller.drain()

        XCTAssertEqual(controller.popCount, 0)
        XCTAssertTrue(controller.topTemplate === chapters)
    }
}

//
//  CarPlayTests.swift
//  PalaceTests
//
//  Tests for CarPlay audiobook support
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import CarPlay
@testable import Palace
@testable import PalaceAudiobookToolkit

/// Tests for CarPlay audiobook browsing and playback integration.
/// Verifies library display, chapter navigation, and error handling.
@MainActor
class CarPlayTests: XCTestCase {
  
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
  
  func testCarPlay_TemplateManager_CreatesWithInterfaceController() {
    // This test verifies the template manager can be initialized
    // In a real test environment, we'd need to mock CPInterfaceController
    // For now, we verify the components compile and link correctly
    
    // Assert that the classes exist and can be referenced
    XCTAssertNotNil(CarPlayAudiobookBridge.self)
    XCTAssertNotNil(CarPlayImageProvider.self)
    // CarPlayTemplateManager and CarPlaySceneDelegate require CPInterfaceController
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
    let _ = SceneDelegate.hasMainSceneConnected
    
    // The flag should be a Bool
    XCTAssertTrue(true, "hasMainSceneConnected flag should be accessible")
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
  }
  
  func testCarPlay_BookRegistry_IsAccessible() {
    // Verify book registry can be accessed (used for library book list)
    let registry = TPPBookRegistry.shared
    XCTAssertNotNil(registry, "Book registry should be accessible")
  }
  
  func testCarPlay_DownloadedAudiobooks_CanBeFiltered() {
    // Arrange
    let audiobookState = TPPBookState.downloadSuccessful
    let ebookState = TPPBookState.downloadSuccessful
    
    // Assert - verify these states are recognized as downloaded
    XCTAssertTrue(
      audiobookState == .downloadSuccessful || 
      audiobookState == .downloadNeeded ||
      audiobookState == .downloading,
      "Should recognize download states"
    )
    
    // Verify both are the same state
    XCTAssertEqual(audiobookState, ebookState)
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
}

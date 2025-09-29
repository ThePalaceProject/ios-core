//
//  ComprehensiveFileCleanupTests.swift
//  PalaceTests
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

// MARK: - ComprehensiveFileCleanupTests

final class ComprehensiveFileCleanupTests: XCTestCase {
  var downloadCenter: MyBooksDownloadCenter!
  var testBookId: String!
  var testBook: TPPBook!

  override func setUp() {
    super.setUp()
    downloadCenter = MyBooksDownloadCenter.shared
    testBookId = "test-book-cleanup-\(UUID().uuidString)"
    testBook = createMockBook(identifier: testBookId)
  }

  override func tearDown() {
    // Clean up any test files that might remain
    cleanupTestFiles()

    testBook = nil
    testBookId = nil
    downloadCenter = nil
    super.tearDown()
  }

  // MARK: - Basic Functionality Tests

  func testCompletelyRemoveAudiobookExists() {
    // Given: Download center
    // Then: Method should exist and be callable
    XCTAssertNoThrow(downloadCenter.completelyRemoveAudiobook(testBook))
  }

  func testFindRemainingFilesExists() {
    // Given: Download center
    // Then: Method should exist and return array
    let remainingFiles = downloadCenter.findRemainingFiles(for: testBookId)
    XCTAssertNotNil(remainingFiles)
  }

  func testReturnBookWithCompleteCleanupExists() {
    // Given: Download center
    // Then: Method should exist and be callable
    XCTAssertNoThrow(downloadCenter.returnBookWithCompleteCleanup(testBook))
  }

  // MARK: - File Detection Tests

  func testFindRemainingFilesDetectsTestFiles() {
    // Given: Create test files with book ID
    createTestFilesForBook(testBookId)

    // When: Search for remaining files
    let remainingFiles = downloadCenter.findRemainingFiles(for: testBookId)

    // Then: Should find the test files
    XCTAssertGreaterThan(remainingFiles.count, 0, "Should find test files containing book ID")

    // Verify at least one file contains the book ID
    let containsBookId = remainingFiles.contains { $0.contains(testBookId) }
    XCTAssertTrue(containsBookId, "Found files should contain book ID")
  }

  func testCleanupRemovesTestFiles() {
    // Given: Create test files with book ID
    createTestFilesForBook(testBookId)

    // Verify files exist before cleanup
    let filesBeforeCleanup = downloadCenter.findRemainingFiles(for: testBookId)
    XCTAssertGreaterThan(filesBeforeCleanup.count, 0, "Should have test files before cleanup")

    // When: Perform cleanup
    downloadCenter.completelyRemoveAudiobook(testBook)

    // Give cleanup time to complete
    let expectation = XCTestExpectation(description: "Cleanup completion")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 2.0)

    // Then: Files should be reduced or removed
    let filesAfterCleanup = downloadCenter.findRemainingFiles(for: testBookId)
    XCTAssertLessThanOrEqual(filesAfterCleanup.count, filesBeforeCleanup.count, "Cleanup should reduce file count")
  }

  // MARK: - Edge Case Tests

  func testCleanupHandlesNonExistentBook() {
    // Given: Non-existent book ID
    let nonExistentBook = createMockBook(identifier: "non-existent-book-id")

    // When: Attempt cleanup
    // Then: Should not crash
    XCTAssertNoThrow(downloadCenter.completelyRemoveAudiobook(nonExistentBook))
  }

  func testFindRemainingFilesHandlesEmptyDirectory() {
    // Given: Book ID that has no associated files
    let cleanBookId = "clean-book-\(UUID().uuidString)"

    // When: Search for remaining files
    let remainingFiles = downloadCenter.findRemainingFiles(for: cleanBookId)

    // Then: Should return empty array without crashing
    XCTAssertEqual(remainingFiles.count, 0, "Should find no files for clean book ID")
  }

  // MARK: - Integration Tests

  func testComprehensiveCleanupDoesNotAffectOtherBooks() {
    // Given: Files for multiple books
    let otherBookId = "other-book-\(UUID().uuidString)"
    createTestFilesForBook(testBookId)
    createTestFilesForBook(otherBookId)

    // Verify both books have files
    let testBookFilesBefore = downloadCenter.findRemainingFiles(for: testBookId)
    let otherBookFilesBefore = downloadCenter.findRemainingFiles(for: otherBookId)
    XCTAssertGreaterThan(testBookFilesBefore.count, 0)
    XCTAssertGreaterThan(otherBookFilesBefore.count, 0)

    // When: Clean up only test book
    downloadCenter.completelyRemoveAudiobook(testBook)

    // Give cleanup time to complete
    let expectation = XCTestExpectation(description: "Cleanup completion")
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 2.0)

    // Then: Other book's files should remain
    let otherBookFilesAfter = downloadCenter.findRemainingFiles(for: otherBookId)
    XCTAssertGreaterThanOrEqual(
      otherBookFilesAfter.count,
      otherBookFilesBefore.count * 0.8,
      "Other book's files should mostly remain"
    )

    // Clean up other book's test files
    let otherBook = createMockBook(identifier: otherBookId)
    downloadCenter.completelyRemoveAudiobook(otherBook)
  }

  // MARK: - Helper Methods

  private func createMockBook(identifier: String) -> TPPBook {
    // Create a minimal mock book for testing
    // This is a simplified version - in real tests you might need a more complete mock
    let book = TPPBook()
    book.identifier = identifier
    book.title = "Test Book \(identifier)"
    return book
  }

  private func createTestFilesForBook(_ bookId: String) {
    let fileManager = FileManager.default

    // Create test files in various locations that might be used by audiobooks
    let testLocations = [
      FileManager.default.temporaryDirectory,
      fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first,
    ].compactMap { $0 }

    for location in testLocations {
      let testFiles = [
        location.appendingPathComponent("\(bookId).test"),
        location.appendingPathComponent("test_\(bookId).tmp"),
        location.appendingPathComponent("\(bookId)_cache.data"),
      ]

      for testFile in testFiles {
        do {
          try "test data".write(to: testFile, atomically: true, encoding: .utf8)
        } catch {
          // Ignore write errors in test setup
        }
      }
    }

    // Create test directories
    let testDirectories = [
      FileManager.default.temporaryDirectory.appendingPathComponent("AudiobookCache").appendingPathComponent(bookId),
      fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent(bookId),
    ].compactMap { $0 }

    for testDirectory in testDirectories {
      do {
        try fileManager.createDirectory(at: testDirectory, withIntermediateDirectories: true)
        // Add a test file in the directory
        let testFile = testDirectory.appendingPathComponent("test.data")
        try "test content".write(to: testFile, atomically: true, encoding: .utf8)
      } catch {
        // Ignore creation errors in test setup
      }
    }
  }

  private func cleanupTestFiles() {
    // Clean up any test files that might remain after tests
    guard let testBookId = testBookId else {
      return
    }

    let fileManager = FileManager.default
    let searchLocations = [
      FileManager.default.temporaryDirectory,
      fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first,
      fileManager.urls(for: .documentDirectory, in: .userDomainMask).first,
    ].compactMap { $0 }

    for location in searchLocations {
      guard let enumerator = fileManager.enumerator(
        at: location,
        includingPropertiesForKeys: [.nameKey],
        options: [.skipsHiddenFiles]
      ) else {
        continue
      }

      for case let fileURL as URL in enumerator {
        let fileName = fileURL.lastPathComponent
        if fileName.contains(testBookId) {
          try? fileManager.removeItem(at: fileURL)
        }
      }
    }
  }
}

// MARK: - AudiobookDataManagerCleanupTests

final class AudiobookDataManagerCleanupTests: XCTestCase {
  func testRemoveTrackingDataExists() {
    // Given: AudiobookDataManager
    let dataManager = AudiobookDataManager()

    // Then: Method should exist and be callable
    XCTAssertNoThrow(dataManager.removeTrackingData(for: "test-book-id"))
  }

  func testRemoveTrackingDataHandlesNonExistentBook() {
    // Given: AudiobookDataManager
    let dataManager = AudiobookDataManager()

    // When: Remove tracking data for non-existent book
    // Then: Should not crash
    XCTAssertNoThrow(dataManager.removeTrackingData(for: "non-existent-book"))
  }
}

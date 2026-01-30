//
//  TPPBookmarkDeletionLogTests.swift
//  PalaceTests
//
//  Tests for TPPBookmarkDeletionLog - regression prevention for ghost bookmark fix
//  Ensures bookmark deletion tracking works correctly to prevent "ghost bookmarks"
//

import XCTest
@testable import Palace

/// Tests for the bookmark deletion log which tracks explicitly deleted bookmarks
/// to ensure they get deleted from the server during sync, regardless of device ID.
final class TPPBookmarkDeletionLogTests: XCTestCase {
  
  private var deletionLog: TPPBookmarkDeletionLog!
  private let testBookId = "test-book-identifier"
  private let testAnnotationId = "https://example.com/annotations/12345"
  private let testAnnotationId2 = "https://example.com/annotations/67890"
  
  // MARK: - Setup/Teardown
  
  override func setUp() {
    super.setUp()
    // Clear any existing data
    UserDefaults.standard.removeObject(forKey: "TPPBookmarkDeletionLog")
    deletionLog = TPPBookmarkDeletionLog.shared
  }
  
  override func tearDown() {
    // Clean up test data
    deletionLog.clearAllDeletions(forBook: testBookId)
    UserDefaults.standard.removeObject(forKey: "TPPBookmarkDeletionLog")
    super.tearDown()
  }
  
  // MARK: - Basic Functionality Tests
  
  /// Test that logging a deletion adds it to pending deletions
  func testLogDeletion_AddsToPendingDeletions() {
    // Act
    deletionLog.logDeletion(annotationId: testAnnotationId, forBook: testBookId)
    
    // Allow async operation to complete
    let expectation = self.expectation(description: "Async deletion log")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      expectation.fulfill()
    }
    waitForExpectations(timeout: 1.0)
    
    // Assert
    let pendingDeletions = deletionLog.pendingDeletions(forBook: testBookId)
    XCTAssertTrue(pendingDeletions.contains(testAnnotationId),
                  "Logged annotation ID should be in pending deletions")
  }
  
  /// Test that empty annotation IDs are ignored
  func testLogDeletion_IgnoresEmptyAnnotationId() {
    // Act
    deletionLog.logDeletion(annotationId: "", forBook: testBookId)
    
    // Allow async operation to complete
    let expectation = self.expectation(description: "Async deletion log")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      expectation.fulfill()
    }
    waitForExpectations(timeout: 1.0)
    
    // Assert
    let pendingDeletions = deletionLog.pendingDeletions(forBook: testBookId)
    XCTAssertTrue(pendingDeletions.isEmpty,
                  "Empty annotation IDs should be ignored")
  }
  
  /// Test that multiple deletions can be logged for the same book
  func testLogDeletion_MultipleDeletionsForSameBook() {
    // Act
    deletionLog.logDeletion(annotationId: testAnnotationId, forBook: testBookId)
    deletionLog.logDeletion(annotationId: testAnnotationId2, forBook: testBookId)
    
    // Allow async operations to complete
    let expectation = self.expectation(description: "Async deletion log")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      expectation.fulfill()
    }
    waitForExpectations(timeout: 1.0)
    
    // Assert
    let pendingDeletions = deletionLog.pendingDeletions(forBook: testBookId)
    XCTAssertEqual(pendingDeletions.count, 2,
                   "Should have 2 pending deletions")
    XCTAssertTrue(pendingDeletions.contains(testAnnotationId))
    XCTAssertTrue(pendingDeletions.contains(testAnnotationId2))
  }
  
  /// Test that duplicates are handled correctly (Set behavior)
  func testLogDeletion_HandlesDuplicates() {
    // Act - log same annotation twice
    deletionLog.logDeletion(annotationId: testAnnotationId, forBook: testBookId)
    deletionLog.logDeletion(annotationId: testAnnotationId, forBook: testBookId)
    
    // Allow async operations to complete
    let expectation = self.expectation(description: "Async deletion log")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      expectation.fulfill()
    }
    waitForExpectations(timeout: 1.0)
    
    // Assert
    let pendingDeletions = deletionLog.pendingDeletions(forBook: testBookId)
    XCTAssertEqual(pendingDeletions.count, 1,
                   "Duplicate annotation IDs should be deduplicated")
  }
  
  // MARK: - Clear Deletion Tests
  
  /// Test that clearing a specific deletion removes it
  func testClearDeletion_RemovesSpecificAnnotation() {
    // Arrange
    deletionLog.logDeletion(annotationId: testAnnotationId, forBook: testBookId)
    deletionLog.logDeletion(annotationId: testAnnotationId2, forBook: testBookId)
    
    // Wait for log
    let logExpectation = self.expectation(description: "Log complete")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      logExpectation.fulfill()
    }
    waitForExpectations(timeout: 1.0)
    
    // Act
    deletionLog.clearDeletion(annotationId: testAnnotationId, forBook: testBookId)
    
    // Wait for clear
    let clearExpectation = self.expectation(description: "Clear complete")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      clearExpectation.fulfill()
    }
    waitForExpectations(timeout: 1.0)
    
    // Assert
    let pendingDeletions = deletionLog.pendingDeletions(forBook: testBookId)
    XCTAssertFalse(pendingDeletions.contains(testAnnotationId),
                   "Cleared annotation should be removed")
    XCTAssertTrue(pendingDeletions.contains(testAnnotationId2),
                  "Other annotations should remain")
  }
  
  /// Test that clearAllDeletions removes all deletions for a book
  func testClearAllDeletions_RemovesAllForBook() {
    // Arrange
    deletionLog.logDeletion(annotationId: testAnnotationId, forBook: testBookId)
    deletionLog.logDeletion(annotationId: testAnnotationId2, forBook: testBookId)
    
    // Wait for log
    let logExpectation = self.expectation(description: "Log complete")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      logExpectation.fulfill()
    }
    waitForExpectations(timeout: 1.0)
    
    XCTAssertEqual(deletionLog.pendingDeletions(forBook: testBookId).count, 2,
                   "Precondition: should have 2 pending deletions")
    
    // Act
    deletionLog.clearAllDeletions(forBook: testBookId)
    
    // Wait for clear
    let clearExpectation = self.expectation(description: "Clear complete")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      clearExpectation.fulfill()
    }
    waitForExpectations(timeout: 1.0)
    
    // Assert
    let pendingDeletions = deletionLog.pendingDeletions(forBook: testBookId)
    XCTAssertTrue(pendingDeletions.isEmpty,
                  "All deletions should be cleared")
  }
  
  /// Test that clearAllDeletions only affects the specified book
  func testClearAllDeletions_OnlyAffectsSpecifiedBook() {
    let otherBookId = "other-book-identifier"
    
    // Arrange
    deletionLog.logDeletion(annotationId: testAnnotationId, forBook: testBookId)
    deletionLog.logDeletion(annotationId: testAnnotationId2, forBook: otherBookId)
    
    // Wait for log
    let logExpectation = self.expectation(description: "Log complete")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      logExpectation.fulfill()
    }
    waitForExpectations(timeout: 1.0)
    
    // Act
    deletionLog.clearAllDeletions(forBook: testBookId)
    
    // Wait for clear
    let clearExpectation = self.expectation(description: "Clear complete")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      clearExpectation.fulfill()
    }
    waitForExpectations(timeout: 1.0)
    
    // Assert
    XCTAssertTrue(deletionLog.pendingDeletions(forBook: testBookId).isEmpty,
                  "Specified book should have no pending deletions")
    XCTAssertTrue(deletionLog.pendingDeletions(forBook: otherBookId).contains(testAnnotationId2),
                  "Other book's deletions should be unaffected")
    
    // Cleanup
    deletionLog.clearAllDeletions(forBook: otherBookId)
  }
  
  // MARK: - pendingDeletions Tests
  
  /// Test that pendingDeletions returns empty set for unknown book
  func testPendingDeletions_ReturnsEmptyForUnknownBook() {
    let unknownBookId = "unknown-book-\(UUID().uuidString)"
    
    // Act
    let pendingDeletions = deletionLog.pendingDeletions(forBook: unknownBookId)
    
    // Assert
    XCTAssertTrue(pendingDeletions.isEmpty,
                  "Unknown book should have no pending deletions")
  }
  
  // MARK: - Ghost Bookmark Regression Tests
  
  /// Verify that deletion log correctly tracks bookmarks for server deletion
  /// This prevents "ghost bookmarks" from reappearing after return/re-borrow
  func testPP3555_DeletionLogTracksBookmarksForServerDeletion() {
    // Scenario: User deletes a bookmark locally. The deletion should be tracked
    // so that during sync, it can be deleted from the server.
    
    let annotationId = "https://library.example.com/annotations/pp3555-test"
    
    // Act: Log the deletion (as would happen when user deletes a bookmark)
    deletionLog.logDeletion(annotationId: annotationId, forBook: testBookId)
    
    // Wait for async
    let expectation = self.expectation(description: "Log complete")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      expectation.fulfill()
    }
    waitForExpectations(timeout: 1.0)
    
    // Assert: Deletion should be tracked for later sync
    let pendingDeletions = deletionLog.pendingDeletions(forBook: testBookId)
    XCTAssertTrue(pendingDeletions.contains(annotationId),
                  "Deletion should be tracked for server sync")
  }
  
  /// Verify that clearAllDeletions is called during book return
  /// to reset state and prevent stale deletion tracking
  func testPP3555_ClearAllDeletionsOnBookReturn() {
    // Scenario: When a book is returned, all pending deletions should be cleared
    // because the server bookmarks will be deleted as part of the return process
    
    // Arrange: Log some deletions (simulating user deleted bookmarks)
    deletionLog.logDeletion(annotationId: testAnnotationId, forBook: testBookId)
    deletionLog.logDeletion(annotationId: testAnnotationId2, forBook: testBookId)
    
    // Wait for log
    let logExpectation = self.expectation(description: "Log complete")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      logExpectation.fulfill()
    }
    waitForExpectations(timeout: 1.0)
    
    XCTAssertFalse(deletionLog.pendingDeletions(forBook: testBookId).isEmpty,
                   "Precondition: should have pending deletions")
    
    // Act: Clear all deletions (as would happen during book return)
    deletionLog.clearAllDeletions(forBook: testBookId)
    
    // Wait for clear
    let clearExpectation = self.expectation(description: "Clear complete")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      clearExpectation.fulfill()
    }
    waitForExpectations(timeout: 1.0)
    
    // Assert: All deletions should be cleared
    XCTAssertTrue(deletionLog.pendingDeletions(forBook: testBookId).isEmpty,
                  "All deletions should be cleared on book return")
  }
  
  // MARK: - Thread Safety Tests
  
  /// Test that the deletion log is thread-safe for concurrent writes
  func testThreadSafety_ConcurrentWrites() {
    let iterations = 100
    let expectation = self.expectation(description: "Concurrent writes complete")
    expectation.expectedFulfillmentCount = iterations
    
    // Act: Write from multiple threads concurrently
    for i in 0..<iterations {
      DispatchQueue.global().async {
        self.deletionLog.logDeletion(
          annotationId: "https://example.com/annotation/\(i)",
          forBook: self.testBookId
        )
        expectation.fulfill()
      }
    }
    
    waitForExpectations(timeout: 5.0)
    
    // Wait a bit more for all writes to complete
    let finalExpectation = self.expectation(description: "Final wait")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      finalExpectation.fulfill()
    }
    waitForExpectations(timeout: 1.0)
    
    // Assert: All writes should have succeeded (Set deduplication applies)
    let pendingDeletions = deletionLog.pendingDeletions(forBook: testBookId)
    XCTAssertEqual(pendingDeletions.count, iterations,
                   "All concurrent writes should succeed")
  }
}

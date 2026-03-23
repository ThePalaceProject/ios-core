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
        UserDefaults.standard.removeObject(forKey: "TPPBookmarkDeletionLog")
        deletionLog = TPPBookmarkDeletionLog.shared
    }

    override func tearDown() {
        deletionLog.clearAllDeletions(forBook: testBookId)
        UserDefaults.standard.removeObject(forKey: "TPPBookmarkDeletionLog")
        super.tearDown()
    }

    // MARK: - Basic Functionality Tests

    /// Test that logging a deletion adds it to pending deletions.
    /// logDeletion uses queue.async(flags:.barrier); pendingDeletions uses queue.sync —
    /// the sync read is guaranteed to drain all prior barrier writes.
    func testLogDeletion_AddsToPendingDeletions() {
        deletionLog.logDeletion(annotationId: testAnnotationId, forBook: testBookId)

        let pendingDeletions = deletionLog.pendingDeletions(forBook: testBookId)
        XCTAssertTrue(pendingDeletions.contains(testAnnotationId),
                      "Logged annotation ID should be in pending deletions")
    }

    func testLogDeletion_IgnoresEmptyAnnotationId() {
        deletionLog.logDeletion(annotationId: "", forBook: testBookId)

        let pendingDeletions = deletionLog.pendingDeletions(forBook: testBookId)
        XCTAssertTrue(pendingDeletions.isEmpty,
                      "Empty annotation IDs should be ignored")
    }

    func testLogDeletion_MultipleDeletionsForSameBook() {
        deletionLog.logDeletion(annotationId: testAnnotationId, forBook: testBookId)
        deletionLog.logDeletion(annotationId: testAnnotationId2, forBook: testBookId)

        let pendingDeletions = deletionLog.pendingDeletions(forBook: testBookId)
        XCTAssertEqual(pendingDeletions.count, 2)
        XCTAssertTrue(pendingDeletions.contains(testAnnotationId))
        XCTAssertTrue(pendingDeletions.contains(testAnnotationId2))
    }

    func testLogDeletion_HandlesDuplicates() {
        deletionLog.logDeletion(annotationId: testAnnotationId, forBook: testBookId)
        deletionLog.logDeletion(annotationId: testAnnotationId, forBook: testBookId)

        let pendingDeletions = deletionLog.pendingDeletions(forBook: testBookId)
        XCTAssertEqual(pendingDeletions.count, 1,
                       "Duplicate annotation IDs should be deduplicated")
    }

    // MARK: - Clear Deletion Tests

    func testClearDeletion_RemovesSpecificAnnotation() {
        deletionLog.logDeletion(annotationId: testAnnotationId, forBook: testBookId)
        deletionLog.logDeletion(annotationId: testAnnotationId2, forBook: testBookId)

        deletionLog.clearDeletion(annotationId: testAnnotationId, forBook: testBookId)

        let pendingDeletions = deletionLog.pendingDeletions(forBook: testBookId)
        XCTAssertFalse(pendingDeletions.contains(testAnnotationId),
                       "Cleared annotation should be removed")
        XCTAssertTrue(pendingDeletions.contains(testAnnotationId2),
                      "Other annotations should remain")
    }

    func testClearAllDeletions_RemovesAllForBook() {
        deletionLog.logDeletion(annotationId: testAnnotationId, forBook: testBookId)
        deletionLog.logDeletion(annotationId: testAnnotationId2, forBook: testBookId)

        XCTAssertEqual(deletionLog.pendingDeletions(forBook: testBookId).count, 2,
                       "Precondition: should have 2 pending deletions")

        deletionLog.clearAllDeletions(forBook: testBookId)

        XCTAssertTrue(deletionLog.pendingDeletions(forBook: testBookId).isEmpty,
                      "All deletions should be cleared")
    }

    func testClearAllDeletions_OnlyAffectsSpecifiedBook() {
        let otherBookId = "other-book-identifier"

        deletionLog.logDeletion(annotationId: testAnnotationId, forBook: testBookId)
        deletionLog.logDeletion(annotationId: testAnnotationId2, forBook: otherBookId)

        deletionLog.clearAllDeletions(forBook: testBookId)

        XCTAssertTrue(deletionLog.pendingDeletions(forBook: testBookId).isEmpty,
                      "Specified book should have no pending deletions")
        XCTAssertTrue(deletionLog.pendingDeletions(forBook: otherBookId).contains(testAnnotationId2),
                      "Other book's deletions should be unaffected")

        deletionLog.clearAllDeletions(forBook: otherBookId)
    }

    // MARK: - pendingDeletions Tests

    func testPendingDeletions_ReturnsEmptyForUnknownBook() {
        let unknownBookId = "unknown-book-\(UUID().uuidString)"

        let pendingDeletions = deletionLog.pendingDeletions(forBook: unknownBookId)
        XCTAssertTrue(pendingDeletions.isEmpty,
                      "Unknown book should have no pending deletions")
    }

    // MARK: - Ghost Bookmark Regression Tests

    func testPP3555_DeletionLogTracksBookmarksForServerDeletion() {
        let annotationId = "https://library.example.com/annotations/pp3555-test"

        deletionLog.logDeletion(annotationId: annotationId, forBook: testBookId)

        let pendingDeletions = deletionLog.pendingDeletions(forBook: testBookId)
        XCTAssertTrue(pendingDeletions.contains(annotationId),
                      "Deletion should be tracked for server sync")
    }

    func testPP3555_ClearAllDeletionsOnBookReturn() {
        deletionLog.logDeletion(annotationId: testAnnotationId, forBook: testBookId)
        deletionLog.logDeletion(annotationId: testAnnotationId2, forBook: testBookId)

        XCTAssertFalse(deletionLog.pendingDeletions(forBook: testBookId).isEmpty,
                       "Precondition: should have pending deletions")

        deletionLog.clearAllDeletions(forBook: testBookId)

        XCTAssertTrue(deletionLog.pendingDeletions(forBook: testBookId).isEmpty,
                      "All deletions should be cleared on book return")
    }

    // MARK: - Thread Safety Tests

    func testThreadSafety_ConcurrentWrites() {
        let iterations = 100
        let writesDone = expectation(description: "Concurrent writes complete")
        writesDone.expectedFulfillmentCount = iterations

        for i in 0..<iterations {
            DispatchQueue.global().async {
                self.deletionLog.logDeletion(
                    annotationId: "https://example.com/annotation/\(i)",
                    forBook: self.testBookId
                )
                writesDone.fulfill()
            }
        }

        // Wait until all dispatches have been queued (not necessarily processed).
        // pendingDeletions uses queue.sync, which drains all prior async barriers —
        // so reading after waitForExpectations gives the final committed count.
        waitForExpectations(timeout: 5.0)

        let pendingDeletions = deletionLog.pendingDeletions(forBook: testBookId)
        XCTAssertEqual(pendingDeletions.count, iterations,
                       "All concurrent writes should succeed")
    }
}

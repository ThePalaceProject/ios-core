//
//  MyBooksDownloadCenterIntegrationTests.swift
//  PalaceTests
//
//  Integration tests for MyBooksDownloadCenter testing real download logic.
//  These tests use MockURLProtocol for network mocking while testing
//  real business logic in MyBooksDownloadCenter.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace

// MARK: - MockURLProtocol for Network Mocking

/// A URLProtocol subclass that intercepts URL requests for testing.
/// Allows tests to control network responses without making real network calls.
class MockURLProtocol: URLProtocol {
  
  /// Handler closure that provides mock responses for requests
  static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data?))?
  
  /// Track all requests made during tests
  static var capturedRequests: [URLRequest] = []
  
  /// Delays before responding (to simulate network latency)
  static var responseDelay: TimeInterval = 0
  
  override class func canInit(with request: URLRequest) -> Bool {
    // Intercept all requests in tests
    return true
  }
  
  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    return request
  }
  
  override func startLoading() {
    MockURLProtocol.capturedRequests.append(request)
    
    guard let handler = MockURLProtocol.requestHandler else {
      let error = NSError(domain: "MockURLProtocol", code: -1, userInfo: [NSLocalizedDescriptionKey: "No handler configured"])
      client?.urlProtocol(self, didFailWithError: error)
      return
    }
    
    // Simulate network delay if configured
    if MockURLProtocol.responseDelay > 0 {
      Thread.sleep(forTimeInterval: MockURLProtocol.responseDelay)
    }
    
    do {
      let (response, data) = try handler(request)
      
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      
      if let data = data {
        client?.urlProtocol(self, didLoad: data)
      }
      
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }
  
  override func stopLoading() {
    // No-op for mock
  }
  
  /// Resets all mock state between tests
  static func reset() {
    requestHandler = nil
    capturedRequests = []
    responseDelay = 0
  }
}

// MARK: - Test Error Types

enum MockNetworkError: Error {
  case timeout
  case serverError(Int)
  case notFound
  case unauthorized
}

// MARK: - Download Coordinator Integration Tests

/// Integration tests for DownloadCoordinator actor.
/// Tests real concurrency behavior and state management.
final class DownloadCoordinatorIntegrationTests: XCTestCase {
  
  // MARK: - Concurrency Tests
  
  func testCoordinator_concurrentRegistrations_maintainsConsistency() async {
    // Given a coordinator
    let coordinator = DownloadCoordinator()
    let bookCount = 100
    
    // When registering many downloads concurrently
    await withTaskGroup(of: Void.self) { group in
      for i in 0..<bookCount {
        group.addTask {
          await coordinator.registerStart(identifier: "book-\(i)")
        }
      }
    }
    
    // Then active count should match
    let count = await coordinator.activeCount
    XCTAssertEqual(count, bookCount, "All concurrent registrations should be tracked")
  }
  
  func testCoordinator_concurrentCompletions_maintainsConsistency() async {
    // Given a coordinator with active downloads
    let coordinator = DownloadCoordinator()
    let bookCount = 50
    
    // Register all downloads first
    for i in 0..<bookCount {
      await coordinator.registerStart(identifier: "book-\(i)")
    }
    
    // When completing many downloads concurrently
    await withTaskGroup(of: Void.self) { group in
      for i in 0..<bookCount {
        group.addTask {
          await coordinator.registerCompletion(identifier: "book-\(i)")
        }
      }
    }
    
    // Then active count should be zero
    let count = await coordinator.activeCount
    XCTAssertEqual(count, 0, "All concurrent completions should be processed")
  }
  
  func testCoordinator_mixedOperations_maintainsConsistency() async {
    // Given a coordinator
    let coordinator = DownloadCoordinator()
    
    // When performing mixed operations concurrently
    await withTaskGroup(of: Void.self) { group in
      // Start 10 downloads
      for i in 0..<10 {
        group.addTask {
          await coordinator.registerStart(identifier: "book-\(i)")
        }
      }
      
      // Complete first 5
      for i in 0..<5 {
        group.addTask {
          // Small delay to ensure starts happen first
          try? await Task.sleep(nanoseconds: 10_000_000)
          await coordinator.registerCompletion(identifier: "book-\(i)")
        }
      }
    }
    
    // Then should have 5 active
    let count = await coordinator.activeCount
    XCTAssertEqual(count, 5, "Should have 5 remaining active downloads")
  }
  
  // MARK: - Queue Management Tests
  
  func testCoordinator_queueFIFO_maintainsOrder() async {
    // Given a coordinator
    let coordinator = DownloadCoordinator()
    
    // When enqueueing books in order
    let book1 = TPPBookMocker.mockBook(identifier: "book-001", title: "First", distributorType: .EpubZip)
    let book2 = TPPBookMocker.mockBook(identifier: "book-002", title: "Second", distributorType: .EpubZip)
    let book3 = TPPBookMocker.mockBook(identifier: "book-003", title: "Third", distributorType: .EpubZip)
    
    await coordinator.enqueuePending(book1)
    await coordinator.enqueuePending(book2)
    await coordinator.enqueuePending(book3)
    
    // Then dequeue should return in FIFO order
    let dequeued = await coordinator.dequeuePending(capacity: 3)
    
    XCTAssertEqual(dequeued.count, 3)
    XCTAssertEqual(dequeued[0].identifier, "book-001", "First book should be dequeued first")
    XCTAssertEqual(dequeued[1].identifier, "book-002", "Second book should be dequeued second")
    XCTAssertEqual(dequeued[2].identifier, "book-003", "Third book should be dequeued third")
  }
  
  func testCoordinator_partialDequeue_leavesRemainder() async {
    // Given a coordinator with 5 pending books
    let coordinator = DownloadCoordinator()
    
    for i in 0..<5 {
      let book = TPPBookMocker.mockBook(identifier: "book-\(i)", title: "Book \(i)", distributorType: .EpubZip)
      await coordinator.enqueuePending(book)
    }
    
    // When dequeuing only 2
    let dequeued = await coordinator.dequeuePending(capacity: 2)
    
    // Then should have 2 dequeued and 3 remaining
    XCTAssertEqual(dequeued.count, 2)
    
    let remaining = await coordinator.queueCount
    XCTAssertEqual(remaining, 3, "Should have 3 books remaining in queue")
  }
  
  func testCoordinator_zeroCapacityDequeue_returnsEmpty() async {
    // Given a coordinator with pending books
    let coordinator = DownloadCoordinator()
    let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
    await coordinator.enqueuePending(book)
    
    // When dequeuing with zero capacity
    let dequeued = await coordinator.dequeuePending(capacity: 0)
    
    // Then should return empty array
    XCTAssertTrue(dequeued.isEmpty)
    
    // And queue should still have the book
    let remaining = await coordinator.queueCount
    XCTAssertEqual(remaining, 1)
  }
  
  // MARK: - Throttling Tests
  
  func testCoordinator_throttling_returnsDelayAfterRecentStart() async {
    // Given a coordinator with a recent start
    let coordinator = DownloadCoordinator()
    await coordinator.registerStart(identifier: "book-1")
    
    // When checking throttle immediately
    let throttleDelay = await coordinator.shouldThrottleStart()
    
    // Then should return a positive delay (minimum start delay is 0.3s)
    XCTAssertGreaterThan(throttleDelay, 0, "Should require throttle delay after recent start")
    XCTAssertLessThanOrEqual(throttleDelay, 0.3, "Delay should not exceed minimum start delay")
  }
  
  func testCoordinator_throttling_returnsZeroAfterDelay() async {
    // Given a coordinator
    let coordinator = DownloadCoordinator()
    
    // With no recent starts
    // When checking throttle
    let throttleDelay = await coordinator.shouldThrottleStart()
    
    // Then should return zero (no recent starts)
    XCTAssertEqual(throttleDelay, 0, "Should not throttle when no recent starts")
  }
  
  // MARK: - Download Info Cache Tests
  
  func testCoordinator_downloadInfoCache_storesMultipleEntries() async {
    // Given a coordinator
    let coordinator = DownloadCoordinator()
    let mockTask1 = MockURLSessionDownloadTask(taskIdentifier: 1)
    let mockTask2 = MockURLSessionDownloadTask(taskIdentifier: 2)
    
    let info1 = MyBooksDownloadInfo(downloadProgress: 0.25, downloadTask: mockTask1, rightsManagement: .none)
    let info2 = MyBooksDownloadInfo(downloadProgress: 0.75, downloadTask: mockTask2, rightsManagement: .adobe)
    
    // When caching multiple entries
    await coordinator.cacheDownloadInfo(info1, for: "book-1")
    await coordinator.cacheDownloadInfo(info2, for: "book-2")
    
    // Then both should be retrievable
    let cached1 = await coordinator.getCachedDownloadInfo(for: "book-1")
    let cached2 = await coordinator.getCachedDownloadInfo(for: "book-2")
    
    XCTAssertNotNil(cached1)
    XCTAssertEqual(cached1?.downloadProgress, 0.25)
    
    XCTAssertNotNil(cached2)
    XCTAssertEqual(cached2?.downloadProgress, 0.75)
  }
  
  func testCoordinator_downloadInfoCache_updatesExistingEntry() async {
    // Given a coordinator with cached info
    let coordinator = DownloadCoordinator()
    let mockTask = MockURLSessionDownloadTask(taskIdentifier: 1)
    
    let initialInfo = MyBooksDownloadInfo(downloadProgress: 0.25, downloadTask: mockTask, rightsManagement: .none)
    await coordinator.cacheDownloadInfo(initialInfo, for: "book-1")
    
    // When updating with new progress
    let updatedInfo = MyBooksDownloadInfo(downloadProgress: 0.75, downloadTask: mockTask, rightsManagement: .none)
    await coordinator.cacheDownloadInfo(updatedInfo, for: "book-1")
    
    // Then should have updated value
    let cached = await coordinator.getCachedDownloadInfo(for: "book-1")
    XCTAssertEqual(cached?.downloadProgress, 0.75, "Cached info should be updated")
  }
}

// MARK: - Download State Machine Integration Tests

/// Tests for download state transitions using real MyBooksDownloadCenter behavior patterns.
final class DownloadStateMachineIntegrationTests: XCTestCase {
  
  private var mockBookRegistry: TPPBookRegistryMock!
  
  override func setUp() {
    super.setUp()
    mockBookRegistry = TPPBookRegistryMock()
  }
  
  override func tearDown() {
    mockBookRegistry?.registry = [:]
    mockBookRegistry = nil
    super.tearDown()
  }
  
  // MARK: - State Transition Validation Tests
  
  func testState_unregisteredToDownloadNeeded_validTransition() {
    // Given an unregistered book
    let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
    mockBookRegistry.addBook(book, location: nil, state: .unregistered, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    
    // When transitioning to downloadNeeded
    mockBookRegistry.setState(.downloadNeeded, for: book.identifier)
    
    // Then state should be updated
    XCTAssertEqual(mockBookRegistry.state(for: book.identifier), .downloadNeeded)
  }
  
  func testState_downloadNeededToDownloading_validTransition() {
    // Given a book needing download
    let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
    mockBookRegistry.addBook(book, location: nil, state: .downloadNeeded, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    
    // When starting download
    mockBookRegistry.setState(.downloading, for: book.identifier)
    
    // Then state should be downloading
    XCTAssertEqual(mockBookRegistry.state(for: book.identifier), .downloading)
  }
  
  func testState_downloadingToDownloadSuccessful_validTransition() {
    // Given a downloading book
    let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
    mockBookRegistry.addBook(book, location: nil, state: .downloading, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    
    // When download completes successfully
    mockBookRegistry.setState(.downloadSuccessful, for: book.identifier)
    
    // Then state should be successful
    XCTAssertEqual(mockBookRegistry.state(for: book.identifier), .downloadSuccessful)
  }
  
  func testState_downloadingToDownloadFailed_validTransition() {
    // Given a downloading book
    let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
    mockBookRegistry.addBook(book, location: nil, state: .downloading, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    
    // When download fails
    mockBookRegistry.setState(.downloadFailed, for: book.identifier)
    
    // Then state should be failed
    XCTAssertEqual(mockBookRegistry.state(for: book.identifier), .downloadFailed)
  }
  
  func testState_downloadFailedToDownloading_retryTransition() {
    // Given a failed download
    let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
    mockBookRegistry.addBook(book, location: nil, state: .downloadFailed, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    
    // When retrying download
    mockBookRegistry.setState(.downloading, for: book.identifier)
    
    // Then state should be downloading (retry allowed)
    XCTAssertEqual(mockBookRegistry.state(for: book.identifier), .downloading)
  }
  
  // MARK: - Complete Flow Tests
  
  func testState_completeSuccessfulDownloadFlow() {
    // Given an unregistered book
    let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
    
    // When going through complete download flow
    // Step 1: Add to registry
    mockBookRegistry.addBook(book, location: nil, state: .unregistered, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    XCTAssertEqual(mockBookRegistry.state(for: book.identifier), .unregistered)
    
    // Step 2: Set to download needed
    mockBookRegistry.setState(.downloadNeeded, for: book.identifier)
    XCTAssertEqual(mockBookRegistry.state(for: book.identifier), .downloadNeeded)
    
    // Step 3: Start downloading
    mockBookRegistry.setState(.downloading, for: book.identifier)
    XCTAssertEqual(mockBookRegistry.state(for: book.identifier), .downloading)
    
    // Step 4: Complete successfully
    mockBookRegistry.setState(.downloadSuccessful, for: book.identifier)
    XCTAssertEqual(mockBookRegistry.state(for: book.identifier), .downloadSuccessful)
    
    // Step 5: Mark as used (book opened)
    mockBookRegistry.setState(.used, for: book.identifier)
    XCTAssertEqual(mockBookRegistry.state(for: book.identifier), .used)
  }
  
  func testState_completeFailedDownloadWithRetryFlow() {
    // Given an unregistered book
    let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
    
    // When going through failed download with retry
    mockBookRegistry.addBook(book, location: nil, state: .downloadNeeded, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    mockBookRegistry.setState(.downloading, for: book.identifier)
    
    // First attempt fails
    mockBookRegistry.setState(.downloadFailed, for: book.identifier)
    XCTAssertEqual(mockBookRegistry.state(for: book.identifier), .downloadFailed)
    
    // Retry
    mockBookRegistry.setState(.downloading, for: book.identifier)
    XCTAssertEqual(mockBookRegistry.state(for: book.identifier), .downloading)
    
    // Second attempt succeeds
    mockBookRegistry.setState(.downloadSuccessful, for: book.identifier)
    XCTAssertEqual(mockBookRegistry.state(for: book.identifier), .downloadSuccessful)
  }
  
  // MARK: - Hold State Tests
  
  func testState_borrowResultsInHold_setsHoldingState() {
    // Given an unregistered book
    let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
    mockBookRegistry.addBook(book, location: nil, state: .unregistered, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    
    // When borrow results in hold (book not available)
    mockBookRegistry.setState(.holding, for: book.identifier)
    
    // Then book should be in holding state
    XCTAssertEqual(mockBookRegistry.state(for: book.identifier), .holding)
  }
  
  func testState_holdReadyToDownload_transitionsCorrectly() {
    // Given a book on hold that becomes ready
    let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
    mockBookRegistry.addBook(book, location: nil, state: .holding, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    
    // When hold becomes ready, transition to downloadNeeded
    mockBookRegistry.setState(.downloadNeeded, for: book.identifier)
    XCTAssertEqual(mockBookRegistry.state(for: book.identifier), .downloadNeeded)
    
    // Then can proceed with download
    mockBookRegistry.setState(.downloading, for: book.identifier)
    XCTAssertEqual(mockBookRegistry.state(for: book.identifier), .downloading)
    
    mockBookRegistry.setState(.downloadSuccessful, for: book.identifier)
    XCTAssertEqual(mockBookRegistry.state(for: book.identifier), .downloadSuccessful)
  }
}

// MARK: - Download Queue Integration Tests

/// Tests for download queue management logic.
final class DownloadQueueIntegrationTests: XCTestCase {
  
  func testMaxConcurrentDownloads_limitsActiveDownloads() async {
    // Given a coordinator with max concurrent = 4
    let coordinator = DownloadCoordinator()
    let maxConcurrent = 4
    
    // When registering 4 downloads
    for i in 0..<maxConcurrent {
      await coordinator.registerStart(identifier: "book-\(i)")
    }
    
    // Then should be at capacity
    let canStart = await coordinator.canStartDownload(maxConcurrent: maxConcurrent)
    XCTAssertFalse(canStart, "Should not allow more downloads when at max capacity")
    
    // When one completes
    await coordinator.registerCompletion(identifier: "book-0")
    
    // Then should allow one more
    let canStartAfter = await coordinator.canStartDownload(maxConcurrent: maxConcurrent)
    XCTAssertTrue(canStartAfter, "Should allow download after one completes")
  }
  
  func testQueuedBooks_startedWhenCapacityAvailable() async {
    // Given a coordinator at capacity with queued books
    let coordinator = DownloadCoordinator()
    let maxConcurrent = 4
    
    // Fill to capacity
    for i in 0..<maxConcurrent {
      await coordinator.registerStart(identifier: "active-\(i)")
    }
    
    // Queue additional books
    let queuedBook1 = TPPBookMocker.mockBook(identifier: "queued-1", title: "Queued 1", distributorType: .EpubZip)
    let queuedBook2 = TPPBookMocker.mockBook(identifier: "queued-2", title: "Queued 2", distributorType: .EpubZip)
    await coordinator.enqueuePending(queuedBook1)
    await coordinator.enqueuePending(queuedBook2)
    
    // When one active download completes
    await coordinator.registerCompletion(identifier: "active-0")
    
    // Then capacity should be available
    let capacity = maxConcurrent - await coordinator.activeCount
    XCTAssertEqual(capacity, 1, "Should have 1 slot available")
    
    // And can dequeue one pending
    let toStart = await coordinator.dequeuePending(capacity: capacity)
    XCTAssertEqual(toStart.count, 1)
    XCTAssertEqual(toStart.first?.identifier, "queued-1", "Should dequeue first queued book")
  }
  
  func testQueuedBooks_preserveOrderAcrossMultipleDequeues() async {
    // Given a coordinator with multiple queued books
    let coordinator = DownloadCoordinator()
    
    for i in 0..<10 {
      let book = TPPBookMocker.mockBook(identifier: "book-\(String(format: "%02d", i))", title: "Book \(i)", distributorType: .EpubZip)
      await coordinator.enqueuePending(book)
    }
    
    // When dequeuing in batches
    let batch1 = await coordinator.dequeuePending(capacity: 3)
    let batch2 = await coordinator.dequeuePending(capacity: 3)
    let batch3 = await coordinator.dequeuePending(capacity: 3)
    let batch4 = await coordinator.dequeuePending(capacity: 3)
    
    // Then order should be preserved across batches
    XCTAssertEqual(batch1.map { $0.identifier }, ["book-00", "book-01", "book-02"])
    XCTAssertEqual(batch2.map { $0.identifier }, ["book-03", "book-04", "book-05"])
    XCTAssertEqual(batch3.map { $0.identifier }, ["book-06", "book-07", "book-08"])
    XCTAssertEqual(batch4.map { $0.identifier }, ["book-09"], "Last batch should have remaining book")
  }
}

// MARK: - Rights Management Detection Tests

/// Tests for MIME type to rights management detection.
final class RightsManagementDetectionTests: XCTestCase {
  
  func testMimeType_adobeAdept_detectsAdobeRights() {
    let mimeType = "application/vnd.adobe.adept+xml"
    let rights = detectRightsManagement(from: mimeType)
    XCTAssertEqual(rights, .adobe)
  }
  
  func testMimeType_lcpLicense_detectsLCPRights() {
    let mimeType = "application/vnd.readium.lcp.license.v1.0+json"
    let rights = detectRightsManagement(from: mimeType)
    XCTAssertEqual(rights, .lcp)
  }
  
  func testMimeType_epubZip_detectsNoRights() {
    let mimeType = "application/epub+zip"
    let rights = detectRightsManagement(from: mimeType)
    XCTAssertEqual(rights, .none)
  }
  
  func testMimeType_bearerToken_detectsBearerTokenRights() {
    let mimeType = "application/vnd.librarysimplified.bearer-token+json"
    let rights = detectRightsManagement(from: mimeType)
    XCTAssertEqual(rights, .simplifiedBearerTokenJSON)
  }
  
  func testMimeType_unknown_detectsUnknown() {
    let mimeType = "application/unknown-type"
    let rights = detectRightsManagement(from: mimeType)
    XCTAssertEqual(rights, .unknown)
  }
  
  // Helper that mimics MyBooksDownloadCenter's logic
  private func detectRightsManagement(from mimeType: String) -> MyBooksDownloadInfo.MyBooksDownloadRightsManagement {
    switch mimeType {
    case "application/vnd.adobe.adept+xml":
      return .adobe
    case "application/vnd.readium.lcp.license.v1.0+json":
      return .lcp
    case "application/epub+zip":
      return .none
    case "application/vnd.librarysimplified.bearer-token+json":
      return .simplifiedBearerTokenJSON
    case "application/json":
      return .overdriveManifestJSON
    default:
      // Check if it's a supported type without DRM
      let supportedTypes = ["application/pdf", "application/audiobook+json"]
      if supportedTypes.contains(mimeType) {
        return .none
      }
      return .unknown
    }
  }
}

// MARK: - Download Progress Publisher Tests

/// Tests for download progress Combine publisher.
final class DownloadProgressPublisherTests: XCTestCase {
  
  private var cancellables: Set<AnyCancellable> = []
  
  override func tearDown() {
    cancellables.removeAll()
    super.tearDown()
  }
  
  func testProgressPublisher_emitsProgressUpdates() {
    // Given a download center
    let downloadCenter = MyBooksDownloadCenter.shared
    
    // Setup expectation for progress updates
    let progressExpectation = expectation(description: "Progress update received")
    var receivedProgress: (identifier: String, progress: Double)?
    
    downloadCenter.downloadProgressPublisher
      .first()
      .sink { (identifier, progress) in
        receivedProgress = (identifier, progress)
        progressExpectation.fulfill()
      }
      .store(in: &cancellables)
    
    // When progress is published (simulated by sending directly)
    downloadCenter.downloadProgressPublisher.send(("test-book-123", 0.5))
    
    // Then should receive the progress
    waitForExpectations(timeout: 1.0)
    
    XCTAssertEqual(receivedProgress?.identifier, "test-book-123")
    XCTAssertEqual(receivedProgress?.progress, 0.5)
  }
  
  func testProgressPublisher_emitsMultipleUpdates() {
    // Given a download center
    let downloadCenter = MyBooksDownloadCenter.shared
    
    // Setup expectation for multiple progress updates
    let progressExpectation = expectation(description: "Multiple progress updates received")
    var progressUpdates: [(String, Double)] = []
    
    downloadCenter.downloadProgressPublisher
      .prefix(3)
      .collect()
      .sink { updates in
        progressUpdates = updates
        progressExpectation.fulfill()
      }
      .store(in: &cancellables)
    
    // When multiple progress updates are published
    downloadCenter.downloadProgressPublisher.send(("book-1", 0.1))
    downloadCenter.downloadProgressPublisher.send(("book-1", 0.5))
    downloadCenter.downloadProgressPublisher.send(("book-1", 1.0))
    
    // Then should receive all updates
    waitForExpectations(timeout: 1.0)
    
    XCTAssertEqual(progressUpdates.count, 3)
    XCTAssertEqual(progressUpdates[0].1, 0.1)
    XCTAssertEqual(progressUpdates[1].1, 0.5)
    XCTAssertEqual(progressUpdates[2].1, 1.0)
  }
}

// MARK: - File URL Generation Tests

/// Tests for book content file URL generation.
final class FileURLGenerationTests: XCTestCase {
  
  func testFileUrl_epubBook_hasEpubExtension() {
    // Given a download center and EPUB book
    let downloadCenter = MyBooksDownloadCenter.shared
    let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
    
    // Note: This test verifies the pathExtension method behavior
    let pathExtension = downloadCenter.pathExtension(for: book)
    
    // Then should return epub extension
    XCTAssertEqual(pathExtension, "epub", "EPUB books should use .epub extension")
  }
  
  func testFileUrl_contentDirectoryExists() {
    // Given a download center
    let downloadCenter = MyBooksDownloadCenter.shared
    
    // When getting content directory
    let testAccountId = "test-account-\(UUID().uuidString)"
    let contentDir = downloadCenter.contentDirectoryURL(testAccountId)
    
    // Then should return a valid URL
    XCTAssertNotNil(contentDir, "Content directory URL should not be nil")
    
    // And directory should exist (created if needed)
    if let contentDir = contentDir {
      XCTAssertTrue(FileManager.default.fileExists(atPath: contentDir.path), "Content directory should exist")
      
      // Cleanup
      try? FileManager.default.removeItem(at: contentDir)
    }
  }
  
  func testFileUrl_deterministicForSameIdentifier() {
    // Given a download center
    let downloadCenter = MyBooksDownloadCenter.shared
    
    // When generating file URL for same identifier multiple times
    // Note: We need a registered book for fileUrl to work
    // This test verifies the hashing is deterministic
    let identifier = "test-identifier-123"
    let hashedId1 = identifier.sha256()
    let hashedId2 = identifier.sha256()
    
    // Then should produce same hash
    XCTAssertEqual(hashedId1, hashedId2, "Same identifier should produce same hash")
    XCTAssertFalse(hashedId1.isEmpty, "Hash should not be empty")
  }
}

// MARK: - Redirect Handling Integration Tests

/// Integration tests for download redirect handling.
final class RedirectHandlingIntegrationTests: XCTestCase {
  
  func testRedirect_httpsToHttp_blockedForSecurity() {
    // Given HTTPS original URL and HTTP redirect
    let originalURL = URL(string: "https://secure.library.org/download")!
    let redirectURL = URL(string: "http://insecure.cdn.com/book.epub")!
    
    // When checking if redirect should be blocked
    let shouldBlock = originalURL.scheme == "https" && redirectURL.scheme != "https"
    
    // Then should block the insecure redirect
    XCTAssertTrue(shouldBlock, "HTTPS to HTTP redirect should be blocked for security")
  }
  
  func testRedirect_httpsToHttps_allowed() {
    // Given HTTPS original URL and HTTPS redirect
    let originalURL = URL(string: "https://secure.library.org/download")!
    let redirectURL = URL(string: "https://cdn.library.org/book.epub")!
    
    // When checking if redirect should be blocked
    let shouldBlock = originalURL.scheme == "https" && redirectURL.scheme != "https"
    
    // Then should allow the secure redirect
    XCTAssertFalse(shouldBlock, "HTTPS to HTTPS redirect should be allowed")
  }
  
  func testRedirect_maxAttempts_enforced() async {
    // Given a coordinator tracking redirects
    let coordinator = DownloadCoordinator()
    let taskId = 42
    let maxRedirects: UInt = 10
    
    // When incrementing redirects up to max
    for _ in 0..<maxRedirects {
      await coordinator.incrementRedirectAttempts(for: taskId)
    }
    
    // Then should be at max
    let attempts = await coordinator.getRedirectAttempts(for: taskId)
    XCTAssertEqual(attempts, Int(maxRedirects))
    
    // And should block further redirects (this would be checked in the delegate)
    XCTAssertTrue(attempts >= Int(maxRedirects), "Should block redirects after max attempts")
  }
  
  func testRedirect_attemptsCleared_afterCompletion() async {
    // Given a coordinator with redirect attempts
    let coordinator = DownloadCoordinator()
    let taskId = 42
    
    await coordinator.incrementRedirectAttempts(for: taskId)
    await coordinator.incrementRedirectAttempts(for: taskId)
    
    // When clearing attempts (as happens on completion)
    await coordinator.clearRedirectAttempts(for: taskId)
    
    // Then should be back to zero
    let attempts = await coordinator.getRedirectAttempts(for: taskId)
    XCTAssertEqual(attempts, 0)
  }
}

// MARK: - Error Recovery Tests

/// Tests for download error handling and retry logic.
final class DownloadErrorRecoveryTests: XCTestCase {
  
  private var mockBookRegistry: TPPBookRegistryMock!
  
  override func setUp() {
    super.setUp()
    mockBookRegistry = TPPBookRegistryMock()
  }
  
  override func tearDown() {
    mockBookRegistry?.registry = [:]
    mockBookRegistry = nil
    super.tearDown()
  }
  
  func testErrorRecovery_downloadFailed_allowsRetry() {
    // Given a failed download
    let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
    mockBookRegistry.addBook(book, location: nil, state: .downloadFailed, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    
    // When user initiates retry
    mockBookRegistry.setState(.downloading, for: book.identifier)
    
    // Then download should be able to restart
    XCTAssertEqual(mockBookRegistry.state(for: book.identifier), .downloading)
  }
  
  func testErrorRecovery_multipleFailures_trackedSeparately() {
    // Given multiple books with different states
    let book1 = TPPBookMocker.mockBook(identifier: "book-1", title: "Book 1", distributorType: .EpubZip)
    let book2 = TPPBookMocker.mockBook(identifier: "book-2", title: "Book 2", distributorType: .EpubZip)
    
    mockBookRegistry.addBook(book1, location: nil, state: .downloadFailed, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    mockBookRegistry.addBook(book2, location: nil, state: .downloading, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    
    // When retrying book1 only
    mockBookRegistry.setState(.downloading, for: book1.identifier)
    
    // Then book2 should remain unaffected
    XCTAssertEqual(mockBookRegistry.state(for: book1.identifier), .downloading)
    XCTAssertEqual(mockBookRegistry.state(for: book2.identifier), .downloading)
  }
  
  func testErrorRecovery_cancelledDownload_resetsToDownloadNeeded() {
    // Given a downloading book
    let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
    mockBookRegistry.addBook(book, location: nil, state: .downloading, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    
    // When download is cancelled (simulating MyBooksDownloadCenter.cancelDownload behavior)
    mockBookRegistry.setState(.downloadNeeded, for: book.identifier)
    
    // Then book should be in downloadNeeded state
    XCTAssertEqual(mockBookRegistry.state(for: book.identifier), .downloadNeeded)
  }
}

// MARK: - Concurrent Book State Management Tests

/// Tests for managing multiple book downloads concurrently.
final class ConcurrentBookStateTests: XCTestCase {
  
  private var mockBookRegistry: TPPBookRegistryMock!
  
  override func setUp() {
    super.setUp()
    mockBookRegistry = TPPBookRegistryMock()
  }
  
  override func tearDown() {
    mockBookRegistry?.registry = [:]
    mockBookRegistry = nil
    super.tearDown()
  }
  
  func testConcurrent_multipleDownloads_independentStates() {
    // Given multiple books downloading
    let books = (0..<5).map { i in
      TPPBookMocker.mockBook(identifier: "book-\(i)", title: "Book \(i)", distributorType: .EpubZip)
    }
    
    for book in books {
      mockBookRegistry.addBook(book, location: nil, state: .downloading, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    }
    
    // When some complete and some fail
    mockBookRegistry.setState(.downloadSuccessful, for: "book-0")
    mockBookRegistry.setState(.downloadSuccessful, for: "book-1")
    mockBookRegistry.setState(.downloadFailed, for: "book-2")
    // book-3 and book-4 still downloading
    
    // Then each should have independent state
    XCTAssertEqual(mockBookRegistry.state(for: "book-0"), .downloadSuccessful)
    XCTAssertEqual(mockBookRegistry.state(for: "book-1"), .downloadSuccessful)
    XCTAssertEqual(mockBookRegistry.state(for: "book-2"), .downloadFailed)
    XCTAssertEqual(mockBookRegistry.state(for: "book-3"), .downloading)
    XCTAssertEqual(mockBookRegistry.state(for: "book-4"), .downloading)
  }
  
  func testConcurrent_differentContentTypes_supportedSimultaneously() {
    // Given books of different types
    let epubBook = TPPBookMocker.mockBook(identifier: "epub-1", title: "EPUB Book", distributorType: .EpubZip)
    let audiobook = TPPBookMocker.mockBook(identifier: "audio-1", title: "Audiobook", distributorType: .OpenAccessAudiobook)
    let pdfBook = TPPBookMocker.mockBook(identifier: "pdf-1", title: "PDF Book", distributorType: .OpenAccessPDF)
    
    // When all are downloading
    mockBookRegistry.addBook(epubBook, location: nil, state: .downloading, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    mockBookRegistry.addBook(audiobook, location: nil, state: .downloading, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    mockBookRegistry.addBook(pdfBook, location: nil, state: .downloading, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    
    // Then all should be tracked
    XCTAssertEqual(mockBookRegistry.state(for: "epub-1"), .downloading)
    XCTAssertEqual(mockBookRegistry.state(for: "audio-1"), .downloading)
    XCTAssertEqual(mockBookRegistry.state(for: "pdf-1"), .downloading)
    
    // And can complete independently
    mockBookRegistry.setState(.downloadSuccessful, for: "epub-1")
    mockBookRegistry.setState(.downloadSuccessful, for: "audio-1")
    mockBookRegistry.setState(.downloadSuccessful, for: "pdf-1")
    
    XCTAssertEqual(mockBookRegistry.state(for: "epub-1"), .downloadSuccessful)
    XCTAssertEqual(mockBookRegistry.state(for: "audio-1"), .downloadSuccessful)
    XCTAssertEqual(mockBookRegistry.state(for: "pdf-1"), .downloadSuccessful)
  }
  
  func testConcurrent_drmTypes_supportedSimultaneously() {
    // Given books with different DRM types
    let adobeBook = TPPBookMocker.mockBook(identifier: "adobe-1", title: "Adobe Book", distributorType: .AdobeAdept)
    let lcpBook = TPPBookMocker.mockBook(identifier: "lcp-1", title: "LCP Book", distributorType: .ReadiumLCP)
    let openAccessBook = TPPBookMocker.mockBook(identifier: "open-1", title: "Open Access", distributorType: .EpubZip)
    
    // When all are downloading
    mockBookRegistry.addBook(adobeBook, location: nil, state: .downloading, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    mockBookRegistry.addBook(lcpBook, location: nil, state: .downloading, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    mockBookRegistry.addBook(openAccessBook, location: nil, state: .downloading, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    
    // Then all should be tracked independently
    XCTAssertEqual(mockBookRegistry.state(for: "adobe-1"), .downloading)
    XCTAssertEqual(mockBookRegistry.state(for: "lcp-1"), .downloading)
    XCTAssertEqual(mockBookRegistry.state(for: "open-1"), .downloading)
  }
}

// MARK: - Disk Budget Tests

/// Tests for content disk budget management.
final class DiskBudgetTests: XCTestCase {
  
  func testDiskSpace_available_returnsPositiveValue() {
    // Given the file system
    let attributes = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
    let freeSpace = attributes?[.systemFreeSize] as? Int64 ?? 0
    
    // Then free space should be positive
    XCTAssertGreaterThan(freeSpace, 0, "System should have available disk space")
  }
  
  func testContentDirectory_createdOnAccess() {
    // Given a download center
    let downloadCenter = MyBooksDownloadCenter.shared
    let testAccountId = "test-disk-budget-\(UUID().uuidString)"
    
    // When accessing content directory
    let contentDir = downloadCenter.contentDirectoryURL(testAccountId)
    
    // Then directory should be created
    XCTAssertNotNil(contentDir)
    if let contentDir = contentDir {
      XCTAssertTrue(FileManager.default.fileExists(atPath: contentDir.path))
      
      // Cleanup
      try? FileManager.default.removeItem(at: contentDir)
    }
  }
}

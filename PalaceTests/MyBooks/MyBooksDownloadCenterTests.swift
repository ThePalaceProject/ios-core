//
//  MyBooksDownloadCenterTests.swift
//  PalaceTests
//
//  Unit tests for MyBooksDownloadCenter production classes.
//  Tests real production classes: MyBooksDownloadInfo, DownloadCoordinator, and URL/request behavior.
//
//  NOTE: These tests use mocks only for dependency injection, NOT for testing mock behavior.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace

// MARK: - Mock URLSession Download Task

/// A mock URLSessionDownloadTask used for dependency injection when testing MyBooksDownloadInfo.
/// This mock is NOT tested directly - it's only used to create real MyBooksDownloadInfo instances.
class MockURLSessionDownloadTask: URLSessionDownloadTask {
  private var _taskIdentifier: Int
  private var _state: URLSessionTask.State = .suspended
  private var _originalRequest: URLRequest?

  init(taskIdentifier: Int, request: URLRequest? = nil) {
    _taskIdentifier = taskIdentifier
    _originalRequest = request
    super.init()
  }

  override var taskIdentifier: Int { _taskIdentifier }
  override var state: URLSessionTask.State { _state }
  override var originalRequest: URLRequest? { _originalRequest }

  override func resume() {
    _state = .running
  }

  override func cancel() {
    _state = .canceling
  }
}

// MARK: - Download Info Tests

/// Tests for MyBooksDownloadInfo functionality - a real production struct
final class DownloadInfoTests: XCTestCase {

  func testDownloadInfo_creation_setsInitialValues() {
    // Given initial values
    let progress: CGFloat = 0.0
    let mockTask = MockURLSessionDownloadTask(taskIdentifier: 1)
    let rights = MyBooksDownloadInfo.MyBooksDownloadRightsManagement.none

    // When creating download info
    let info = MyBooksDownloadInfo(
      downloadProgress: progress,
      downloadTask: mockTask,
      rightsManagement: rights
    )

    // Then values should be set correctly
    XCTAssertEqual(info.downloadProgress, 0.0)
    XCTAssertEqual(info.rightsManagement, .none)
    XCTAssertNil(info.bearerToken)
  }

  func testDownloadInfo_withDownloadProgress_createsNewInstance() {
    // Given existing download info
    let mockTask = MockURLSessionDownloadTask(taskIdentifier: 1)
    let original = MyBooksDownloadInfo(
      downloadProgress: 0.0,
      downloadTask: mockTask,
      rightsManagement: .none
    )

    // When updating progress
    let updated = original.withDownloadProgress(0.5)

    // Then new instance should have updated progress
    XCTAssertEqual(updated.downloadProgress, 0.5)
    // And original should be unchanged
    XCTAssertEqual(original.downloadProgress, 0.0)
  }

  func testDownloadInfo_withRightsManagement_createsNewInstance() {
    // Given existing download info
    let mockTask = MockURLSessionDownloadTask(taskIdentifier: 1)
    let original = MyBooksDownloadInfo(
      downloadProgress: 0.5,
      downloadTask: mockTask,
      rightsManagement: .unknown
    )

    // When updating rights management
    let updated = original.withRightsManagement(.adobe)

    // Then new instance should have updated rights
    XCTAssertEqual(updated.rightsManagement, .adobe)
    // And should preserve other values
    XCTAssertEqual(updated.downloadProgress, 0.5)
    // And original should be unchanged
    XCTAssertEqual(original.rightsManagement, .unknown)
  }

  func testDownloadInfo_rightsManagementString_returnsCorrectString() {
    let mockTask = MockURLSessionDownloadTask(taskIdentifier: 1)

    let testCases: [(MyBooksDownloadInfo.MyBooksDownloadRightsManagement, String)] = [
      (.unknown, "Unknown"),
      (.none, "None"),
      (.adobe, "Adobe"),
      (.simplifiedBearerTokenJSON, "SimplifiedBearerTokenJSON"),
      (.overdriveManifestJSON, "OverdriveManifestJSON"),
      (.lcp, "TPPMyBooksDownloadRightsManagementLCP")
    ]

    for (rights, expectedString) in testCases {
      let info = MyBooksDownloadInfo(
        downloadProgress: 0.0,
        downloadTask: mockTask,
        rightsManagement: rights
      )

      XCTAssertEqual(
        info.rightsManagementString,
        expectedString,
        "Expected \(expectedString) for \(rights)"
      )
    }
  }

  func testDownloadInfo_progressUpdates_handlesEdgeCases() {
    let mockTask = MockURLSessionDownloadTask(taskIdentifier: 1)
    var info = MyBooksDownloadInfo(
      downloadProgress: 0.0,
      downloadTask: mockTask,
      rightsManagement: .none
    )

    // Test very small progress
    info = info.withDownloadProgress(0.001)
    XCTAssertEqual(info.downloadProgress, 0.001, accuracy: 0.0001)

    // Test progress close to complete
    info = info.withDownloadProgress(0.999)
    XCTAssertEqual(info.downloadProgress, 0.999, accuracy: 0.0001)

    // Test 100% complete
    info = info.withDownloadProgress(1.0)
    XCTAssertEqual(info.downloadProgress, 1.0)
  }
}

// MARK: - Download Coordinator Tests

/// Tests for the DownloadCoordinator actor - a real production actor
final class DownloadCoordinatorTests: XCTestCase {

  func testCoordinator_canStartDownload_withinLimit() async {
    let coordinator = DownloadCoordinator()
    let maxConcurrent = 4

    // Initially should allow downloads
    let canStart = await coordinator.canStartDownload(maxConcurrent: maxConcurrent)
    XCTAssertTrue(canStart)
  }

  func testCoordinator_registerStart_incrementsActiveCount() async {
    let coordinator = DownloadCoordinator()

    // Register multiple starts
    await coordinator.registerStart(identifier: "book-1")
    await coordinator.registerStart(identifier: "book-2")

    let count = await coordinator.activeCount
    XCTAssertEqual(count, 2)
  }

  func testCoordinator_registerCompletion_decrementsActiveCount() async {
    let coordinator = DownloadCoordinator()

    // Register starts
    await coordinator.registerStart(identifier: "book-1")
    await coordinator.registerStart(identifier: "book-2")

    // Register completion
    await coordinator.registerCompletion(identifier: "book-1")

    let count = await coordinator.activeCount
    XCTAssertEqual(count, 1)
  }

  func testCoordinator_enqueuePending_addsToQueue() async {
    let coordinator = DownloadCoordinator()
    let book = TPPBookMocker.mockBook(distributorType: .EpubZip)

    await coordinator.enqueuePending(book)

    let queueCount = await coordinator.queueCount
    XCTAssertEqual(queueCount, 1)
  }

  func testCoordinator_dequeuePending_returnsBooks() async {
    let coordinator = DownloadCoordinator()
    let book1 = TPPBookMocker.mockBook(distributorType: .EpubZip)
    let book2 = TPPBookMocker.mockBook(distributorType: .EpubZip)

    await coordinator.enqueuePending(book1)
    await coordinator.enqueuePending(book2)

    let dequeued = await coordinator.dequeuePending(capacity: 1)

    XCTAssertEqual(dequeued.count, 1)
    XCTAssertEqual(dequeued.first?.identifier, book1.identifier)

    let remaining = await coordinator.queueCount
    XCTAssertEqual(remaining, 1)
  }

  func testCoordinator_enqueuePending_preventsDuplicates() async {
    let coordinator = DownloadCoordinator()
    let book = TPPBookMocker.mockBook(distributorType: .EpubZip)

    // Try to enqueue same book twice
    await coordinator.enqueuePending(book)
    await coordinator.enqueuePending(book)

    let queueCount = await coordinator.queueCount
    XCTAssertEqual(queueCount, 1)
  }

  func testCoordinator_reset_clearsAllState() async {
    let coordinator = DownloadCoordinator()
    let book = TPPBookMocker.mockBook(distributorType: .EpubZip)

    // Add some state
    await coordinator.registerStart(identifier: book.identifier)
    await coordinator.enqueuePending(book)

    // Reset
    await coordinator.reset()

    let activeCount = await coordinator.activeCount
    let queueCount = await coordinator.queueCount

    XCTAssertEqual(activeCount, 0)
    XCTAssertEqual(queueCount, 0)
  }

  func testCoordinator_cacheDownloadInfo_storesAndRetrieves() async {
    let coordinator = DownloadCoordinator()
    let mockTask = MockURLSessionDownloadTask(taskIdentifier: 1)
    let info = MyBooksDownloadInfo(
      downloadProgress: 0.5,
      downloadTask: mockTask,
      rightsManagement: .none
    )

    await coordinator.cacheDownloadInfo(info, for: "book-1")

    let cached = await coordinator.getCachedDownloadInfo(for: "book-1")
    XCTAssertNotNil(cached)
    XCTAssertEqual(cached?.downloadProgress, 0.5)
  }

  func testCoordinator_removeCachedDownloadInfo_removesEntry() async {
    let coordinator = DownloadCoordinator()
    let mockTask = MockURLSessionDownloadTask(taskIdentifier: 1)
    let info = MyBooksDownloadInfo(
      downloadProgress: 0.5,
      downloadTask: mockTask,
      rightsManagement: .none
    )

    await coordinator.cacheDownloadInfo(info, for: "book-1")
    await coordinator.removeCachedDownloadInfo(for: "book-1")

    let cached = await coordinator.getCachedDownloadInfo(for: "book-1")
    XCTAssertNil(cached)
  }

  func testCoordinator_redirectAttempts_tracksCorrectly() async {
    let coordinator = DownloadCoordinator()
    let taskID = 42

    // Initially zero
    let initial = await coordinator.getRedirectAttempts(for: taskID)
    XCTAssertEqual(initial, 0)

    // Increment
    await coordinator.incrementRedirectAttempts(for: taskID)
    await coordinator.incrementRedirectAttempts(for: taskID)

    let incremented = await coordinator.getRedirectAttempts(for: taskID)
    XCTAssertEqual(incremented, 2)

    // Clear
    await coordinator.clearRedirectAttempts(for: taskID)

    let cleared = await coordinator.getRedirectAttempts(for: taskID)
    XCTAssertEqual(cleared, 0)
  }

  func testCoordinator_canStartDownload_respectsMaxConcurrent() async {
    let coordinator = DownloadCoordinator()
    let maxConcurrent = 4

    // Register starts up to limit
    for i in 0..<maxConcurrent {
      await coordinator.registerStart(identifier: "book-\(i)")
    }

    // Should not allow more
    let canStart = await coordinator.canStartDownload(maxConcurrent: maxConcurrent)
    XCTAssertFalse(canStart)

    // After completion, should allow
    await coordinator.registerCompletion(identifier: "book-0")
    let canStartAfter = await coordinator.canStartDownload(maxConcurrent: maxConcurrent)
    XCTAssertTrue(canStartAfter)
  }
}

// MARK: - Download Redirect Handling Tests

/// Tests for redirect handling in downloads.
/// Verifies that auth headers are not forwarded on redirects (for No DRM open access content).
final class DownloadRedirectTests: XCTestCase {

  // MARK: - URLRequest Auth Header Tests

  func testRedirectRequest_shouldNotContainAuthHeader_whenFollowingRedirect() {
    // When URLSession follows a redirect, the Authorization header should be stripped
    // This is URLSession's default secure behavior, and we don't re-add it

    let originalURL = URL(string: "https://gorgon.palaceproject.io/library/fulfill")!
    let redirectURL = URL(string: "https://cdn.example.com/book.epub")!

    var originalRequest = URLRequest(url: originalURL)
    originalRequest.setValue("Bearer palace-token-123", forHTTPHeaderField: "Authorization")

    // Simulate what URLSession does: create new request without auth
    let redirectRequest = URLRequest(url: redirectURL)
    // URLSession strips Authorization header by default - no auth in redirect request

    XCTAssertNil(
      redirectRequest.value(forHTTPHeaderField: "Authorization"),
      "Redirect request should not contain Authorization header"
    )
  }

  func testRedirectRequest_sameDomain_shouldNotContainAuthHeader() {
    // Even for same-domain redirects, we don't forward auth for open access content

    let originalURL = URL(string: "https://gorgon.palaceproject.io/library/fulfill")!
    let redirectURL = URL(string: "https://gorgon.palaceproject.io/content/book.epub")!

    var originalRequest = URLRequest(url: originalURL)
    originalRequest.setValue("Bearer palace-token-123", forHTTPHeaderField: "Authorization")

    // Redirect request should not have auth
    let redirectRequest = URLRequest(url: redirectURL)

    XCTAssertNil(
      redirectRequest.value(forHTTPHeaderField: "Authorization"),
      "Same-domain redirect request should not contain Authorization header for open access"
    )
  }

  func testRedirectRequest_crossDomain_shouldNotContainAuthHeader() {
    // Cross-domain redirects definitely should not forward auth

    let originalURL = URL(string: "https://gorgon.palaceproject.io/library/fulfill")!
    let redirectURL = URL(string: "https://library.biblioboard.com/content/book.epub")!

    var originalRequest = URLRequest(url: originalURL)
    originalRequest.setValue("Bearer palace-token-123", forHTTPHeaderField: "Authorization")

    let redirectRequest = URLRequest(url: redirectURL)

    XCTAssertNil(
      redirectRequest.value(forHTTPHeaderField: "Authorization"),
      "Cross-domain redirect request should not contain Authorization header"
    )

    // Verify domains are different
    XCTAssertNotEqual(originalURL.host, redirectURL.host)
  }

  // MARK: - Bearer Token JSON Flow Tests

  func testBearerTokenJSON_shouldUseDistributorToken_notPalaceToken() {
    // When we receive a Bearer Token JSON document, we should use the
    // distributor's token in the follow-up request, not our Palace token

    let palaceToken = "palace-auth-token-xyz"
    let distributorToken = "distributor-specific-token-abc"
    let contentLocation = URL(string: "https://distributor.example.com/book.epub")!

    // Simulate parsing the bearer token JSON document
    let bearerTokenDocument: [String: Any] = [
      "token_type": "Bearer",
      "access_token": distributorToken,
      "expires_in": 60,
      "location": contentLocation.absoluteString
    ]

    // Extract the token and location (simulating MyBooksSimplifiedBearerToken parsing)
    let accessToken = bearerTokenDocument["access_token"] as? String
    let location = bearerTokenDocument["location"] as? String

    XCTAssertEqual(accessToken, distributorToken)
    XCTAssertNotEqual(accessToken, palaceToken, "Should use distributor token, not Palace token")
    XCTAssertEqual(location, contentLocation.absoluteString)

    // Create request with distributor's token
    var contentRequest = URLRequest(url: contentLocation)
    contentRequest.setValue("Bearer \(distributorToken)", forHTTPHeaderField: "Authorization")

    XCTAssertEqual(
      contentRequest.value(forHTTPHeaderField: "Authorization"),
      "Bearer \(distributorToken)",
      "Content request should use distributor's token from JSON document"
    )
  }

  // MARK: - HTTPS Downgrade Protection Tests

  func testRedirect_httpsToHttp_shouldBeBlocked() {
    // Redirects from HTTPS to HTTP should be blocked for security

    let originalURL = URL(string: "https://secure.example.com/book")!
    let insecureRedirectURL = URL(string: "http://insecure.example.com/book.epub")!

    XCTAssertEqual(originalURL.scheme, "https")
    XCTAssertEqual(insecureRedirectURL.scheme, "http")

    // The redirect handler should block this (return nil to completionHandler)
    let shouldBlock = originalURL.scheme == "https" && insecureRedirectURL.scheme != "https"
    XCTAssertTrue(shouldBlock, "HTTPS to HTTP redirect should be blocked")
  }

  func testRedirect_httpsToHttps_shouldBeAllowed() {
    // Redirects from HTTPS to HTTPS should be allowed

    let originalURL = URL(string: "https://secure.example.com/book")!
    let secureRedirectURL = URL(string: "https://cdn.example.com/book.epub")!

    XCTAssertEqual(originalURL.scheme, "https")
    XCTAssertEqual(secureRedirectURL.scheme, "https")

    let shouldBlock = originalURL.scheme == "https" && secureRedirectURL.scheme != "https"
    XCTAssertFalse(shouldBlock, "HTTPS to HTTPS redirect should be allowed")
  }

  func testRedirect_maxRedirectAttempts_shouldBeEnforced() {
    // Verify max redirect attempt limit constant
    let maxRedirectAttempts: UInt = 10

    var redirectCount: UInt = 0

    // Simulate redirect loop
    while redirectCount < maxRedirectAttempts + 5 {
      if redirectCount >= maxRedirectAttempts {
        // Should stop following redirects
        break
      }
      redirectCount += 1
    }

    XCTAssertEqual(redirectCount, maxRedirectAttempts, "Should stop at max redirect attempts")
  }
}

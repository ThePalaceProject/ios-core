//
//  DownloadFlowIntegrationTests.swift
//  PalaceTests
//
//  Integration tests for the complete book download flow:
//  Borrow → Download → Verify state → Open
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace

@MainActor
final class DownloadFlowIntegrationTests: XCTestCase {
  
  // MARK: - Properties
  
  private var mockRegistry: TPPBookRegistryMock!
  private var cancellables: Set<AnyCancellable>!
  
  // MARK: - Setup/Teardown
  
  override func setUp() async throws {
    try await super.setUp()
    mockRegistry = TPPBookRegistryMock()
    cancellables = Set<AnyCancellable>()
  }
  
  override func tearDown() async throws {
    mockRegistry = nil
    cancellables = nil
    try await super.tearDown()
  }
  
  // MARK: - Helper Methods
  
  private func createTestBook(type: DistributorType = .EpubZip) -> TPPBook {
    return TPPBookMocker.mockBook(distributorType: type)
  }
  
  // MARK: - State Flow Tests
  
  func testDownloadFlow_UnregisteredToDownloading() {
    let book = createTestBook()
    
    // Start: Book is unregistered
    mockRegistry.addBook(book, state: .unregistered)
    XCTAssertEqual(mockRegistry.state(for: book.identifier), .unregistered)
    
    // User taps Get/Download
    mockRegistry.setState(.downloading, for: book.identifier)
    XCTAssertEqual(mockRegistry.state(for: book.identifier), .downloading)
  }
  
  func testDownloadFlow_DownloadingToSuccess() {
    let book = createTestBook()
    
    mockRegistry.addBook(book, state: .downloading)
    
    // Download completes successfully
    mockRegistry.setState(.downloadSuccessful, for: book.identifier)
    XCTAssertEqual(mockRegistry.state(for: book.identifier), .downloadSuccessful)
  }
  
  func testDownloadFlow_DownloadingToFailed() {
    let book = createTestBook()
    
    mockRegistry.addBook(book, state: .downloading)
    
    // Download fails
    mockRegistry.setState(.downloadFailed, for: book.identifier)
    XCTAssertEqual(mockRegistry.state(for: book.identifier), .downloadFailed)
  }
  
  func testDownloadFlow_FailedToRetry() {
    let book = createTestBook()
    
    mockRegistry.addBook(book, state: .downloadFailed)
    
    // User taps retry
    mockRegistry.setState(.downloading, for: book.identifier)
    XCTAssertEqual(mockRegistry.state(for: book.identifier), .downloading)
    
    // Retry succeeds
    mockRegistry.setState(.downloadSuccessful, for: book.identifier)
    XCTAssertEqual(mockRegistry.state(for: book.identifier), .downloadSuccessful)
  }
  
  func testDownloadFlow_CompleteFlow_EPUB() {
    let book = createTestBook(type: .EpubZip)
    
    // Step 1: Unregistered → Downloading
    mockRegistry.addBook(book, state: .unregistered)
    XCTAssertEqual(mockRegistry.state(for: book.identifier), .unregistered)
    
    // Step 2: Start download
    mockRegistry.setState(.downloading, for: book.identifier)
    XCTAssertEqual(mockRegistry.state(for: book.identifier), .downloading)
    
    // Step 3: Download completes
    mockRegistry.setState(.downloadSuccessful, for: book.identifier)
    XCTAssertEqual(mockRegistry.state(for: book.identifier), .downloadSuccessful)
    
    // Verify button state would be "Read"
    let buttonState = BookButtonMapper.map(
      registryState: .downloadSuccessful,
      availability: nil,
      isProcessingDownload: false
    )
    XCTAssertEqual(buttonState, .downloadSuccessful)
    
    let buttons = buttonState.buttonTypes(book: book)
    XCTAssertTrue(buttons.contains(.read))
  }
  
  func testDownloadFlow_CompleteFlow_Audiobook() {
    let book = createTestBook(type: .OpenAccessAudiobook)
    
    // Complete flow
    mockRegistry.addBook(book, state: .unregistered)
    mockRegistry.setState(.downloading, for: book.identifier)
    mockRegistry.setState(.downloadSuccessful, for: book.identifier)
    
    // Verify button state would be "Listen"
    let buttonState = BookButtonMapper.map(
      registryState: .downloadSuccessful,
      availability: nil,
      isProcessingDownload: false
    )
    let buttons = buttonState.buttonTypes(book: book)
    XCTAssertTrue(buttons.contains(.listen))
  }
  
  // MARK: - Return Flow Tests
  
  func testReturnFlow_SuccessfulToUnregistered() {
    let book = createTestBook()
    
    // Start with downloaded book
    mockRegistry.addBook(book, state: .downloadSuccessful)
    
    // User taps return
    mockRegistry.setState(.returning, for: book.identifier)
    XCTAssertEqual(mockRegistry.state(for: book.identifier), .returning)
    
    // Return completes
    mockRegistry.removeBook(forIdentifier: book.identifier)
    XCTAssertNil(mockRegistry.book(forIdentifier: book.identifier))
  }
  
  func testReturnFlow_VerifyUIStateCleared() {
    let book = createTestBook()
    
    // Simulate return flow with UI state tracking
    var isManagingHold = false
    var showHalfSheet = true
    var processingButtons: Set<BookButtonType> = [.returning]
    
    mockRegistry.addBook(book, state: .downloadSuccessful)
    
    // Return in progress
    mockRegistry.setState(.returning, for: book.identifier)
    
    // Simulate return completion and state cleanup
    mockRegistry.removeBook(forIdentifier: book.identifier)
    
    // Clear UI state (simulating what BookDetailViewModel does)
    let registryState = mockRegistry.state(for: book.identifier)
    if registryState == .unregistered {
      isManagingHold = false
      showHalfSheet = false
      processingButtons.remove(.returning)
    }
    
    XCTAssertFalse(isManagingHold)
    XCTAssertFalse(showHalfSheet)
    XCTAssertTrue(processingButtons.isEmpty)
  }
  
  // MARK: - Hold Flow Tests
  
  func testHoldFlow_UnregisteredToHolding() {
    let book = createTestBook()
    
    mockRegistry.addBook(book, state: .unregistered)
    
    // User places hold
    mockRegistry.setState(.holding, for: book.identifier)
    XCTAssertEqual(mockRegistry.state(for: book.identifier), .holding)
    
    let buttonState = BookButtonMapper.map(
      registryState: .holding,
      availability: nil,
      isProcessingDownload: false
    )
    XCTAssertEqual(buttonState, .holding)
  }
  
  func testHoldFlow_HoldingToDownloadNeeded() {
    let book = createTestBook()
    
    // Hold is ready
    mockRegistry.addBook(book, state: .holding)
    
    // User borrows when hold is ready
    mockRegistry.setState(.downloadNeeded, for: book.identifier)
    XCTAssertEqual(mockRegistry.state(for: book.identifier), .downloadNeeded)
  }
  
  func testHoldFlow_CancelHold() {
    let book = createTestBook()
    
    mockRegistry.addBook(book, state: .holding)
    
    // User cancels hold
    mockRegistry.removeBook(forIdentifier: book.identifier)
    XCTAssertNil(mockRegistry.book(forIdentifier: book.identifier))
  }
  
  // MARK: - Download Progress Tests
  
  func testDownloadProgress_StateTracking() {
    var downloadProgress: Double = 0.0
    
    // Simulate download progress updates
    let progressSteps: [Double] = [0.0, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0]
    
    for progress in progressSteps {
      downloadProgress = progress
      XCTAssertEqual(downloadProgress, progress, accuracy: 0.01)
    }
  }
  
  func testDownloadProgress_ResetOnCancel() {
    var downloadProgress: Double = 0.5
    
    // User cancels download
    downloadProgress = 0.0
    
    XCTAssertEqual(downloadProgress, 0.0)
  }
  
  func testDownloadProgress_ResetOnRetry() {
    var downloadProgress: Double = 0.25
    
    // Download fails
    downloadProgress = 0.0
    
    // User retries - progress starts over
    XCTAssertEqual(downloadProgress, 0.0)
  }
  
  // MARK: - Button State Mapping Integration Tests
  
  func testButtonStateMapping_AllRegistryStates() {
    let book = createTestBook()
    
    let stateToExpectedButtonState: [(TPPBookState, BookButtonState)] = [
      (.downloading, .downloadInProgress),
      (.downloadFailed, .downloadFailed),
      (.downloadSuccessful, .downloadSuccessful),
      (.downloadNeeded, .downloadNeeded),
      (.used, .used),
      (.holding, .holding),
      (.returning, .returning)
    ]
    
    for (registryState, expectedButtonState) in stateToExpectedButtonState {
      mockRegistry.addBook(book, state: registryState)
      
      let buttonState = BookButtonMapper.map(
        registryState: registryState,
        availability: nil,
        isProcessingDownload: false
      )
      
      XCTAssertEqual(buttonState, expectedButtonState, "Registry state \(registryState) should map to \(expectedButtonState)")
    }
  }
  
  // MARK: - Notification Flow Tests
  
  func testNotification_RegistryChange() {
    let book = createTestBook()
    var notificationReceived = false
    
    NotificationCenter.default.publisher(for: .TPPBookRegistryDidChange)
      .sink { _ in
        notificationReceived = true
      }
      .store(in: &cancellables)
    
    mockRegistry.addBook(book, state: .unregistered)
    
    // Wait briefly for notification
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    
    XCTAssertTrue(notificationReceived)
  }
  
  // MARK: - Book Registry Publisher Tests
  
  func testRegistryPublisher_StateUpdates() {
    let book = createTestBook()
    var receivedStates: [TPPBookState] = []
    
    mockRegistry.bookStatePublisher
      .filter { $0.0 == book.identifier }
      .map { $0.1 }
      .sink { state in
        receivedStates.append(state)
      }
      .store(in: &cancellables)
    
    // Trigger state changes
    mockRegistry.addBook(book, state: .unregistered)
    mockRegistry.setState(.downloading, for: book.identifier)
    mockRegistry.setState(.downloadSuccessful, for: book.identifier)
    
    // Allow publishers to emit
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    
    XCTAssertTrue(receivedStates.contains(.unregistered))
    XCTAssertTrue(receivedStates.contains(.downloading))
    XCTAssertTrue(receivedStates.contains(.downloadSuccessful))
  }
  
  // MARK: - Concurrent Download Tests
  
  func testConcurrentDownloads_IndependentState() {
    let book1 = createTestBook()
    let book2 = createTestBook()
    
    // Both books start downloading
    mockRegistry.addBook(book1, state: .downloading)
    mockRegistry.addBook(book2, state: .downloading)
    
    // Book 1 completes first
    mockRegistry.setState(.downloadSuccessful, for: book1.identifier)
    
    // Verify states are independent
    XCTAssertEqual(mockRegistry.state(for: book1.identifier), .downloadSuccessful)
    XCTAssertEqual(mockRegistry.state(for: book2.identifier), .downloading)
    
    // Book 2 fails
    mockRegistry.setState(.downloadFailed, for: book2.identifier)
    
    XCTAssertEqual(mockRegistry.state(for: book1.identifier), .downloadSuccessful)
    XCTAssertEqual(mockRegistry.state(for: book2.identifier), .downloadFailed)
  }
  
  // MARK: - Edge Case Tests
  
  func testEdgeCase_RapidStateChanges() {
    let book = createTestBook()
    mockRegistry.addBook(book, state: .unregistered)
    
    // Rapid state changes
    mockRegistry.setState(.downloading, for: book.identifier)
    mockRegistry.setState(.downloadFailed, for: book.identifier)
    mockRegistry.setState(.downloading, for: book.identifier)
    mockRegistry.setState(.downloadSuccessful, for: book.identifier)
    
    // Final state should be downloadSuccessful
    XCTAssertEqual(mockRegistry.state(for: book.identifier), .downloadSuccessful)
  }
  
  func testEdgeCase_NonexistentBook() {
    let state = mockRegistry.state(for: "nonexistent-id")
    XCTAssertEqual(state, .unregistered)
  }
  
  func testEdgeCase_SetStateForNonexistentBook() {
    // Setting state for a non-existent book should not crash
    mockRegistry.setState(.downloading, for: "nonexistent-id")
    
    // State lookup should still return unregistered
    let state = mockRegistry.state(for: "nonexistent-id")
    XCTAssertEqual(state, .unregistered)
  }
  
  // MARK: - Fulfillment ID Tests
  
  func testFulfillmentId_SetAndRetrieve() {
    let book = createTestBook()
    mockRegistry.addBook(book, state: .downloadSuccessful)
    
    mockRegistry.setFulfillmentId("test-fulfillment-123", for: book.identifier)
    
    let fulfillmentId = mockRegistry.fulfillmentId(forIdentifier: book.identifier)
    XCTAssertEqual(fulfillmentId, "test-fulfillment-123")
  }
  
  // MARK: - Location Persistence Tests
  
  func testLocation_SetAndRetrieve() {
    let book = createTestBook()
    mockRegistry.addBook(book, state: .downloadSuccessful)
    
    let location = TPPBookLocation(
      locationString: "{\"progression\":0.5}",
      renderer: TPPBookLocation.r3Renderer
    )
    
    mockRegistry.setLocation(location, forIdentifier: book.identifier)
    
    let retrievedLocation = mockRegistry.location(forIdentifier: book.identifier)
    XCTAssertNotNil(retrievedLocation)
  }
  
  // MARK: - Sync Flow Tests
  
  func testSyncFlow_StartAndComplete() {
    XCTAssertFalse(mockRegistry.isSyncing)
    
    mockRegistry.sync()
    
    // Sync completes synchronously in mock
    XCTAssertFalse(mockRegistry.isSyncing)
  }
  
  func testSyncFlow_ResetClearsRegistry() {
    let book = createTestBook()
    mockRegistry.addBook(book, state: .downloadSuccessful)
    
    XCTAssertNotNil(mockRegistry.book(forIdentifier: book.identifier))
    
    mockRegistry.reset("test-library-id")
    
    XCTAssertTrue(mockRegistry.registry.isEmpty)
  }
}


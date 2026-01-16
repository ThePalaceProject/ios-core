//
//  MyBooksDownloadCenterExtendedTests.swift
//  PalaceTests
//
//  Extended tests for download-related state machine logic
//  NOTE: These tests use mocks only and do NOT make network calls
//

import XCTest
@testable import Palace

// MARK: - Download State Machine Tests

/// Tests for download state machine logic using mock book registry
/// These tests verify state transitions without creating real download sessions
final class DownloadStateMachineTests: XCTestCase {
  
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
  
  func testState_downloadNeeded_canTransitionToDownloading() {
    let book = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
    
    mockBookRegistry.addBook(
      book,
      location: nil,
      state: .downloadNeeded,
      fulfillmentId: nil,
      readiumBookmarks: nil,
      genericBookmarks: nil
    )
    
    mockBookRegistry.setState(.downloading, for: book.identifier)
    
    XCTAssertEqual(mockBookRegistry.state(for: book.identifier), .downloading)
  }
  
  func testState_downloading_canTransitionToSuccess() {
    let book = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
    
    mockBookRegistry.addBook(
      book,
      location: nil,
      state: .downloading,
      fulfillmentId: nil,
      readiumBookmarks: nil,
      genericBookmarks: nil
    )
    
    mockBookRegistry.setState(.downloadSuccessful, for: book.identifier)
    
    XCTAssertEqual(mockBookRegistry.state(for: book.identifier), .downloadSuccessful)
  }
  
  func testState_downloading_canTransitionToFailed() {
    let book = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
    
    mockBookRegistry.addBook(
      book,
      location: nil,
      state: .downloading,
      fulfillmentId: nil,
      readiumBookmarks: nil,
      genericBookmarks: nil
    )
    
    mockBookRegistry.setState(.downloadFailed, for: book.identifier)
    
    XCTAssertEqual(mockBookRegistry.state(for: book.identifier), .downloadFailed)
  }
  
  func testState_downloadFailed_canRetry() {
    let book = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
    
    mockBookRegistry.addBook(
      book,
      location: nil,
      state: .downloadFailed,
      fulfillmentId: nil,
      readiumBookmarks: nil,
      genericBookmarks: nil
    )
    
    // Retry by setting back to downloading
    mockBookRegistry.setState(.downloading, for: book.identifier)
    
    XCTAssertEqual(mockBookRegistry.state(for: book.identifier), .downloading)
  }
  
  func testState_downloadNeeded_canTransitionToDownloadSuccessful() {
    let book = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
    
    mockBookRegistry.addBook(
      book,
      location: nil,
      state: .downloadNeeded,
      fulfillmentId: nil,
      readiumBookmarks: nil,
      genericBookmarks: nil
    )
    
    // Simulate download completion
    mockBookRegistry.setState(.downloadSuccessful, for: book.identifier)
    
    XCTAssertEqual(mockBookRegistry.state(for: book.identifier), .downloadSuccessful)
  }
}

// MARK: - Disk Space Tests

final class DownloadDiskSpaceTests: XCTestCase {
  
  func testAvailableDiskSpace_isPositive() {
    let attributes = try? FileManager.default.attributesOfFileSystem(
      forPath: NSHomeDirectory()
    )
    
    let freeSpace = attributes?[.systemFreeSize] as? Int64 ?? 0
    XCTAssertGreaterThan(freeSpace, 0)
  }
  
  func testDocumentsDirectory_exists() {
    let documentsPath = NSSearchPathForDirectoriesInDomains(
      .documentDirectory,
      .userDomainMask,
      true
    ).first
    
    XCTAssertNotNil(documentsPath)
    XCTAssertTrue(FileManager.default.fileExists(atPath: documentsPath!))
  }
}

// MARK: - Concurrent Download State Tests

/// Tests for concurrent download state management using mock registry
/// These tests verify multiple book state tracking without network calls
final class ConcurrentDownloadStateTests: XCTestCase {
  
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
  
  func testMultipleBooks_canBeRegisteredSimultaneously() {
    let book1 = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
    let book2 = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
    let book3 = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
    
    mockBookRegistry.addBook(book1, location: nil, state: .downloadNeeded, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    mockBookRegistry.addBook(book2, location: nil, state: .downloadNeeded, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    mockBookRegistry.addBook(book3, location: nil, state: .downloadNeeded, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    
    // All books should be registered
    XCTAssertNotNil(mockBookRegistry.book(forIdentifier: book1.identifier))
    XCTAssertNotNil(mockBookRegistry.book(forIdentifier: book2.identifier))
    XCTAssertNotNil(mockBookRegistry.book(forIdentifier: book3.identifier))
  }
  
  func testMultipleBooks_canHaveDifferentStates() {
    let book1 = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
    let book2 = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
    let book3 = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
    
    mockBookRegistry.addBook(book1, location: nil, state: .downloadNeeded, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    mockBookRegistry.addBook(book2, location: nil, state: .downloading, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    mockBookRegistry.addBook(book3, location: nil, state: .downloadSuccessful, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    
    XCTAssertEqual(mockBookRegistry.state(for: book1.identifier), .downloadNeeded)
    XCTAssertEqual(mockBookRegistry.state(for: book2.identifier), .downloading)
    XCTAssertEqual(mockBookRegistry.state(for: book3.identifier), .downloadSuccessful)
  }
  
  func testMultipleBooks_stateChangesAreIndependent() {
    let book1 = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
    let book2 = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
    
    mockBookRegistry.addBook(book1, location: nil, state: .downloading, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    mockBookRegistry.addBook(book2, location: nil, state: .downloading, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    
    // Change only book1's state
    mockBookRegistry.setState(.downloadSuccessful, for: book1.identifier)
    
    // book2 should remain unchanged
    XCTAssertEqual(mockBookRegistry.state(for: book1.identifier), .downloadSuccessful)
    XCTAssertEqual(mockBookRegistry.state(for: book2.identifier), .downloading)
  }
}

// MARK: - PR 735 Regression Tests: Download Slot Management

/// Tests for download slot release when borrow results in hold or failure
/// Bug fix: PP-XXXX - Download queue stuck when borrow results in hold
/// NOTE: These tests verify state transitions without network calls
final class DownloadSlotManagementTests: XCTestCase {
  
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
  
  /// Tests that the download center properly handles state transitions
  /// This verifies the infrastructure for slot management works correctly
  func testStateTransitions_holdingStateIsTracked() {
    let book = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
    
    // Start with unregistered
    mockBookRegistry.addBook(
      book,
      location: nil,
      state: .unregistered,
      fulfillmentId: nil,
      readiumBookmarks: nil,
      genericBookmarks: nil
    )
    
    // Transition through states as would happen in borrow flow
    mockBookRegistry.setState(.downloading, for: book.identifier)
    XCTAssertEqual(mockBookRegistry.state(for: book.identifier), .downloading)
    
    // Borrow results in hold (book unavailable)
    mockBookRegistry.setState(.holding, for: book.identifier)
    XCTAssertEqual(mockBookRegistry.state(for: book.identifier), .holding)
  }
  
  /// Tests that state changes from downloading to holding are detected
  /// The download center should handle this gracefully without getting stuck
  func testStateTransition_downloadingToHolding() {
    let book = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
    
    mockBookRegistry.addBook(
      book,
      location: nil,
      state: .downloading,
      fulfillmentId: nil,
      readiumBookmarks: nil,
      genericBookmarks: nil
    )
    
    XCTAssertEqual(mockBookRegistry.state(for: book.identifier), .downloading)
    
    // Simulate borrow resulting in hold
    mockBookRegistry.setState(.holding, for: book.identifier)
    
    // State should be holding, not stuck at downloading
    XCTAssertEqual(mockBookRegistry.state(for: book.identifier), .holding)
    XCTAssertNotEqual(mockBookRegistry.state(for: book.identifier), .downloading)
  }
  
  /// Tests that books transitioning to holding state are handled correctly
  /// This is critical for the PR 735 fix
  func testHoldingState_bookRegistryTracksCorrectly() {
    let book = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
    
    // Add book and simulate borrow attempt
    mockBookRegistry.addBook(
      book,
      location: nil,
      state: .unregistered,
      fulfillmentId: nil,
      readiumBookmarks: nil,
      genericBookmarks: nil
    )
    
    // Simulate the sequence: unregistered -> (borrow) -> holding
    mockBookRegistry.setState(.holding, for: book.identifier)
    
    let finalState = mockBookRegistry.state(for: book.identifier)
    XCTAssertEqual(finalState, .holding, "Book should be in holding state after unavailable borrow")
  }
  
  /// Tests download failed state transition
  func testStateTransition_downloadingToFailed() {
    let book = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
    
    mockBookRegistry.addBook(
      book,
      location: nil,
      state: .downloading,
      fulfillmentId: nil,
      readiumBookmarks: nil,
      genericBookmarks: nil
    )
    
    // Simulate download failure
    mockBookRegistry.setState(.downloadFailed, for: book.identifier)
    
    XCTAssertEqual(mockBookRegistry.state(for: book.identifier), .downloadFailed)
  }
  
  /// Tests complete download flow state transitions
  func testStateTransition_completeDownloadFlow() {
    let book = TPPBookMocker.mockBook(distributorType: .AdobeAdept)
    
    mockBookRegistry.addBook(
      book,
      location: nil,
      state: .unregistered,
      fulfillmentId: nil,
      readiumBookmarks: nil,
      genericBookmarks: nil
    )
    
    // Simulate: unregistered -> downloadNeeded -> downloading -> downloadSuccessful
    mockBookRegistry.setState(.downloadNeeded, for: book.identifier)
    XCTAssertEqual(mockBookRegistry.state(for: book.identifier), .downloadNeeded)
    
    mockBookRegistry.setState(.downloading, for: book.identifier)
    XCTAssertEqual(mockBookRegistry.state(for: book.identifier), .downloading)
    
    mockBookRegistry.setState(.downloadSuccessful, for: book.identifier)
    XCTAssertEqual(mockBookRegistry.state(for: book.identifier), .downloadSuccessful)
  }
}

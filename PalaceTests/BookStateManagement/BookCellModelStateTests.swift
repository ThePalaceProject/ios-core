//
//  BookCellModelStateTests.swift
//  PalaceTests
//
//  Tests for BookCellModel state synchronization with registry.
//

import XCTest
import Combine
@testable import Palace

@MainActor
final class BookCellModelStateTests: XCTestCase {
  
  var mockRegistry: TPPBookRegistryMock!
  var mockImageCache: MockImageCache!
  var cancellables: Set<AnyCancellable>!
  
  override func setUp() {
    super.setUp()
    mockRegistry = TPPBookRegistryMock()
    mockImageCache = MockImageCache()
    cancellables = Set<AnyCancellable>()
  }
  
  override func tearDown() {
    cancellables = nil
    mockRegistry = nil
    mockImageCache = nil
    super.tearDown()
  }
  
  // MARK: - Helper to create test book
  
  private func createTestBook(id: String = "test-book-123") -> TPPBook {
    return TPPBook(dictionary: [
      "acquisitions": [TPPFake.genericAcquisition.dictionaryRepresentation()],
      "title": "Test Book",
      "categories": ["Fiction"],
      "id": id,
      "updated": "2024-01-01T00:00:00Z"
    ])!
  }
  
  // MARK: - Initial State Tests
  
  func testInitialStateMatchesRegistry() {
    let book = createTestBook()
    mockRegistry.addBook(book, state: .downloadSuccessful)
    
    let model = BookCellModel(book: book, imageCache: mockImageCache, bookRegistry: mockRegistry)
    
    XCTAssertEqual(model.registryState, .downloadSuccessful)
    XCTAssertEqual(model.stableButtonState, .downloadSuccessful)
  }
  
  func testInitialStateForDownloadFailed() {
    let book = createTestBook()
    mockRegistry.addBook(book, state: .downloadFailed)
    
    let model = BookCellModel(book: book, imageCache: mockImageCache, bookRegistry: mockRegistry)
    
    XCTAssertEqual(model.registryState, .downloadFailed)
    XCTAssertEqual(model.stableButtonState, .downloadFailed)
  }
  
  func testInitialStateForDownloading() {
    let book = createTestBook()
    mockRegistry.addBook(book, state: .downloading)
    
    let model = BookCellModel(book: book, imageCache: mockImageCache, bookRegistry: mockRegistry)
    
    XCTAssertEqual(model.registryState, .downloading)
    XCTAssertEqual(model.stableButtonState, .downloadInProgress)
  }
  
  func testInitialStateForUnregisteredBook() {
    let book = createTestBook()
    // Don't add to registry - should be unregistered
    
    let model = BookCellModel(book: book, imageCache: mockImageCache, bookRegistry: mockRegistry)
    
    XCTAssertEqual(model.registryState, .unregistered)
  }
  
  func testInitialStateForHolding() {
    let book = createTestBook()
    mockRegistry.addBook(book, state: .holding)
    
    let model = BookCellModel(book: book, imageCache: mockImageCache, bookRegistry: mockRegistry)
    
    XCTAssertEqual(model.registryState, .holding)
    XCTAssertEqual(model.stableButtonState, .holding)
  }
  
  func testInitialStateForDownloadNeeded() {
    let book = createTestBook()
    mockRegistry.addBook(book, state: .downloadNeeded)
    
    let model = BookCellModel(book: book, imageCache: mockImageCache, bookRegistry: mockRegistry)
    
    XCTAssertEqual(model.registryState, .downloadNeeded)
    XCTAssertEqual(model.stableButtonState, .downloadNeeded)
  }
  
  // MARK: - State Consistency Validation
  
  func testValidateStateConsistencyPasses() {
    let book = createTestBook()
    mockRegistry.addBook(book, state: .downloadSuccessful)
    
    let model = BookCellModel(book: book, imageCache: mockImageCache, bookRegistry: mockRegistry)
    
    XCTAssertTrue(model.validateStateConsistency())
  }
  
  func testValidateStateConsistencyDetectsMismatch() {
    let book = createTestBook()
    mockRegistry.addBook(book, state: .downloadSuccessful)
    
    let model = BookCellModel(book: book, imageCache: mockImageCache, bookRegistry: mockRegistry)
    
    // Directly mutate registry without going through setState (simulates a bug)
    mockRegistry.registry[book.identifier]?.state = .downloadFailed
    
    // State should now be inconsistent
    let isConsistent = model.validateStateConsistency()
    XCTAssertFalse(isConsistent, "Should detect state mismatch")
  }
  
  // MARK: - BookCellState Tests
  
  func testBookCellStateForDownloadInProgress() {
    let state = BookCellState(.downloadInProgress)
    if case .downloading = state {
      // Expected
    } else {
      XCTFail("downloadInProgress should map to .downloading cell state")
    }
  }
  
  func testBookCellStateForDownloadFailed() {
    let state = BookCellState(.downloadFailed)
    if case .downloadFailed = state {
      // Expected
    } else {
      XCTFail("downloadFailed should map to .downloadFailed cell state")
    }
  }
  
  func testBookCellStateForDownloadSuccessful() {
    let state = BookCellState(.downloadSuccessful)
    if case .normal = state {
      // Expected
    } else {
      XCTFail("downloadSuccessful should map to .normal cell state")
    }
  }
  
  func testBookCellStateButtonState() {
    let downloadingState = BookCellState(.downloadInProgress)
    XCTAssertEqual(downloadingState.buttonState, .downloadInProgress)
    
    let failedState = BookCellState(.downloadFailed)
    XCTAssertEqual(failedState.buttonState, .downloadFailed)
    
    let normalState = BookCellState(.downloadSuccessful)
    XCTAssertEqual(normalState.buttonState, .downloadSuccessful)
  }
  
  // MARK: - Loading State Tests
  
  func testIsLoadingDefaultsFalse() {
    let book = createTestBook()
    mockRegistry.addBook(book, state: .downloadSuccessful)
    
    let model = BookCellModel(book: book, imageCache: mockImageCache, bookRegistry: mockRegistry)
    
    XCTAssertFalse(model.isLoading)
  }
  
  func testIsLoadingCanBeSet() {
    let book = createTestBook()
    mockRegistry.addBook(book, state: .downloadSuccessful)
    
    let model = BookCellModel(book: book, imageCache: mockImageCache, bookRegistry: mockRegistry)
    model.isLoading = true
    
    XCTAssertTrue(model.isLoading)
  }
}

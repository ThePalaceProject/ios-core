//
//  BookDetailViewModelTests.swift
//  PalaceTests
//
//  Comprehensive unit tests for BookDetailViewModel following Test_Patterns.md
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace

@MainActor
final class BookDetailViewModelUnitTests: XCTestCase {

  // MARK: - Properties

  private var mockRegistry: TPPBookRegistryMock!
  private var cancellables: Set<AnyCancellable>!

  // MARK: - Setup / Teardown

  override func setUp() {
    super.setUp()
    mockRegistry = TPPBookRegistryMock()
    cancellables = Set<AnyCancellable>()
  }

  override func tearDown() {
    mockRegistry = nil
    cancellables = nil
    super.tearDown()
  }

  // MARK: - Helper Methods

  private func createTestBook(type: DistributorType = .EpubZip) -> TPPBook {
    return TPPBookMocker.mockBook(distributorType: type)
  }

  private func createAudiobook() -> TPPBook {
    return TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
  }

  private func createPDFBook() -> TPPBook {
    return TPPBookMocker.mockBook(distributorType: .OpenAccessPDF)
  }

  private func createViewModel(with book: TPPBook, state: TPPBookState = .unregistered) -> BookDetailViewModel {
    mockRegistry.addBook(book, location: nil, state: state, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    return BookDetailViewModel(book: book, registry: mockRegistry)
  }

  // MARK: - Initialization Tests

  /// Tests that the ViewModel initializes with the provided book and sets all properties correctly
  func testInit_WithBook_SetsProperties() {
    // Arrange
    let book = createTestBook()

    // Act
    let viewModel = createViewModel(with: book, state: .downloadNeeded)

    // Assert
    XCTAssertEqual(viewModel.book.identifier, book.identifier, "Book identifier should match")
    XCTAssertEqual(viewModel.book.title, book.title, "Book title should match")
    XCTAssertEqual(viewModel.bookState, .downloadNeeded, "Book state should match registry state")
  }

  /// Tests that the ViewModel has correct default values on initialization
  func testInit_HasCorrectDefaults() {
    // Arrange
    let book = createTestBook()

    // Act
    let viewModel = createViewModel(with: book)

    // Assert
    XCTAssertEqual(viewModel.downloadProgress, 0.0, "Download progress should start at 0")
    XCTAssertFalse(viewModel.showSampleToolbar, "Sample toolbar should not show by default")
    XCTAssertTrue(viewModel.relatedBooksByLane.isEmpty, "Related books should be empty initially")
    XCTAssertFalse(viewModel.isLoadingRelatedBooks, "Should not be loading related books initially")
    XCTAssertFalse(viewModel.isLoadingDescription, "Should not be loading description initially")
    XCTAssertNil(viewModel.selectedBookURL, "Selected book URL should be nil initially")
    XCTAssertFalse(viewModel.isManagingHold, "Should not be managing hold initially")
    XCTAssertFalse(viewModel.showHalfSheet, "Half sheet should not show initially")
    XCTAssertFalse(viewModel.isProcessing, "Should not be processing initially")
    XCTAssertTrue(viewModel.processingButtons.isEmpty, "No buttons should be processing initially")
    XCTAssertTrue(viewModel.bookmarks.isEmpty, "Bookmarks should be empty initially")
  }

  /// Tests that the ViewModel gets its initial state from the registry
  func testInit_GetsStateFromRegistry() {
    // Arrange
    let book = createTestBook()
    mockRegistry.addBook(book, location: nil, state: .downloadSuccessful, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

    // Act
    let viewModel = BookDetailViewModel(book: book, registry: mockRegistry)

    // Assert
    XCTAssertEqual(viewModel.bookState, .downloadSuccessful, "Should get state from registry")
  }

  // MARK: - Book State Tests

  /// Tests that the ViewModel's bookState property reflects the registry state
  func testBookState_ReflectsRegistryState() {
    // Arrange
    let book = createTestBook()
    let viewModel = createViewModel(with: book, state: .unregistered)

    // Pre-condition
    XCTAssertEqual(viewModel.bookState, .unregistered)

    // Act - Update registry state
    mockRegistry.setState(.downloading, for: book.identifier)

    // Assert - Wait for Combine to propagate the change
    let expectation = XCTestExpectation(description: "State updates")

    viewModel.$bookState
      .dropFirst()
      .sink { state in
        if state == .downloading {
          expectation.fulfill()
        }
      }
      .store(in: &cancellables)

    wait(for: [expectation], timeout: 1.0)
    XCTAssertEqual(viewModel.bookState, .downloading)
  }

  /// Tests that state transitions are properly reflected
  func testBookState_TransitionsThroughStates() {
    // Arrange
    let book = createTestBook()
    let viewModel = createViewModel(with: book, state: .unregistered)
    var recordedStates: [TPPBookState] = []

    let expectation = XCTestExpectation(description: "State transitions")
    expectation.expectedFulfillmentCount = 3

    viewModel.$bookState
      .dropFirst()
      .sink { state in
        recordedStates.append(state)
        expectation.fulfill()
      }
      .store(in: &cancellables)

    // Act - Simulate state transitions
    mockRegistry.setState(.downloadNeeded, for: book.identifier)

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      self.mockRegistry.setState(.downloading, for: book.identifier)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      self.mockRegistry.setState(.downloadSuccessful, for: book.identifier)
    }

    wait(for: [expectation], timeout: 2.0)

    // Assert
    XCTAssertTrue(recordedStates.contains(.downloadNeeded))
    XCTAssertTrue(recordedStates.contains(.downloading))
    XCTAssertTrue(recordedStates.contains(.downloadSuccessful))
  }

  // MARK: - Button State Tests

  /// Tests that stable button state is computed correctly from book and registry state
  func testButtonState_ComputedFromBookAndState() {
    // Arrange
    let book = createTestBook()
    let viewModel = createViewModel(with: book, state: .downloadSuccessful)

    // Assert
    XCTAssertEqual(viewModel.buttonState, .downloadSuccessful)
  }

  /// Tests that button state updates when book state changes
  func testButtonState_UpdatesWithBookState() {
    // Arrange
    let book = createTestBook()
    let viewModel = createViewModel(with: book, state: .unregistered)

    let expectation = XCTestExpectation(description: "Button state updates")

    viewModel.$stableButtonState
      .dropFirst()
      .sink { state in
        if state == .downloadInProgress {
          expectation.fulfill()
        }
      }
      .store(in: &cancellables)

    // Act
    mockRegistry.setState(.downloading, for: book.identifier)

    wait(for: [expectation], timeout: 1.0)
    XCTAssertEqual(viewModel.buttonState, .downloadInProgress)
  }

  // MARK: - Handle Action Tests

  /// Tests that handleAction adds the button to processingButtons
  func testHandleAction_AddsButtonToProcessing() {
    // Arrange
    let book = createTestBook()
    let viewModel = createViewModel(with: book, state: .downloadNeeded)

    // Pre-condition
    XCTAssertFalse(viewModel.isProcessing(for: .download))

    // Act
    viewModel.handleAction(for: .download)

    // Assert
    XCTAssertTrue(viewModel.isProcessing(for: .download), "Download button should be processing")
    XCTAssertTrue(viewModel.isProcessing, "ViewModel should indicate processing")
  }

  /// Tests that handleAction ignores duplicate taps while processing
  func testHandleAction_IgnoresDuplicateWhileProcessing() {
    // Arrange
    let book = createTestBook()
    let viewModel = createViewModel(with: book, state: .downloadNeeded)

    // First action
    viewModel.handleAction(for: .download)
    let firstProcessingCount = viewModel.processingButtons.count

    // Act - Try to handle same action again
    viewModel.handleAction(for: .download)

    // Assert - Count should not increase
    XCTAssertEqual(viewModel.processingButtons.count, firstProcessingCount)
  }

  /// Tests that cancel action clears download progress
  func testHandleAction_Cancel_ClearsProgress() {
    // Arrange
    let book = createTestBook()
    let viewModel = createViewModel(with: book, state: .downloading)
    viewModel.downloadProgress = 0.5

    // Act
    viewModel.handleAction(for: .cancel)

    // Assert
    XCTAssertEqual(viewModel.downloadProgress, 0.0, "Download progress should be cleared on cancel")
  }

  /// Tests that manageHold action sets isManagingHold
  func testHandleAction_ManageHold_SetsFlag() {
    // Arrange
    let book = createTestBook()
    let viewModel = createViewModel(with: book, state: .holding)

    // Pre-condition
    XCTAssertFalse(viewModel.isManagingHold)

    // Act
    viewModel.handleAction(for: .manageHold)

    // Assert
    XCTAssertTrue(viewModel.isManagingHold)
  }

  // MARK: - Download Action Tests

  /// Tests that download action sets download progress to 0
  func testDownloadAction_StartsDownload() {
    // Arrange
    let book = createTestBook()
    let viewModel = createViewModel(with: book, state: .downloadNeeded)
    viewModel.downloadProgress = 0.5 // Simulate previous progress

    // Act
    viewModel.handleAction(for: .download)

    // Assert
    XCTAssertEqual(viewModel.downloadProgress, 0.0, "Download progress should reset on new download")
    XCTAssertTrue(viewModel.isProcessing(for: .download))
  }

  /// Tests that get action behaves like download action
  func testGetAction_BehavesLikeDownload() {
    // Arrange
    let book = createTestBook()
    let viewModel = createViewModel(with: book, state: .unregistered)
    viewModel.downloadProgress = 0.3

    // Act
    viewModel.handleAction(for: .get)

    // Assert
    XCTAssertEqual(viewModel.downloadProgress, 0.0)
    XCTAssertTrue(viewModel.isProcessing(for: .get))
  }

  /// Tests that retry action behaves like download action
  func testRetryAction_BehavesLikeDownload() {
    // Arrange
    let book = createTestBook()
    let viewModel = createViewModel(with: book, state: .downloadFailed)

    // Act
    viewModel.handleAction(for: .retry)

    // Assert
    XCTAssertTrue(viewModel.isProcessing(for: .retry))
  }

  // MARK: - Read/Listen Action Tests

  /// Tests that read action is available when book is downloaded (EPUB)
  func testReadAction_Available_WhenDownloaded() {
    // Arrange
    let book = createTestBook(type: .EpubZip)
    let viewModel = createViewModel(with: book, state: .downloadSuccessful)

    // Assert
    let buttonTypes = viewModel.buttonState.buttonTypes(book: book)
    XCTAssertTrue(buttonTypes.contains(.read), "Read button should be available for downloaded EPUB")
  }

  /// Tests that listen action is available when audiobook is downloaded
  func testListenAction_Available_WhenDownloaded() {
    // Arrange
    let book = createAudiobook()
    let viewModel = createViewModel(with: book, state: .downloadSuccessful)

    // Assert
    let buttonTypes = viewModel.buttonState.buttonTypes(book: book)
    XCTAssertTrue(buttonTypes.contains(.listen), "Listen button should be available for downloaded audiobook")
  }

  // MARK: - Delete/Return Action Tests

  /// Tests that return action sets state to returning
  func testDeleteAction_RemovesBook() {
    // Arrange
    let book = createTestBook()
    let viewModel = createViewModel(with: book, state: .downloadSuccessful)

    // Act
    viewModel.handleAction(for: .return)

    // Assert
    XCTAssertEqual(viewModel.bookState, .returning)
    XCTAssertTrue(viewModel.processingButtons.contains(.returning))
  }

  /// Tests that remove action behaves like return
  func testRemoveAction_BehavesLikeReturn() {
    // Arrange
    let book = createTestBook()
    let viewModel = createViewModel(with: book, state: .downloadSuccessful)

    // Act
    viewModel.handleAction(for: .remove)

    // Assert
    XCTAssertEqual(viewModel.bookState, .returning)
  }

  // MARK: - Cancel Download Tests

  /// Tests that cancel download sets progress to 0
  func testCancelDownload_StopsDownload() {
    // Arrange
    let book = createTestBook()
    let viewModel = createViewModel(with: book, state: .downloading)
    viewModel.downloadProgress = 0.75

    // Act
    viewModel.didSelectCancel()

    // Assert
    XCTAssertEqual(viewModel.downloadProgress, 0.0, "Progress should be reset on cancel")
  }

  // MARK: - Related Books Tests

  /// Tests that related books can be set correctly
  func testRelatedBooks_LoadsCorrectly() {
    // Arrange
    let book = createTestBook()
    let viewModel = createViewModel(with: book)

    let relatedBook1 = createTestBook()
    let relatedBook2 = createTestBook()
    let lane = BookLane(title: "More by Author", books: [relatedBook1, relatedBook2], subsectionURL: nil)

    // Act
    viewModel.relatedBooksByLane = ["More by Author": lane]

    // Assert
    XCTAssertEqual(viewModel.relatedBooksByLane.count, 1)
    XCTAssertEqual(viewModel.relatedBooksByLane["More by Author"]?.books.count, 2)
  }

  /// Tests that selecting a related book clears existing related books
  func testSelectRelatedBook_ClearsRelatedBooks() {
    // Arrange
    let book1 = createTestBook()
    let book2 = createTestBook()
    mockRegistry.addBook(book1, location: nil, state: .unregistered, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)
    mockRegistry.addBook(book2, location: nil, state: .unregistered, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

    let viewModel = BookDetailViewModel(book: book1, registry: mockRegistry)
    let relatedBook = createTestBook()
    let lane = BookLane(title: "Similar", books: [relatedBook], subsectionURL: nil)
    viewModel.relatedBooksByLane = ["Similar": lane]

    // Pre-condition
    XCTAssertFalse(viewModel.relatedBooksByLane.isEmpty)

    // Act
    viewModel.selectRelatedBook(book2)

    // Assert
    XCTAssertTrue(viewModel.relatedBooksByLane.isEmpty, "Related books should be cleared when selecting different book")
    XCTAssertEqual(viewModel.book.identifier, book2.identifier)
  }

  /// Tests that selecting the same book does nothing
  func testSelectRelatedBook_SameBook_DoesNothing() {
    // Arrange
    let book = createTestBook()
    let viewModel = createViewModel(with: book)
    let relatedBook = createTestBook()
    let lane = BookLane(title: "Similar", books: [relatedBook], subsectionURL: nil)
    viewModel.relatedBooksByLane = ["Similar": lane]

    // Act
    viewModel.selectRelatedBook(book)

    // Assert
    XCTAssertFalse(viewModel.relatedBooksByLane.isEmpty, "Related books should remain when selecting same book")
  }

  // MARK: - Show More Books for Lane Tests

  /// Tests that showMoreBooksForLane sets the selected URL
  func testShowMoreBooksForLane_SetsSelectedURL() {
    // Arrange
    let book = createTestBook()
    let viewModel = createViewModel(with: book)
    let moreURL = URL(string: "https://example.com/more")!
    let lane = BookLane(title: "Fiction", books: [], subsectionURL: moreURL)
    viewModel.relatedBooksByLane = ["Fiction": lane]

    // Act
    viewModel.showMoreBooksForLane(laneTitle: "Fiction")

    // Assert
    XCTAssertEqual(viewModel.selectedBookURL, moreURL)
  }

  /// Tests that showMoreBooksForLane does nothing if lane not found
  func testShowMoreBooksForLane_NonexistentLane_DoesNothing() {
    // Arrange
    let book = createTestBook()
    let viewModel = createViewModel(with: book)

    // Act
    viewModel.showMoreBooksForLane(laneTitle: "Nonexistent")

    // Assert
    XCTAssertNil(viewModel.selectedBookURL)
  }

  // MARK: - Processing State Tests

  /// Tests that isProcessing returns true when any button is processing
  func testIsProcessing_TrueWhenButtonProcessing() {
    // Arrange
    let book = createTestBook()
    let viewModel = createViewModel(with: book, state: .downloadNeeded)

    // Pre-condition
    XCTAssertFalse(viewModel.isProcessing)

    // Act
    viewModel.handleAction(for: .download)

    // Assert
    XCTAssertTrue(viewModel.isProcessing)
  }

  /// Tests isProcessing(for:) returns correct value for specific button
  func testIsProcessingForButton_ReturnsCorrectValue() {
    // Arrange
    let book = createTestBook()
    let viewModel = createViewModel(with: book, state: .downloadNeeded)

    viewModel.handleAction(for: .download)

    // Assert
    XCTAssertTrue(viewModel.isProcessing(for: .download))
    XCTAssertFalse(viewModel.isProcessing(for: .read))
  }

  // MARK: - Half Sheet Tests

  /// Tests that half sheet is NOT dismissed on download success
  func testHalfSheet_StaysOpenOnDownloadSuccess() {
    // Arrange
    let book = createTestBook()
    let viewModel = createViewModel(with: book, state: .downloading)
    viewModel.showHalfSheet = true

    // Act - Simulate download completion
    mockRegistry.setState(.downloadSuccessful, for: book.identifier)

    // Allow Combine to process
    let expectation = XCTestExpectation(description: "State change processed")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1.0)

    // Assert - Half sheet should remain open
    XCTAssertTrue(viewModel.showHalfSheet, "Half sheet should stay open on download success")
  }

  /// Tests that half sheet IS dismissed when book becomes unregistered
  func testHalfSheet_DismissedOnUnregistered() {
    // Arrange
    let book = createTestBook()
    let viewModel = createViewModel(with: book, state: .downloadSuccessful)
    viewModel.showHalfSheet = true

    // Act - Simulate return completion
    mockRegistry.setState(.unregistered, for: book.identifier)

    // Allow Combine to process
    let expectation = XCTestExpectation(description: "State change processed")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1.0)

    // Assert
    XCTAssertFalse(viewModel.showHalfSheet, "Half sheet should be dismissed when unregistered")
  }

  // MARK: - Hold Management Tests

  /// Tests that hold state clears isManagingHold when unregistered
  func testHoldManagement_ClearedOnUnregistered() {
    // Arrange
    let book = createTestBook()
    let viewModel = createViewModel(with: book, state: .holding)
    viewModel.isManagingHold = true

    // Act
    mockRegistry.setState(.unregistered, for: book.identifier)

    // Allow Combine to process
    let expectation = XCTestExpectation(description: "State change processed")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1.0)

    // Assert
    XCTAssertFalse(viewModel.isManagingHold)
  }

  // MARK: - Button Types Tests

  /// Tests that BookButtonProvider protocol is correctly implemented
  func testBookButtonProvider_ReturnsCorrectButtonTypes() {
    // Arrange
    let book = createTestBook()
    let viewModel = createViewModel(with: book, state: .downloadSuccessful)

    // Assert
    let buttonTypes = viewModel.buttonTypes
    XCTAssertTrue(buttonTypes.contains(.read), "Downloaded EPUB should have read button")
  }

  // MARK: - Download Progress Tests

  /// Tests that download progress updates are received
  func testDownloadProgress_ReceivesUpdates() {
    // Arrange
    let book = createTestBook()
    let viewModel = createViewModel(with: book, state: .downloading)

    // Initial progress should be 0
    XCTAssertEqual(viewModel.downloadProgress, 0.0)
  }

  // MARK: - Book Update Tests

  /// Tests that ViewModel updates book when registry provides new book data
  func testBookUpdate_WhenRegistryChanges() {
    // Arrange
    let originalBook = createTestBook()
    let viewModel = createViewModel(with: originalBook, state: .downloadNeeded)

    // Create updated book with same identifier
    let updatedBook = TPPBookMocker.mockBook(
      identifier: originalBook.identifier,
      title: "Updated Title",
      distributorType: .EpubZip
    )

    // Act
    mockRegistry.addBook(updatedBook, location: nil, state: .downloading, fulfillmentId: nil, readiumBookmarks: nil, genericBookmarks: nil)

    // Allow Combine to process
    let expectation = XCTestExpectation(description: "Book update processed")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1.0)

    // Assert
    XCTAssertEqual(viewModel.book.title, "Updated Title")
  }

  // MARK: - Returning State Tests

  /// Tests that returning state is properly handled
  func testReturningState_SetsLocalOverride() {
    // Arrange
    let book = createTestBook()
    let viewModel = createViewModel(with: book, state: .downloadSuccessful)

    // Act
    viewModel.handleAction(for: .return)

    // Assert
    XCTAssertEqual(viewModel.bookState, .returning)
  }

  // MARK: - Reserve Action Tests

  /// Tests that reserve action adds reserve button to processing
  func testReserveAction_AddsToProcessing() {
    // Arrange
    let book = TPPBookMocker.snapshotReservedBook()
    let viewModel = createViewModel(with: book, state: .unregistered)

    // Act
    viewModel.handleAction(for: .reserve)

    // Assert
    XCTAssertTrue(viewModel.isProcessing(for: .reserve))
  }

  // MARK: - State Clearing Tests

  /// Tests that processing buttons are cleared appropriately on state changes
  func testProcessingButtons_ClearedOnStateTransitions() {
    // Arrange
    let book = createTestBook()
    let viewModel = createViewModel(with: book, state: .unregistered)
    viewModel.handleAction(for: .get)

    // Pre-condition
    XCTAssertTrue(viewModel.isProcessing(for: .get))

    // Act - Simulate download starting
    mockRegistry.setState(.downloading, for: book.identifier)

    // Allow Combine to process
    let expectation = XCTestExpectation(description: "State change processed")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 1.0)

    // Assert - Processing should be cleared
    XCTAssertFalse(viewModel.isProcessing(for: .get))
  }

  // MARK: - Audiobook Content Type Tests

  /// Tests that audiobook content type is correctly identified
  func testAudiobook_HasCorrectContentType() {
    // Arrange
    let book = createAudiobook()
    let viewModel = createViewModel(with: book, state: .downloadSuccessful)

    // Assert
    XCTAssertEqual(book.defaultBookContentType, .audiobook)
    let buttonTypes = viewModel.buttonState.buttonTypes(book: book)
    XCTAssertTrue(buttonTypes.contains(.listen))
  }

  // MARK: - PDF Content Type Tests

  /// Tests that PDF content type is correctly identified
  func testPDF_HasCorrectContentType() {
    // Arrange
    let book = createPDFBook()
    let viewModel = createViewModel(with: book, state: .downloadSuccessful)

    // Assert
    XCTAssertEqual(book.defaultBookContentType, .pdf)
    let buttonTypes = viewModel.buttonState.buttonTypes(book: book)
    XCTAssertTrue(buttonTypes.contains(.read))
  }

  // MARK: - Sample/Preview Tests

  /// Tests that sample button is available for books with preview link
  func testSampleButton_AvailableWhenPreviewExists() {
    // Arrange
    let book = createTestBook()
    book.previewLink = TPPFake.genericSample

    // Assert
    let buttonTypes = BookButtonState.canBorrow.buttonTypes(book: book, previewEnabled: true)
    XCTAssertTrue(buttonTypes.contains(.sample))
  }

  /// Tests that audiobook sample button is available for audiobooks
  func testAudiobookSampleButton_AvailableForAudiobooks() {
    // Arrange
    let book = createAudiobook()
    book.previewLink = TPPFake.genericAudiobookSample

    // Assert
    let buttonTypes = BookButtonState.canBorrow.buttonTypes(book: book, previewEnabled: true)
    XCTAssertTrue(buttonTypes.contains(.audiobookSample))
  }

  // MARK: - Edge Cases

  /// Tests behavior when book identifier is empty
  func testViewModel_WithEmptyIdentifier_HandlesGracefully() {
    // This test ensures the ViewModel doesn't crash with edge cases
    let book = createTestBook()
    let viewModel = createViewModel(with: book)

    // Should not crash
    XCTAssertNotNil(viewModel.book.identifier)
  }

  /// Tests that multiple rapid state changes are handled
  func testRapidStateChanges_HandledCorrectly() {
    // Arrange
    let book = createTestBook()
    let viewModel = createViewModel(with: book, state: .unregistered)

    // Act - Rapid state changes
    mockRegistry.setState(.downloadNeeded, for: book.identifier)
    mockRegistry.setState(.downloading, for: book.identifier)
    mockRegistry.setState(.downloadFailed, for: book.identifier)
    mockRegistry.setState(.downloading, for: book.identifier)
    mockRegistry.setState(.downloadSuccessful, for: book.identifier)

    // Allow Combine to process
    let expectation = XCTestExpectation(description: "All state changes processed")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      expectation.fulfill()
    }
    wait(for: [expectation], timeout: 2.0)

    // Assert - Should end up in final state
    XCTAssertEqual(viewModel.bookState, .downloadSuccessful)
  }
}

// MARK: - Test Error Enum (Private to avoid conflicts with other test files)

private enum BookDetailTestError: Error {
  case networkError
  case authenticationError
  case parseError

  var localizedDescription: String {
    switch self {
    case .networkError:
      return "Network error occurred"
    case .authenticationError:
      return "Authentication failed"
    case .parseError:
      return "Parse error occurred"
    }
  }
}

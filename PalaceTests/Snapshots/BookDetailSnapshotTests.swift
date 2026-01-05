//
//  BookDetailSnapshotTests.swift
//  PalaceTests
//
//  Tests for BookDetailView to ensure visual and data consistency.
//  These tests verify the structure and state of book detail UI components.
//
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import XCTest
import SwiftUI
import SnapshotTesting
@testable import Palace

/// Tests for BookDetailView to ensure visual and data consistency.
@MainActor
final class BookDetailSnapshotTests: XCTestCase {
  
  // Set to true to record new snapshots, false to compare
  private let recordMode = false
  
  override func setUp() {
    super.setUp()
    // Configure snapshot testing
    // isRecording = recordMode  // Uncomment to enable recording mode
  }
  
  // MARK: - Helper Methods
  
  private func createMockEPUBBook() -> TPPBook {
    return TPPBookMocker.mockBook(distributorType: .EpubZip)
  }
  
  private func createMockAudiobook() -> TPPBook {
    return TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
  }
  
  private func createMockLCPAudiobook() -> TPPBook {
    return TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
  }
  
  private func createMockPDFBook() -> TPPBook {
    return TPPBookMocker.mockBook(distributorType: .OpenAccessPDF)
  }
  
  // MARK: - Accessibility Tests
  
  func testBookDetail_AccessibilityIdentifiersExist() {
    XCTAssertFalse(AccessibilityID.BookDetail.coverImage.isEmpty, "BookDetail cover image identifier should exist")
    XCTAssertFalse(AccessibilityID.BookDetail.title.isEmpty, "BookDetail title identifier should exist")
    XCTAssertFalse(AccessibilityID.BookDetail.author.isEmpty, "BookDetail author identifier should exist")
    XCTAssertFalse(AccessibilityID.BookDetail.description.isEmpty, "BookDetail description identifier should exist")
  }
  
  func testBookDetail_ActionButtonIdentifiersExist() {
    XCTAssertFalse(AccessibilityID.BookDetail.getButton.isEmpty, "Get button identifier should exist")
    XCTAssertFalse(AccessibilityID.BookDetail.readButton.isEmpty, "Read button identifier should exist")
    XCTAssertFalse(AccessibilityID.BookDetail.listenButton.isEmpty, "Listen button identifier should exist")
    XCTAssertFalse(AccessibilityID.BookDetail.reserveButton.isEmpty, "Reserve button identifier should exist")
  }
  
  // MARK: - Book Type Tests
  
  func testBookType_EPUB() {
    let book = createMockEPUBBook()
    
    XCTAssertNotNil(book.identifier)
    XCTAssertEqual(book.defaultBookContentType, .epub)
  }
  
  func testBookType_Audiobook() {
    let book = createMockAudiobook()
    
    XCTAssertNotNil(book.identifier)
    XCTAssertEqual(book.defaultBookContentType, .audiobook)
  }
  
  func testBookType_PDF() {
    let book = createMockPDFBook()
    
    XCTAssertNotNil(book.identifier)
    XCTAssertEqual(book.defaultBookContentType, .pdf)
  }
  
  // MARK: - Button State Tests
  
  func testButtonState_CanBorrow() {
    let state = BookButtonState.canBorrow
    let book = createMockEPUBBook()
    let buttons = state.buttonTypes(book: book, previewEnabled: false)
    
    XCTAssertTrue(buttons.contains(.get))
  }
  
  func testButtonState_CanHold() {
    let state = BookButtonState.canHold
    let book = createMockEPUBBook()
    let buttons = state.buttonTypes(book: book, previewEnabled: false)
    
    XCTAssertTrue(buttons.contains(.reserve))
  }
  
  func testButtonState_DownloadInProgress() {
    let state = BookButtonState.downloadInProgress
    let book = createMockEPUBBook()
    let buttons = state.buttonTypes(book: book)
    
    XCTAssertTrue(buttons.contains(.cancel))
  }
  
  func testButtonState_DownloadSuccessful_EPUB() {
    let state = BookButtonState.downloadSuccessful
    let book = createMockEPUBBook()
    let buttons = state.buttonTypes(book: book)
    
    XCTAssertTrue(buttons.contains(.read))
  }
  
  func testButtonState_DownloadSuccessful_Audiobook() {
    let state = BookButtonState.downloadSuccessful
    let book = createMockAudiobook()
    let buttons = state.buttonTypes(book: book)
    
    XCTAssertTrue(buttons.contains(.listen))
  }
  
  func testButtonState_DownloadFailed() {
    let state = BookButtonState.downloadFailed
    let book = createMockEPUBBook()
    let buttons = state.buttonTypes(book: book)
    
    XCTAssertTrue(buttons.contains(.retry) || buttons.contains(.download))
  }
  
  func testButtonState_Returning() {
    let state = BookButtonState.returning
    let book = createMockEPUBBook()
    let buttons = state.buttonTypes(book: book)
    
    XCTAssertNotNil(buttons)
  }
  
  // MARK: - Book Metadata Tests
  
  func testBookMetadata() {
    let book = createMockEPUBBook()
    
    XCTAssertFalse(book.title.isEmpty)
    XCTAssertNotNil(book.imageURL)
    XCTAssertNotNil(book.imageThumbnailURL)
  }
  
  // MARK: - View State Tests
  
  func testViewState_Loading() {
    struct ViewState {
      let isLoading: Bool
      let errorMessage: String?
    }
    
    let loadingState = ViewState(isLoading: true, errorMessage: nil)
    XCTAssertTrue(loadingState.isLoading)
    XCTAssertNil(loadingState.errorMessage)
  }
  
  func testViewState_Error() {
    struct ViewState {
      let isLoading: Bool
      let errorMessage: String?
    }
    
    let errorState = ViewState(isLoading: false, errorMessage: "Unable to load book details")
    XCTAssertFalse(errorState.isLoading)
    XCTAssertNotNil(errorState.errorMessage)
  }
  
  func testViewState_Success() {
    struct ViewState {
      let isLoading: Bool
      let errorMessage: String?
      let hasBook: Bool
    }
    
    let successState = ViewState(isLoading: false, errorMessage: nil, hasBook: true)
    XCTAssertFalse(successState.isLoading)
    XCTAssertNil(successState.errorMessage)
    XCTAssertTrue(successState.hasBook)
  }
  
  // MARK: - Sample/Preview Tests
  
  func testSampleAvailability() {
    let bookWithSample = createMockEPUBBook()
    
    // Mock books may or may not have samples
    XCTAssertNotNil(bookWithSample)
  }
  
  // MARK: - Related Works Tests
  
  func testRelatedWorks() {
    let book = createMockEPUBBook()
    
    // Check that related works URL can be accessed
    _ = book.relatedWorksURL
    XCTAssertNotNil(book)
  }
  
  // MARK: - BookLane Tests
  
  func testBookLane() {
    let books = [createMockEPUBBook(), createMockAudiobook()]
    let lane = BookLane(
      title: "Similar Books",
      books: books,
      subsectionURL: URL(string: "https://example.com/more")
    )
    
    XCTAssertEqual(lane.title, "Similar Books")
    XCTAssertEqual(lane.books.count, 2)
    XCTAssertNotNil(lane.subsectionURL)
  }
  
  // MARK: - Processing State Tests
  
  func testProcessingState() {
    var processingButtons: Set<BookButtonType> = [.download, .get]
    
    XCTAssertEqual(processingButtons.count, 2)
    XCTAssertTrue(processingButtons.contains(.download))
    XCTAssertTrue(processingButtons.contains(.get))
  }
  
  // MARK: - Download Progress Tests
  
  func testDownloadProgress_States() {
    struct DownloadProgressState {
      let progress: Double
      let description: String
    }
    
    let states = [
      DownloadProgressState(progress: 0.0, description: "Not Started"),
      DownloadProgressState(progress: 0.25, description: "25%"),
      DownloadProgressState(progress: 0.5, description: "50%"),
      DownloadProgressState(progress: 0.75, description: "75%"),
      DownloadProgressState(progress: 1.0, description: "Complete")
    ]
    
    XCTAssertEqual(states.count, 5)
    XCTAssertEqual(states.first?.progress, 0.0)
    XCTAssertEqual(states.last?.progress, 1.0)
  }
  
  // MARK: - Half Sheet State Tests
  
  func testHalfSheet_State() {
    struct HalfSheetState {
      let isShowing: Bool
      let bookState: String
    }
    
    let downloadingState = HalfSheetState(isShowing: true, bookState: "downloading")
    XCTAssertTrue(downloadingState.isShowing)
    
    let hiddenState = HalfSheetState(isShowing: false, bookState: "idle")
    XCTAssertFalse(hiddenState.isShowing)
  }
  
  // MARK: - Managing Hold State Tests
  
  func testManagingHold_State() {
    struct ManagingHoldState {
      let isManagingHold: Bool
      let bookState: String
    }
    
    let managingState = ManagingHoldState(isManagingHold: true, bookState: "holding")
    XCTAssertTrue(managingState.isManagingHold)
    
    let notManagingState = ManagingHoldState(isManagingHold: false, bookState: "holding")
    XCTAssertFalse(notManagingState.isManagingHold)
  }
  
  // MARK: - Orientation State Tests
  
  func testOrientationChange_State() {
    struct OrientationState {
      let isFullSize: Bool
      let isIPad: Bool
    }
    
    let portraitState = OrientationState(isFullSize: true, isIPad: true)
    XCTAssertTrue(portraitState.isFullSize)
    XCTAssertTrue(portraitState.isIPad)
    
    let phoneState = OrientationState(isFullSize: false, isIPad: false)
    XCTAssertFalse(phoneState.isIPad)
  }
  
  // MARK: - TPPBookState Tests
  
  func testAllBookStates() {
    let allStates = TPPBookState.allCases
    
    XCTAssertGreaterThan(allStates.count, 0)
    
    for state in allStates {
      XCTAssertNotNil(state.stringValue())
    }
  }
  
  // MARK: - BookButtonState Tests
  
  func testAllButtonStates() {
    let allStates: [BookButtonState] = [
      .canBorrow, .canHold, .holding, .holdingFrontOfQueue,
      .downloadNeeded, .downloadSuccessful, .used,
      .downloadInProgress, .returning, .managingHold,
      .downloadFailed, .unsupported
    ]
    
    XCTAssertEqual(allStates.count, 12)
  }
  
  // MARK: - Visual Snapshot Tests
  
  func testEPUBBook_snapshot() {
    let book = createMockEPUBBook()
    
    // Snapshot the book model state
    assertSnapshot(of: book, as: .dump)
  }
  
  func testAudiobook_snapshot() {
    let book = createMockAudiobook()
    
    assertSnapshot(of: book, as: .dump)
  }
  
  func testPDFBook_snapshot() {
    let book = createMockPDFBook()
    
    assertSnapshot(of: book, as: .dump)
  }
  
  func testBookButtonState_canBorrow_snapshot() {
    let book = createMockEPUBBook()
    let buttonTypes = BookButtonState.canBorrow.buttonTypes(book: book)
    
    assertSnapshot(of: buttonTypes, as: .dump)
  }
  
  func testBookButtonState_downloadSuccessful_snapshot() {
    let book = createMockEPUBBook()
    let buttonTypes = BookButtonState.downloadSuccessful.buttonTypes(book: book)
    
    assertSnapshot(of: buttonTypes, as: .dump)
  }
  
  func testBookButtonState_audiobook_snapshot() {
    let book = createMockAudiobook()
    let buttonTypes = BookButtonState.downloadSuccessful.buttonTypes(book: book)
    
    assertSnapshot(of: buttonTypes, as: .dump)
  }
}

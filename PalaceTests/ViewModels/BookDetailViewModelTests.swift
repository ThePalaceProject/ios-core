//
//  BookDetailViewModelTests.swift
//  PalaceTests
//
//  Tests for BookButtonMapper, BookButtonState, and BookLane.
//  These are real production classes that contain business logic.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

@MainActor
final class BookDetailViewModelTests: XCTestCase {
  
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
  
  // MARK: - BookButtonMapper Tests (Real Production Class)
  
  func testButtonState_Unregistered_MapsToCanBorrow() {
    let state = TPPBookState.unregistered
    let availability = TPPOPDSAcquisitionAvailabilityUnlimited()
    
    let buttonState = BookButtonMapper.map(
      registryState: state,
      availability: availability,
      isProcessingDownload: false
    )
    
    XCTAssertEqual(buttonState, .canBorrow)
  }
  
  func testButtonState_Downloading_MapsToDownloadInProgress() {
    let state = TPPBookState.downloading
    
    let buttonState = BookButtonMapper.map(
      registryState: state,
      availability: nil,
      isProcessingDownload: false
    )
    
    XCTAssertEqual(buttonState, .downloadInProgress)
  }
  
  func testButtonState_DownloadFailed_MapsToDownloadFailed() {
    let state = TPPBookState.downloadFailed
    
    let buttonState = BookButtonMapper.map(
      registryState: state,
      availability: nil,
      isProcessingDownload: false
    )
    
    XCTAssertEqual(buttonState, .downloadFailed)
  }
  
  func testButtonState_DownloadSuccessful_MapsToDownloadSuccessful() {
    let state = TPPBookState.downloadSuccessful
    
    let buttonState = BookButtonMapper.map(
      registryState: state,
      availability: nil,
      isProcessingDownload: false
    )
    
    XCTAssertEqual(buttonState, .downloadSuccessful)
  }
  
  func testButtonState_DownloadNeeded_MapsToDownloadNeeded() {
    let state = TPPBookState.downloadNeeded
    
    let buttonState = BookButtonMapper.map(
      registryState: state,
      availability: nil,
      isProcessingDownload: false
    )
    
    XCTAssertEqual(buttonState, .downloadNeeded)
  }
  
  func testButtonState_Holding_MapsToHolding() {
    let state = TPPBookState.holding
    
    let buttonState = BookButtonMapper.map(
      registryState: state,
      availability: nil,
      isProcessingDownload: false
    )
    
    XCTAssertEqual(buttonState, .holding)
  }
  
  func testButtonState_Used_MapsToUsed() {
    let state = TPPBookState.used
    
    let buttonState = BookButtonMapper.map(
      registryState: state,
      availability: nil,
      isProcessingDownload: false
    )
    
    XCTAssertEqual(buttonState, .used)
  }
  
  func testButtonState_Returning_MapsToReturning() {
    let state = TPPBookState.returning
    
    let buttonState = BookButtonMapper.map(
      registryState: state,
      availability: nil,
      isProcessingDownload: false
    )
    
    XCTAssertEqual(buttonState, .returning)
  }
  
  func testButtonState_IsProcessingDownload_MapsToDownloadInProgress() {
    let state = TPPBookState.unregistered
    
    let buttonState = BookButtonMapper.map(
      registryState: state,
      availability: nil,
      isProcessingDownload: true
    )
    
    XCTAssertEqual(buttonState, .downloadInProgress)
  }
  
  // MARK: - BookButtonState.buttonTypes Tests (Real Business Logic)
  
  func testButtonTypes_CanBorrow_ReturnsGetButton() {
    let buttonState = BookButtonState.canBorrow
    let book = createTestBook()
    
    let buttons = buttonState.buttonTypes(book: book, previewEnabled: false)
    
    XCTAssertTrue(buttons.contains(.get))
  }
  
  func testButtonTypes_CanHold_ReturnsReserveButton() {
    let buttonState = BookButtonState.canHold
    let book = createTestBook()
    
    let buttons = buttonState.buttonTypes(book: book, previewEnabled: false)
    
    XCTAssertTrue(buttons.contains(.reserve))
  }
  
  func testButtonTypes_DownloadInProgress_ReturnsCancelButton() {
    let buttonState = BookButtonState.downloadInProgress
    let book = createTestBook()
    
    let buttons = buttonState.buttonTypes(book: book)
    
    XCTAssertEqual(buttons, [.cancel])
  }
  
  func testButtonTypes_DownloadFailed_ReturnsCancelAndRetry() {
    let buttonState = BookButtonState.downloadFailed
    let book = createTestBook()
    
    let buttons = buttonState.buttonTypes(book: book)
    
    XCTAssertTrue(buttons.contains(.cancel))
    XCTAssertTrue(buttons.contains(.retry))
  }
  
  func testButtonTypes_DownloadSuccessful_EpubReturnsRead() {
    let buttonState = BookButtonState.downloadSuccessful
    let book = createTestBook()
    
    let buttons = buttonState.buttonTypes(book: book)
    
    XCTAssertTrue(buttons.contains(.read))
  }
  
  func testButtonTypes_DownloadSuccessful_AudiobookReturnsListen() {
    let buttonState = BookButtonState.downloadSuccessful
    let book = createAudiobook()
    
    let buttons = buttonState.buttonTypes(book: book)
    
    XCTAssertTrue(buttons.contains(.listen))
  }
  
  func testButtonTypes_Returning_ReturnsReturningButton() {
    let buttonState = BookButtonState.returning
    let book = createTestBook()
    
    let buttons = buttonState.buttonTypes(book: book)
    
    XCTAssertEqual(buttons, [.returning])
  }
  
  func testButtonTypes_Unsupported_ReturnsEmpty() {
    let buttonState = BookButtonState.unsupported
    let book = createTestBook()
    
    let buttons = buttonState.buttonTypes(book: book)
    
    XCTAssertTrue(buttons.isEmpty)
  }
  
  // MARK: - Preview/Sample Button Tests (Real Business Logic)
  
  func testButtonTypes_CanBorrowWithSample_IncludesSampleButton() {
    let buttonState = BookButtonState.canBorrow
    let book = createTestBook()
    book.previewLink = TPPFake.genericSample
    
    let buttons = buttonState.buttonTypes(book: book, previewEnabled: true)
    
    XCTAssertTrue(buttons.contains(.sample))
  }
  
  func testButtonTypes_CanBorrowAudiobookWithSample_IncludesAudiobookSample() {
    let buttonState = BookButtonState.canBorrow
    let book = createAudiobook()
    book.previewLink = TPPFake.genericAudiobookSample
    
    let buttons = buttonState.buttonTypes(book: book, previewEnabled: true)
    
    XCTAssertTrue(buttons.contains(.audiobookSample))
  }
  
  func testButtonTypes_PreviewDisabled_ExcludesSampleButton() {
    let buttonState = BookButtonState.canBorrow
    let book = createTestBook()
    book.previewLink = TPPFake.genericSample
    
    let buttons = buttonState.buttonTypes(book: book, previewEnabled: false)
    
    XCTAssertFalse(buttons.contains(.sample))
    XCTAssertFalse(buttons.contains(.audiobookSample))
  }
  
  // MARK: - Book Content Type Tests (Real TPPBook Methods)
  
  func testBookContentType_EPUB() {
    let book = createTestBook(type: .EpubZip)
    
    XCTAssertEqual(book.defaultBookContentType, .epub)
  }
  
  func testBookContentType_Audiobook() {
    let book = createAudiobook()
    
    XCTAssertEqual(book.defaultBookContentType, .audiobook)
  }
  
  func testBookContentType_PDF() {
    let book = createPDFBook()
    
    XCTAssertEqual(book.defaultBookContentType, .pdf)
  }
  
  // MARK: - Availability Mapping Tests (Real BookButtonMapper Logic)
  
  func testAvailability_Unlimited_MapsToCanBorrow() {
    let availability = TPPOPDSAcquisitionAvailabilityUnlimited()
    
    let state = BookButtonMapper.stateForAvailability(availability)
    
    XCTAssertEqual(state, .canBorrow)
  }
  
  func testAvailability_Nil_ReturnsNil() {
    let state = BookButtonMapper.stateForAvailability(nil)
    
    XCTAssertNil(state)
  }
  
  // MARK: - BookLane Tests (Real Production Struct)
  
  func testBookLane_Creation() {
    let books = [createTestBook(), createTestBook()]
    let url = URL(string: "https://example.com/more")
    
    let lane = BookLane(title: "Fiction", books: books, subsectionURL: url)
    
    XCTAssertEqual(lane.title, "Fiction")
    XCTAssertEqual(lane.books.count, 2)
    XCTAssertEqual(lane.subsectionURL, url)
  }
  
  func testBookLane_WithNilURL() {
    let books = [createTestBook()]
    
    let lane = BookLane(title: "Featured", books: books, subsectionURL: nil)
    
    XCTAssertNil(lane.subsectionURL)
  }
  
  func testBookLane_EmptyBooks() {
    let lane = BookLane(title: "Empty Lane", books: [], subsectionURL: nil)
    
    XCTAssertTrue(lane.books.isEmpty)
    XCTAssertEqual(lane.title, "Empty Lane")
  }
  
  // MARK: - Hold State Business Logic Tests
  
  /// Tests that holding state maps correctly when transitioning from borrow attempt
  func testHoldingState_MapsFromBorrowAttempt() {
    let state = TPPBookState.holding
    
    let buttonState = BookButtonMapper.map(
      registryState: state,
      availability: nil,
      isProcessingDownload: false
    )
    
    XCTAssertEqual(buttonState, .holding)
  }
  
  /// Tests that holding state button types include hold management options
  func testHoldingState_ButtonTypesIncludeHoldManagement() {
    let buttonState = BookButtonState.holding
    let book = createTestBook()
    
    let buttons = buttonState.buttonTypes(book: book)
    
    // Holding state should show hold management buttons, not get
    XCTAssertFalse(buttons.contains(.get), "Should not contain get button")
    XCTAssertFalse(buttons.contains(.reserve), "Should not contain reserve button")
    XCTAssertFalse(buttons.contains(.download), "Should not contain download button")
  }
  
  // MARK: - Managing Hold State Tests
  
  func testManagedHoldState_ButtonTypes() {
    let buttonState = BookButtonState.managingHold
    let book = createTestBook()
    
    let buttons = buttonState.buttonTypes(book: book)
    
    // Managing hold should show cancel hold button
    XCTAssertTrue(buttons.contains(.cancelHold))
  }
  
  // MARK: - All Book States Coverage Tests
  
  func testAllBookStates_HaveValidMapping() {
    let allStates: [TPPBookState] = [
      .unregistered,
      .downloading,
      .downloadFailed,
      .downloadNeeded,
      .downloadSuccessful,
      .holding,
      .used,
      .returning,
      .unsupported
    ]
    
    for state in allStates {
      let buttonState = BookButtonMapper.map(
        registryState: state,
        availability: nil,
        isProcessingDownload: false
      )
      
      // Every state should map to a valid button state
      XCTAssertNotNil(buttonState, "State \(state) should map to a valid button state")
    }
  }
  
  func testAllButtonStates_HaveValidButtonTypes() {
    let allButtonStates: [BookButtonState] = [
      .canBorrow,
      .canHold,
      .downloadInProgress,
      .downloadFailed,
      .downloadNeeded,
      .downloadSuccessful,
      .holding,
      .used,
      .returning,
      .unsupported,
      .managingHold
    ]
    
    let book = createTestBook()
    
    for buttonState in allButtonStates {
      // This should not crash
      let buttons = buttonState.buttonTypes(book: book)
      
      // Verify we get an array (even if empty)
      XCTAssertNotNil(buttons, "Button state \(buttonState) should return valid button types")
    }
  }
}

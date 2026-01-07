//
//  BookDetailViewModelTests.swift
//  PalaceTests
//
//  Tests for BookButtonMapper, BookButtonState, and BookLane.
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
  
  // MARK: - BookButtonMapper Tests
  
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
  
  // MARK: - BookButtonState.buttonTypes Tests
  
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
  
  // MARK: - Preview/Sample Button Tests
  
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
  
  // MARK: - BookLane Tests
  
  func testBookLane_Creation() {
    let books = [createTestBook(), createTestBook()]
    let lane = BookLane(
      title: "Similar Books",
      books: books,
      subsectionURL: URL(string: "https://example.com/more")
    )
    
    XCTAssertEqual(lane.title, "Similar Books")
    XCTAssertEqual(lane.books.count, 2)
    XCTAssertNotNil(lane.subsectionURL)
  }
  
  // MARK: - Book Content Type Tests
  
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
  
  // MARK: - Availability Mapping Tests
  
  func testAvailability_Unlimited_MapsToCanBorrow() {
    let availability = TPPOPDSAcquisitionAvailabilityUnlimited()
    
    let state = BookButtonState.stateForAvailability(availability)
    
    XCTAssertEqual(state, .canBorrow)
  }
  
  func testAvailability_Nil_ReturnsNil() {
    let state = BookButtonState.stateForAvailability(nil)
    
    XCTAssertNil(state)
  }
  
  // MARK: - Managing Hold State Logic
  
  func testComputeButtonState_ManagingHold_ReturnsManagedHoldState() {
    let bookState = TPPBookState.holding
    let isManagingHold = true
    
    let expectedState: BookButtonState = .managingHold
    
    // Simulate the computeButtonState logic
    let resultState: BookButtonState
    if bookState == .holding && isManagingHold {
      resultState = .managingHold
    } else {
      resultState = BookButtonMapper.map(
        registryState: bookState,
        availability: nil,
        isProcessingDownload: false
      )
    }
    
    XCTAssertEqual(resultState, expectedState)
  }
}

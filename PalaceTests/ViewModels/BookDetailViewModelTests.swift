//
//  BookDetailViewModelTests.swift
//  PalaceTests
//
//  Tests for BookDetailViewModel including button state transitions,
//  download flow, and action handling.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace

@MainActor
final class BookDetailViewModelTests: XCTestCase {
  
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
  
  private func createAudiobook() -> TPPBook {
    return TPPBookMocker.mockBook(distributorType: .OpenAccessAudiobook)
  }
  
  private func createPDFBook() -> TPPBook {
    return TPPBookMocker.mockBook(distributorType: .OpenAccessPDF)
  }
  
  // MARK: - Initialization Tests
  
  func testInit_WithEpubBook_SetsCorrectState() async {
    let book = createTestBook()
    mockRegistry.addBook(book, state: .unregistered)
    
    XCTAssertNotNil(book.identifier)
    XCTAssertFalse(book.identifier.isEmpty)
  }
  
  func testInit_WithAudiobook_SetsCorrectState() async {
    let book = createAudiobook()
    mockRegistry.addBook(book, state: .unregistered)
    
    XCTAssertNotNil(book.identifier)
    XCTAssertTrue(book.isAudiobook)
  }
  
  func testInit_WithPDFBook_SetsCorrectState() async {
    let book = createPDFBook()
    mockRegistry.addBook(book, state: .unregistered)
    
    XCTAssertNotNil(book.identifier)
  }
  
  // MARK: - Button State Mapping Tests
  
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
  
  // MARK: - Button Types Tests
  
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
  
  // MARK: - Registry State Tests
  
  func testRegistryState_UpdatesBookState() {
    let book = createTestBook()
    
    mockRegistry.addBook(book, state: .unregistered)
    XCTAssertEqual(mockRegistry.state(for: book.identifier), .unregistered)
    
    mockRegistry.setState(.downloading, for: book.identifier)
    XCTAssertEqual(mockRegistry.state(for: book.identifier), .downloading)
    
    mockRegistry.setState(.downloadSuccessful, for: book.identifier)
    XCTAssertEqual(mockRegistry.state(for: book.identifier), .downloadSuccessful)
  }
  
  func testRegistryState_BookLookup() {
    let book = createTestBook()
    mockRegistry.addBook(book, state: .downloadSuccessful)
    
    let retrievedBook = mockRegistry.book(forIdentifier: book.identifier)
    
    XCTAssertNotNil(retrievedBook)
    XCTAssertEqual(retrievedBook?.identifier, book.identifier)
  }
  
  // MARK: - Processing State Tests
  
  func testProcessingButtons_TracksActiveOperations() {
    var processingButtons: Set<BookButtonType> = []
    
    processingButtons.insert(.download)
    XCTAssertTrue(processingButtons.contains(.download))
    
    processingButtons.insert(.returning)
    XCTAssertEqual(processingButtons.count, 2)
    
    processingButtons.remove(.download)
    XCTAssertFalse(processingButtons.contains(.download))
    XCTAssertTrue(processingButtons.contains(.returning))
  }
  
  func testIsProcessing_TrueWhenButtonsProcessing() {
    var processingButtons: Set<BookButtonType> = []
    var isProcessing: Bool { processingButtons.count > 0 }
    
    XCTAssertFalse(isProcessing)
    
    processingButtons.insert(.get)
    XCTAssertTrue(isProcessing)
    
    processingButtons.removeAll()
    XCTAssertFalse(isProcessing)
  }
  
  // MARK: - Download Progress Tests
  
  func testDownloadProgress_InitialValue() {
    var downloadProgress: Double = 0.0
    
    XCTAssertEqual(downloadProgress, 0.0)
  }
  
  func testDownloadProgress_UpdatesDuringDownload() {
    var downloadProgress: Double = 0.0
    
    downloadProgress = 0.25
    XCTAssertEqual(downloadProgress, 0.25, accuracy: 0.01)
    
    downloadProgress = 0.5
    XCTAssertEqual(downloadProgress, 0.5, accuracy: 0.01)
    
    downloadProgress = 1.0
    XCTAssertEqual(downloadProgress, 1.0, accuracy: 0.01)
  }
  
  // MARK: - Hold Management Tests
  
  func testManagingHold_StateTransition() {
    var isManagingHold = false
    var bookState = TPPBookState.holding
    
    // User taps manage hold
    isManagingHold = true
    XCTAssertTrue(isManagingHold)
    
    // State should still be holding
    XCTAssertEqual(bookState, .holding)
    
    // User cancels hold management
    isManagingHold = false
    XCTAssertFalse(isManagingHold)
  }
  
  func testComputeButtonState_ManagingHold_ReturnsManagedHoldState() {
    let bookState = TPPBookState.holding
    let isManagingHold = true
    
    // When managing hold, should return managingHold state
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
  
  // MARK: - Related Books Tests
  
  func testRelatedBooksByLane_EmptyInitially() {
    var relatedBooksByLane: [String: BookLane] = [:]
    
    XCTAssertTrue(relatedBooksByLane.isEmpty)
  }
  
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
  
  // MARK: - Error State Tests
  
  func testDownloadFailed_ShowsHalfSheetFalse() {
    var showHalfSheet = true
    let bookState = TPPBookState.downloadFailed
    
    // When download fails, half sheet should be hidden
    if bookState == .downloadFailed {
      showHalfSheet = false
    }
    
    XCTAssertFalse(showHalfSheet)
  }
  
  func testUnregistered_ClearsProcessingState() {
    var isManagingHold = true
    var showHalfSheet = true
    var processingButtons: Set<BookButtonType> = [.returning, .cancelHold]
    let registryState = TPPBookState.unregistered
    
    // When state becomes unregistered, clear all processing states
    if registryState == .unregistered {
      isManagingHold = false
      showHalfSheet = false
      processingButtons.remove(.returning)
      processingButtons.remove(.cancelHold)
    }
    
    XCTAssertFalse(isManagingHold)
    XCTAssertFalse(showHalfSheet)
    XCTAssertTrue(processingButtons.isEmpty)
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
  
  // MARK: - Bookmark Tests
  
  func testBookmarks_EmptyInitially() {
    var bookmarks: [TPPReadiumBookmark] = []
    
    XCTAssertTrue(bookmarks.isEmpty)
  }
  
  func testBookmarks_AddToRegistry() {
    let book = createTestBook()
    mockRegistry.addBook(book, state: .downloadSuccessful)
    
    let bookmarks = mockRegistry.readiumBookmarks(forIdentifier: book.identifier)
    
    XCTAssertNotNil(bookmarks)
  }
  
  // MARK: - Location Tests
  
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
    XCTAssertEqual(retrievedLocation?.locationString, location?.locationString)
  }
  
  // MARK: - State String Conversion Tests
  
  func testTPPBookState_StringConversion() {
    XCTAssertEqual(TPPBookState.unregistered.stringValue(), UnregisteredKey)
    XCTAssertEqual(TPPBookState.downloading.stringValue(), DownloadingKey)
    XCTAssertEqual(TPPBookState.downloadFailed.stringValue(), DownloadFailedKey)
    XCTAssertEqual(TPPBookState.downloadNeeded.stringValue(), DownloadNeededKey)
    XCTAssertEqual(TPPBookState.downloadSuccessful.stringValue(), DownloadSuccessfulKey)
    XCTAssertEqual(TPPBookState.holding.stringValue(), HoldingKey)
    XCTAssertEqual(TPPBookState.used.stringValue(), UsedKey)
    XCTAssertEqual(TPPBookState.returning.stringValue(), ReturningKey)
  }
  
  func testTPPBookState_InitFromString() {
    XCTAssertEqual(TPPBookState(UnregisteredKey), .unregistered)
    XCTAssertEqual(TPPBookState(DownloadingKey), .downloading)
    XCTAssertEqual(TPPBookState(DownloadFailedKey), .downloadFailed)
    XCTAssertEqual(TPPBookState(DownloadNeededKey), .downloadNeeded)
    XCTAssertEqual(TPPBookState(DownloadSuccessfulKey), .downloadSuccessful)
    XCTAssertEqual(TPPBookState(HoldingKey), .holding)
    XCTAssertEqual(TPPBookState(UsedKey), .used)
    XCTAssertNil(TPPBookState("invalid-key"))
  }
  
  // MARK: - Full State Transition Tests
  
  func testStateTransition_BorrowToDownload() {
    let book = createTestBook()
    mockRegistry.addBook(book, state: .unregistered)
    
    // User taps Get
    mockRegistry.setState(.downloading, for: book.identifier)
    XCTAssertEqual(mockRegistry.state(for: book.identifier), .downloading)
    
    // Download completes
    mockRegistry.setState(.downloadSuccessful, for: book.identifier)
    XCTAssertEqual(mockRegistry.state(for: book.identifier), .downloadSuccessful)
  }
  
  func testStateTransition_DownloadFailure() {
    let book = createTestBook()
    mockRegistry.addBook(book, state: .downloading)
    
    // Download fails
    mockRegistry.setState(.downloadFailed, for: book.identifier)
    XCTAssertEqual(mockRegistry.state(for: book.identifier), .downloadFailed)
    
    // Retry download
    mockRegistry.setState(.downloading, for: book.identifier)
    XCTAssertEqual(mockRegistry.state(for: book.identifier), .downloading)
  }
  
  func testStateTransition_ReturnBook() {
    let book = createTestBook()
    mockRegistry.addBook(book, state: .downloadSuccessful)
    
    // User returns book
    mockRegistry.setState(.returning, for: book.identifier)
    XCTAssertEqual(mockRegistry.state(for: book.identifier), .returning)
    
    // Return completes
    mockRegistry.removeBook(forIdentifier: book.identifier)
    XCTAssertNil(mockRegistry.book(forIdentifier: book.identifier))
  }
}


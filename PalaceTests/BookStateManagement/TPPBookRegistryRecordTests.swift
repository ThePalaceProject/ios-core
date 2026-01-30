//
//  TPPBookRegistryRecordTests.swift
//  PalaceTests
//
//  Tests for TPPBookRegistryRecord - ensures state is properly preserved
//  and deriveInitialState works correctly.
//

import XCTest
@testable import Palace

final class TPPBookRegistryRecordTests: XCTestCase {
  
  // MARK: - Helper
  
  private func createTestBook(id: String = "test-book-123") -> TPPBook {
    return TPPBook(dictionary: [
      "acquisitions": [TPPFake.genericAcquisition.dictionaryRepresentation()],
      "title": "Test Book",
      "categories": ["Fiction"],
      "id": id,
      "updated": "2024-01-01T00:00:00Z"
    ])!
  }
  
  // MARK: - State Preservation Tests
  
  func testInitPreservesDownloadSuccessfulState() {
    let book = createTestBook()
    
    let record = TPPBookRegistryRecord(
      book: book,
      state: .downloadSuccessful
    )
    
    XCTAssertEqual(record.state, .downloadSuccessful,
                   "State should be preserved as-is, not overridden")
  }
  
  func testInitPreservesDownloadFailedState() {
    let book = createTestBook()
    
    let record = TPPBookRegistryRecord(
      book: book,
      state: .downloadFailed
    )
    
    XCTAssertEqual(record.state, .downloadFailed)
  }
  
  func testInitPreservesDownloadingState() {
    let book = createTestBook()
    
    let record = TPPBookRegistryRecord(
      book: book,
      state: .downloading
    )
    
    XCTAssertEqual(record.state, .downloading)
  }
  
  func testInitPreservesHoldingState() {
    let book = createTestBook()
    
    let record = TPPBookRegistryRecord(
      book: book,
      state: .holding
    )
    
    XCTAssertEqual(record.state, .holding)
  }
  
  func testInitPreservesUsedState() {
    let book = createTestBook()
    
    let record = TPPBookRegistryRecord(
      book: book,
      state: .used
    )
    
    XCTAssertEqual(record.state, .used)
  }
  
  // MARK: - deriveInitialState Tests
  
  func testDeriveInitialStateForBookWithoutAcquisition() {
    // Create a minimal book without default acquisition
    let book = TPPBook(dictionary: [
      "title": "No Acquisition Book",
      "categories": ["Test"],
      "id": "no-acq-123",
      "updated": "2024-01-01T00:00:00Z"
    ])!
    
    let state = TPPBookRegistryRecord.deriveInitialState(for: book)
    
    XCTAssertEqual(state, .unsupported,
                   "Book without acquisition should be unsupported")
  }
  
  func testDeriveInitialStateForBorrowableBook() {
    let book = createTestBook()
    // Book with generic acquisition should be borrowable -> downloadNeeded
    
    let state = TPPBookRegistryRecord.deriveInitialState(for: book)
    
    // Should derive to downloadNeeded (or holding if reserved)
    // depending on the availability of the mock acquisition
    XCTAssertTrue(
      state == .downloadNeeded || state == .holding,
      "Borrowable book should be downloadNeeded or holding"
    )
  }
  
  // MARK: - Dictionary Round-trip Tests
  
  func testDictionaryRepresentationPreservesState() {
    let book = createTestBook()
    let record = TPPBookRegistryRecord(
      book: book,
      state: .downloadSuccessful,
      fulfillmentId: "test-fulfillment"
    )
    
    let dict = record.dictionaryRepresentation
    
    // Verify state is in dictionary
    XCTAssertEqual(dict["state"] as? String, "download-successful")
    XCTAssertEqual(dict["fulfillmentId"] as? String, "test-fulfillment")
  }
  
  func testInitFromDictionaryPreservesState() {
    let book = createTestBook()
    let originalRecord = TPPBookRegistryRecord(
      book: book,
      state: .downloadSuccessful
    )
    
    let dict = originalRecord.dictionaryRepresentation
    
    // Create TPPBookRegistryData from dictionary
    var registryData = TPPBookRegistryData()
    for (key, value) in dict {
      if let key = TPPBookRegistryKey(rawValue: key) {
        registryData.setValue(value, for: key)
      }
    }
    
    let restoredRecord = TPPBookRegistryRecord(record: registryData)
    
    XCTAssertNotNil(restoredRecord)
    XCTAssertEqual(restoredRecord?.state, .downloadSuccessful)
  }
  
  // MARK: - All States Test
  
  func testAllStatesCanBePreserved() {
    let book = createTestBook()
    let allStates: [TPPBookState] = [
      .unregistered, .downloadNeeded, .downloading, .downloadFailed,
      .downloadSuccessful, .returning, .holding, .used, .unsupported, .SAMLStarted
    ]
    
    for state in allStates {
      let record = TPPBookRegistryRecord(book: book, state: state)
      XCTAssertEqual(record.state, state,
                     "State \(state) should be preserved")
    }
  }
}

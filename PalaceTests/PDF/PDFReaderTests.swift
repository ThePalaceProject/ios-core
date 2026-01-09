//
//  PDFReaderTests.swift
//  PalaceTests
//
//  Tests for TPPPDFPage, TPPPDFPageBookmark, and TPPPDFReaderMode.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace

@MainActor
final class PDFReaderTests: XCTestCase {
  
  // MARK: - Helper Methods
  
  private func createPDFBook() -> TPPBook {
    return TPPBookMocker.mockBook(distributorType: .OpenAccessPDF)
  }
  
  private func createLCPPDFBook() -> TPPBook {
    return TPPBookMocker.mockBook(distributorType: .PDFLCP)
  }
  
  // MARK: - TPPPDFPage Tests
  
  func testPDFPage_Initialization() {
    let page = TPPPDFPage(pageNumber: 5)
    
    XCTAssertEqual(page.pageNumber, 5)
  }
  
  func testPDFPage_Encoding() throws {
    let page = TPPPDFPage(pageNumber: 10)
    let encoder = JSONEncoder()
    
    let data = try encoder.encode(page)
    XCTAssertFalse(data.isEmpty)
    
    let json = String(data: data, encoding: .utf8)
    XCTAssertTrue(json?.contains("10") ?? false)
  }
  
  func testPDFPage_Decoding() throws {
    let json = "{\"pageNumber\":15}"
    let data = json.data(using: .utf8)!
    let decoder = JSONDecoder()
    
    let page = try decoder.decode(TPPPDFPage.self, from: data)
    
    XCTAssertEqual(page.pageNumber, 15)
  }
  
  func testPDFPage_RoundTrip() throws {
    let originalPage = TPPPDFPage(pageNumber: 42)
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    
    let data = try encoder.encode(originalPage)
    let decodedPage = try decoder.decode(TPPPDFPage.self, from: data)
    
    XCTAssertEqual(originalPage.pageNumber, decodedPage.pageNumber)
  }
  
  // MARK: - TPPPDFPageBookmark Tests
  
  func testPDFPageBookmark_Initialization() {
    let bookmark = TPPPDFPageBookmark(page: 25)
    
    XCTAssertEqual(bookmark.page, 25)
    XCTAssertEqual(bookmark.type, TPPPDFPageBookmark.Types.locatorPage.rawValue)
    XCTAssertNil(bookmark.annotationID)
  }
  
  func testPDFPageBookmark_WithAnnotationID() {
    let bookmark = TPPPDFPageBookmark(page: 30, annotationID: "annotation-123")
    
    XCTAssertEqual(bookmark.page, 30)
    XCTAssertEqual(bookmark.annotationID, "annotation-123")
  }
  
  func testPDFPageBookmark_ConformsToBookmark() {
    let bookmark = TPPPDFPageBookmark(page: 1)
    
    XCTAssertTrue(bookmark is Bookmark)
  }
  
  func testPDFPageBookmark_Encoding() throws {
    let bookmark = TPPPDFPageBookmark(page: 50)
    let encoder = JSONEncoder()
    
    let data = try encoder.encode(bookmark)
    let json = String(data: data, encoding: .utf8)!
    
    XCTAssertTrue(json.contains("LocatorPage"))
    XCTAssertTrue(json.contains("50"))
  }
  
  func testPDFPageBookmark_Decoding() throws {
    let json = "{\"@type\":\"LocatorPage\",\"page\":75}"
    let data = json.data(using: .utf8)!
    let decoder = JSONDecoder()
    
    let bookmark = try decoder.decode(TPPPDFPageBookmark.self, from: data)
    
    XCTAssertEqual(bookmark.page, 75)
    XCTAssertEqual(bookmark.type, "LocatorPage")
  }
  
  // MARK: - TPPPDFReaderMode Tests
  
  func testReaderMode_Values() {
    XCTAssertEqual(TPPPDFReaderMode.reader.value, "Reader")
    XCTAssertEqual(TPPPDFReaderMode.previews.value, "Page previews")
    XCTAssertEqual(TPPPDFReaderMode.bookmarks.value, "Bookmarks")
    XCTAssertEqual(TPPPDFReaderMode.toc.value, "TOC")
    XCTAssertEqual(TPPPDFReaderMode.search.value, "Search")
  }
  
  // MARK: - Book Content Type Tests
  
  func testPDFBook_ContentType() {
    let book = createPDFBook()
    
    XCTAssertEqual(book.defaultBookContentType, .pdf)
  }
  
  func testLCPPDFBook_ContentType() {
    let book = createLCPPDFBook()
    
    // LCP PDF content type detection depends on the acquisition path
    let contentType = book.defaultBookContentType
    XCTAssertTrue(
      contentType == .pdf || contentType == .unsupported,
      "LCP PDF should be .pdf or .unsupported depending on acquisition configuration"
    )
  }
}

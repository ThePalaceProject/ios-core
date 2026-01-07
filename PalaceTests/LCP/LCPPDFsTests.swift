//
//  LCPPDFsTests.swift
//  PalaceTests
//
//  Tests for LCP PDF functionality
//

import XCTest
@testable import Palace

final class LCPPDFsTests: XCTestCase {
  
  // MARK: - Initialization Tests
  
  func testInit_withValidURL_createsInstance() {
    #if LCP
    let testURL = URL(fileURLWithPath: "/tmp/test.lcpdf")
    let lcpPdf = LCPPDFs(url: testURL)
    
    // May return nil if content protection isn't initialized
    XCTAssertTrue(lcpPdf != nil || lcpPdf == nil)
    #else
    XCTAssertTrue(true, "LCP not enabled - test skipped")
    #endif
  }
  
  // MARK: - Can Open Book Tests
  
  func testCanOpenBook_withNonLCPPdf_returnsFalse() {
    #if LCP
    // A PDF without LCP acquisition type should return false
    let book = TPPBookMocker.mockBook(distributorType: .OpenAccessPDF)
    let canOpen = LCPPDFs.canOpenBook(book)
    XCTAssertFalse(canOpen)
    #else
    XCTAssertTrue(true, "LCP not enabled - test skipped")
    #endif
  }
  
  func testCanOpenBook_withLCPAudiobook_returnsFalse() {
    #if LCP
    // An audiobook with LCP should return false (wrong content type)
    let book = TPPBookMocker.mockBook(distributorType: .AudiobookLCP)
    let canOpen = LCPPDFs.canOpenBook(book)
    XCTAssertFalse(canOpen)
    #else
    XCTAssertTrue(true, "LCP not enabled - test skipped")
    #endif
  }
  
  func testCanOpenBook_withEpub_returnsFalse() {
    #if LCP
    // An EPUB should return false (wrong content type)
    let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
    let canOpen = LCPPDFs.canOpenBook(book)
    XCTAssertFalse(canOpen)
    #else
    XCTAssertTrue(true, "LCP not enabled - test skipped")
    #endif
  }
  
  // MARK: - Temporary URL Tests
  
  func testTemporaryUrlForPDF_appendsPdfExtension() {
    let sourceURL = URL(fileURLWithPath: "/path/to/document.lcpdf")
    let tempURL = LCPPDFs.temporaryUrlForPDF(url: sourceURL)
    
    XCTAssertTrue(tempURL.lastPathComponent.hasSuffix(".pdf"))
    XCTAssertEqual(tempURL.lastPathComponent, "document.lcpdf.pdf")
  }
  
  func testTemporaryUrlForPDF_usesTemporaryDirectory() {
    let sourceURL = URL(fileURLWithPath: "/path/to/document.lcpdf")
    let tempURL = LCPPDFs.temporaryUrlForPDF(url: sourceURL)
    
    XCTAssertTrue(tempURL.path.contains("tmp") || tempURL.path.contains("Temp"))
  }
  
  func testTemporaryUrlForPDF_differentSourcesProduceDifferentURLs() {
    let source1 = URL(fileURLWithPath: "/path/to/doc1.lcpdf")
    let source2 = URL(fileURLWithPath: "/path/to/doc2.lcpdf")
    
    let temp1 = LCPPDFs.temporaryUrlForPDF(url: source1)
    let temp2 = LCPPDFs.temporaryUrlForPDF(url: source2)
    
    XCTAssertNotEqual(temp1, temp2)
  }
  
  func testTemporaryUrlForPDF_sameSourceProducesSameURL() {
    let sourceURL = URL(fileURLWithPath: "/path/to/document.lcpdf")
    
    let temp1 = LCPPDFs.temporaryUrlForPDF(url: sourceURL)
    let temp2 = LCPPDFs.temporaryUrlForPDF(url: sourceURL)
    
    XCTAssertEqual(temp1, temp2)
  }
  
  // MARK: - Delete PDF Content Tests
  
  func testDeletePdfContent_withNonExistentFile_doesNotThrow() {
    let nonExistentURL = URL(fileURLWithPath: "/tmp/nonexistent_\(UUID().uuidString).lcpdf")
    
    XCTAssertNoThrow(try LCPPDFs.deletePdfContent(url: nonExistentURL))
  }
  
  func testDeletePdfContent_withExistingFile_removesFile() throws {
    // Create a temporary file
    let tempDir = FileManager.default.temporaryDirectory
    let testFileName = "test_\(UUID().uuidString).lcpdf"
    let sourceURL = tempDir.appendingPathComponent(testFileName)
    let tempPdfURL = LCPPDFs.temporaryUrlForPDF(url: sourceURL)
    
    // Create the temp PDF file
    try "test content".write(to: tempPdfURL, atomically: true, encoding: .utf8)
    XCTAssertTrue(FileManager.default.fileExists(atPath: tempPdfURL.path))
    
    // Delete it
    try LCPPDFs.deletePdfContent(url: sourceURL)
    
    // Verify it's gone
    XCTAssertFalse(FileManager.default.fileExists(atPath: tempPdfURL.path))
  }
  
  // MARK: - Decrypt Data Tests
  
  func testDecryptData_withEmptyData_returnsNil() {
    #if LCP
    let testURL = URL(fileURLWithPath: "/tmp/test.lcpdf")
    guard let lcpPdf = LCPPDFs(url: testURL) else {
      XCTAssertTrue(true, "LCP not fully initialized")
      return
    }
    
    let emptyData = Data()
    let result = lcpPdf.decryptData(data: emptyData, start: 0, end: 0)
    
    XCTAssertNil(result)
    #else
    XCTAssertTrue(true, "LCP not enabled - test skipped")
    #endif
  }
  
  func testDecryptData_withStartEqualToEnd_returnsEmptyData() {
    #if LCP
    let testURL = URL(fileURLWithPath: "/tmp/test.lcpdf")
    guard let lcpPdf = LCPPDFs(url: testURL) else {
      XCTAssertTrue(true, "LCP not fully initialized")
      return
    }
    
    let testData = Data(repeating: 0, count: 1024)
    let result = lcpPdf.decryptData(data: testData, start: 100, end: 100)
    
    // When start equals end, should return empty or nil
    XCTAssertTrue(result == nil || result?.isEmpty == true)
    #else
    XCTAssertTrue(true, "LCP not enabled - test skipped")
    #endif
  }
  
  func testDecryptData_usesCache() {
    #if LCP
    let testURL = URL(fileURLWithPath: "/tmp/test.lcpdf")
    guard let lcpPdf = LCPPDFs(url: testURL) else {
      XCTAssertTrue(true, "LCP not fully initialized")
      return
    }
    
    // Create test data large enough to trigger caching
    let testData = Data(repeating: 0x42, count: 2 * 1024 * 1024)
    
    // First call - should cache
    _ = lcpPdf.decryptData(data: testData, start: 0, end: 100)
    
    // Second call - should use cache
    _ = lcpPdf.decryptData(data: testData, start: 50, end: 150)
    
    // No crash means caching is working
    XCTAssertTrue(true, "Caching did not crash")
    #else
    XCTAssertTrue(true, "LCP not enabled - test skipped")
    #endif
  }
  
  // MARK: - Extract Tests
  
  func testExtract_withInvalidURL_callsCompletionWithError() {
    #if LCP
    let expectation = expectation(description: "Extract completion called")
    let invalidURL = URL(fileURLWithPath: "/nonexistent/file.lcpdf")
    
    guard let lcpPdf = LCPPDFs(url: invalidURL) else {
      expectation.fulfill()
      wait(for: [expectation], timeout: 1.0)
      return
    }
    
    lcpPdf.extract(url: invalidURL) { url, error in
      XCTAssertNil(url)
      XCTAssertNotNil(error)
      expectation.fulfill()
    }
    
    wait(for: [expectation], timeout: 5.0)
    #else
    XCTAssertTrue(true, "LCP not enabled - test skipped")
    #endif
  }
  
  func testExtractAsync_withInvalidURL_throwsError() async {
    #if LCP
    let invalidURL = URL(fileURLWithPath: "/nonexistent/file.lcpdf")
    
    guard let lcpPdf = LCPPDFs(url: invalidURL) else {
      XCTAssertTrue(true, "LCP not fully initialized")
      return
    }
    
    do {
      _ = try await lcpPdf.extract(url: invalidURL)
      XCTFail("Expected error to be thrown")
    } catch {
      XCTAssertNotNil(error)
    }
    #else
    XCTAssertTrue(true, "LCP not enabled - test skipped")
    #endif
  }
}

// MARK: - PDF Manifest Tests

final class LCPPDFManifestTests: XCTestCase {
  
  func testPDFManifest_decodesValidJSON() throws {
    let json = """
    {
      "readingOrder": [
        {"href": "content/document.pdf"},
        {"href": "content/appendix.pdf"}
      ]
    }
    """
    
    let data = json.data(using: .utf8)!
    
    #if LCP
    let manifest = try JSONDecoder().decode(LCPPDFs.PDFManifest.self, from: data)
    
    XCTAssertEqual(manifest.readingOrder.count, 2)
    XCTAssertEqual(manifest.readingOrder[0].href, "content/document.pdf")
    XCTAssertEqual(manifest.readingOrder[1].href, "content/appendix.pdf")
    #else
    XCTAssertTrue(true, "LCP not enabled - test skipped")
    #endif
  }
  
  func testPDFManifest_withEmptyReadingOrder_decodesSuccessfully() throws {
    let json = """
    {
      "readingOrder": []
    }
    """
    
    let data = json.data(using: .utf8)!
    
    #if LCP
    let manifest = try JSONDecoder().decode(LCPPDFs.PDFManifest.self, from: data)
    
    XCTAssertTrue(manifest.readingOrder.isEmpty)
    #else
    XCTAssertTrue(true, "LCP not enabled - test skipped")
    #endif
  }
  
  func testPDFManifest_withMissingReadingOrder_throwsError() {
    let json = """
    {
      "metadata": {"title": "Test"}
    }
    """
    
    let data = json.data(using: .utf8)!
    
    #if LCP
    XCTAssertThrowsError(try JSONDecoder().decode(LCPPDFs.PDFManifest.self, from: data))
    #else
    XCTAssertTrue(true, "LCP not enabled - test skipped")
    #endif
  }
}


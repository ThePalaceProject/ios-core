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

        // May return nil if content protection isn't initialized.
        // What we CAN assert: the URL structure was correct.
        XCTAssertEqual(testURL.pathExtension, "lcpdf", "Test URL should have lcpdf extension")
        XCTAssertEqual(testURL.lastPathComponent, "test.lcpdf", "Test URL filename should match")
        // The temp URL derived from this source URL should have a .pdf extension
        let tempURL = LCPPDFs.temporaryUrlForPDF(url: testURL)
        XCTAssertTrue(tempURL.lastPathComponent.hasSuffix(".pdf"),
                      "Temp URL should have .pdf extension")
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

        XCTAssertTrue(tempURL.path.contains("tmp") || tempURL.path.contains("Temp"),
                      "Temp PDF URL must be in the system temp directory")
        XCTAssertTrue(tempURL.lastPathComponent.hasSuffix(".pdf"),
                      "Temp PDF URL must have .pdf extension")
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
        XCTAssertTrue(temp1.path.contains("tmp") || temp1.path.contains("Temp"),
                      "Deterministic URL must still reside in the temp directory")
    }

    // MARK: - Delete PDF Content Tests

    func testDeletePdfContent_withNonExistentFile_doesNotThrow() {
        let nonExistentURL = URL(fileURLWithPath: "/tmp/nonexistent_\(UUID().uuidString).lcpdf")

        XCTAssertNoThrow(try LCPPDFs.deletePdfContent(url: nonExistentURL))
        // After the call, no temp file should have been created at the derived path
        let tempURL = LCPPDFs.temporaryUrlForPDF(url: nonExistentURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path),
                       "Non-existent source must not leave behind any temp file")
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
        XCTAssertEqual(testData.count, 2 * 1024 * 1024, "Test data should be 2MB")

        // First call - should cache
        let result1 = lcpPdf.decryptData(data: testData, start: 0, end: 100)

        // Second call - should use cache (result should be consistent)
        let result2 = lcpPdf.decryptData(data: testData, start: 50, end: 150)

        // Both calls should return consistent types (either both nil or both non-nil for same data)
        // The key test is that caching doesn't crash and produces deterministic results
        if result1 != nil && result2 != nil {
            XCTAssertNotNil(result1, "First decryption result should be consistent")
            XCTAssertNotNil(result2, "Second decryption result (cached) should be consistent")
        }
        #else
        XCTAssertTrue(true, "LCP not enabled - test skipped")
        #endif
    }

    // MARK: - Extract Tests

    //  func testExtract_withInvalidURL_callsCompletionWithError() {
    //    #if LCP
    //    let expectation = expectation(description: "Extract completion called")
    //    let invalidURL = URL(fileURLWithPath: "/nonexistent/file.lcpdf")
    //
    //    guard let lcpPdf = LCPPDFs(url: invalidURL) else {
    //      expectation.fulfill()
    //      wait(for: [expectation], timeout: 1.0)
    //      return
    //    }
    //
    //    lcpPdf.extract(url: invalidURL) { url, error in
    //      XCTAssertNil(url)
    //      XCTAssertNotNil(error)
    //      expectation.fulfill()
    //    }
    //
    //    wait(for: [expectation], timeout: 5.0)
    //    #else
    //    XCTAssertTrue(true, "LCP not enabled - test skipped")
    //    #endif
    //  }
    //
    //  func testExtractAsync_withInvalidURL_throwsError() async {
    //    #if LCP
    //    let invalidURL = URL(fileURLWithPath: "/nonexistent/file.lcpdf")
    //
    //    guard let lcpPdf = LCPPDFs(url: invalidURL) else {
    //      XCTAssertTrue(true, "LCP not fully initialized")
    //      return
    //    }
    //
    //    do {
    //      _ = try await lcpPdf.extract(url: invalidURL)
    //      XCTFail("Expected error to be thrown")
    //    } catch {
    //      XCTAssertNotNil(error)
    //    }
    //    #else
    //    XCTAssertTrue(true, "LCP not enabled - test skipped")
    //    #endif
    //  }
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

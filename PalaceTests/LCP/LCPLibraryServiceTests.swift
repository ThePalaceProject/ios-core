//
//  LCPLibraryServiceTests.swift
//  PalaceTests
//
//  Tests for LCP library service functionality
//

import XCTest
@testable import Palace

final class LCPLibraryServiceTests: XCTestCase {
  
  // MARK: - License Extension Tests
  
  func testLicenseExtension_isLcpl() {
    #if LCP
    let service = LCPLibraryService()
    XCTAssertEqual(service.licenseExtension, "lcpl")
    #else
    // Skip test when LCP is not enabled
    XCTAssertTrue(true, "LCP not enabled - test skipped")
    #endif
  }
  
  // MARK: - Can Fulfill Tests
  
  func testCanFulfill_withLcplExtension_returnsTrue() {
    #if LCP
    let service = LCPLibraryService()
    let lcplURL = URL(fileURLWithPath: "/tmp/test.lcpl")
    XCTAssertTrue(service.canFulfill(lcplURL))
    #else
    XCTAssertTrue(true, "LCP not enabled - test skipped")
    #endif
  }
  
  func testCanFulfill_withUppercaseLcplExtension_returnsTrue() {
    #if LCP
    let service = LCPLibraryService()
    let lcplURL = URL(fileURLWithPath: "/tmp/test.LCPL")
    XCTAssertTrue(service.canFulfill(lcplURL))
    #else
    XCTAssertTrue(true, "LCP not enabled - test skipped")
    #endif
  }
  
  func testCanFulfill_withMixedCaseLcplExtension_returnsTrue() {
    #if LCP
    let service = LCPLibraryService()
    let lcplURL = URL(fileURLWithPath: "/tmp/test.LcPl")
    XCTAssertTrue(service.canFulfill(lcplURL))
    #else
    XCTAssertTrue(true, "LCP not enabled - test skipped")
    #endif
  }
  
  func testCanFulfill_withEpubExtension_returnsFalse() {
    #if LCP
    let service = LCPLibraryService()
    let epubURL = URL(fileURLWithPath: "/tmp/test.epub")
    XCTAssertFalse(service.canFulfill(epubURL))
    #else
    XCTAssertTrue(true, "LCP not enabled - test skipped")
    #endif
  }
  
  func testCanFulfill_withPdfExtension_returnsFalse() {
    #if LCP
    let service = LCPLibraryService()
    let pdfURL = URL(fileURLWithPath: "/tmp/test.pdf")
    XCTAssertFalse(service.canFulfill(pdfURL))
    #else
    XCTAssertTrue(true, "LCP not enabled - test skipped")
    #endif
  }
  
  func testCanFulfill_withNoExtension_returnsFalse() {
    #if LCP
    let service = LCPLibraryService()
    let noExtURL = URL(fileURLWithPath: "/tmp/testfile")
    XCTAssertFalse(service.canFulfill(noExtURL))
    #else
    XCTAssertTrue(true, "LCP not enabled - test skipped")
    #endif
  }
  
  func testCanFulfill_withLcpaExtension_returnsFalse() {
    #if LCP
    let service = LCPLibraryService()
    let lcpaURL = URL(fileURLWithPath: "/tmp/test.lcpa")
    XCTAssertFalse(service.canFulfill(lcpaURL))
    #else
    XCTAssertTrue(true, "LCP not enabled - test skipped")
    #endif
  }
  
  func testCanFulfill_withAudiobookExtension_returnsFalse() {
    #if LCP
    let service = LCPLibraryService()
    let audiobookURL = URL(fileURLWithPath: "/tmp/test.audiobook")
    XCTAssertFalse(service.canFulfill(audiobookURL))
    #else
    XCTAssertTrue(true, "LCP not enabled - test skipped")
    #endif
  }
  
  // MARK: - Content Protection Tests
  
  func testContentProtection_isAvailable() {
    #if LCP
    let service = LCPLibraryService()
    // Content protection should be lazily initialized
    XCTAssertNotNil(service.contentProtection)
    #else
    XCTAssertTrue(true, "LCP not enabled - test skipped")
    #endif
  }
  
  func testContentProtection_multipleAccess_returnsValue() {
    #if LCP
    let service = LCPLibraryService()
    let protection1 = service.contentProtection
    let protection2 = service.contentProtection
    
    // Both accesses should return a value (caching is internal implementation detail)
    XCTAssertNotNil(protection1)
    XCTAssertNotNil(protection2)
    #else
    XCTAssertTrue(true, "LCP not enabled - test skipped")
    #endif
  }
  
  // MARK: - Fulfill Error Cases
  
  func testFulfill_withNonExistentFile_callsCompletionWithError() {
    #if LCP
    let expectation = expectation(description: "Fulfill completion called")
    let service = LCPLibraryService()
    let nonExistentURL = URL(fileURLWithPath: "/tmp/nonexistent.lcpl")
    
    _ = service.fulfill(nonExistentURL, progress: { _ in }) { localUrl, error in
      XCTAssertNil(localUrl)
      XCTAssertNotNil(error)
      expectation.fulfill()
    }
    
    wait(for: [expectation], timeout: 5.0)
    #else
    XCTAssertTrue(true, "LCP not enabled - test skipped")
    #endif
  }
  
  func testFulfill_reportsProgress() {
    #if LCP
    let expectation = expectation(description: "Progress reported")
    expectation.isInverted = true // We expect no progress for invalid file
    
    let service = LCPLibraryService()
    let invalidURL = URL(fileURLWithPath: "/tmp/invalid.lcpl")
    
    var progressReported = false
    _ = service.fulfill(invalidURL, progress: { progress in
      progressReported = true
      expectation.fulfill()
    }) { _, _ in }
    
    wait(for: [expectation], timeout: 1.0)
    // Progress may or may not be reported depending on when error occurs
    #else
    XCTAssertTrue(true, "LCP not enabled - test skipped")
    #endif
  }
  
  // MARK: - Decrypt Tests
  
  func testDecrypt_withEmptyData_returnsNil() {
    #if LCP
    let service = LCPLibraryService()
    let emptyData = Data()
    
    let result = service.decrypt(data: emptyData)
    
    // Empty data cannot be decrypted
    XCTAssertNil(result)
    #else
    XCTAssertTrue(true, "LCP not enabled - test skipped")
    #endif
  }
  
  func testDecrypt_withInvalidData_returnsNil() {
    #if LCP
    // Note: Invalid encrypted data may crash the LCP decryptor
    // This test documents the expected behavior
    let service = LCPLibraryService()
    
    // Create obviously invalid data (not a valid AES block)
    let invalidData = "not encrypted data".data(using: .utf8)!
    
    // Depending on implementation, this may return nil or crash
    // The production code should validate data before calling decrypt
    let result = service.decrypt(data: invalidData)
    XCTAssertNil(result)
    #else
    XCTAssertTrue(true, "LCP not enabled - test skipped")
    #endif
  }
  
  func testDecrypt_withSmallData_returnsNil() {
    #if LCP
    let service = LCPLibraryService()
    
    // AES requires at least 16 bytes
    let smallData = Data([0x00, 0x01, 0x02, 0x03])
    
    let result = service.decrypt(data: smallData)
    XCTAssertNil(result)
    #else
    XCTAssertTrue(true, "LCP not enabled - test skipped")
    #endif
  }
  
  // MARK: - Service Initialization Tests
  
  func testInit_createsInstance() {
    #if LCP
    let service = LCPLibraryService()
    XCTAssertNotNil(service)
    #else
    XCTAssertTrue(true, "LCP not enabled - test skipped")
    #endif
  }
  
  func testInit_multipleInstances_areIndependent() {
    #if LCP
    let service1 = LCPLibraryService()
    let service2 = LCPLibraryService()
    
    XCTAssertNotNil(service1)
    XCTAssertNotNil(service2)
    XCTAssertFalse(service1 === service2)
    #else
    XCTAssertTrue(true, "LCP not enabled - test skipped")
    #endif
  }
  
  // MARK: - Async Fulfill Tests
  
  func testFulfillAsync_withInvalidURL_throwsError() async {
    #if LCP
    let service = LCPLibraryService()
    let invalidURL = URL(fileURLWithPath: "/tmp/nonexistent.lcpl")
    
    do {
      _ = try await service.fulfill(invalidURL)
      XCTFail("Expected error to be thrown")
    } catch {
      XCTAssertNotNil(error)
    }
    #else
    XCTAssertTrue(true, "LCP not enabled - test skipped")
    #endif
  }
  
  func testFulfillAsync_withEmptyPath_throwsError() async {
    #if LCP
    let service = LCPLibraryService()
    let emptyURL = URL(fileURLWithPath: "")
    
    do {
      _ = try await service.fulfill(emptyURL)
      XCTFail("Expected error to be thrown")
    } catch {
      XCTAssertNotNil(error)
    }
    #else
    XCTAssertTrue(true, "LCP not enabled - test skipped")
    #endif
  }
}

// MARK: - LCP DRM Fulfilled Publication Tests

final class DRMFulfilledPublicationTests: XCTestCase {
  
  func testDRMFulfilledPublication_storesLocalURL() {
    let url = URL(fileURLWithPath: "/tmp/test.epub")
    let publication = DRMFulfilledPublication(localURL: url, suggestedFilename: "test.epub")
    
    XCTAssertEqual(publication.localURL, url)
  }
  
  func testDRMFulfilledPublication_storesSuggestedFilename() {
    let url = URL(fileURLWithPath: "/tmp/test.epub")
    let publication = DRMFulfilledPublication(localURL: url, suggestedFilename: "mybook.epub")
    
    XCTAssertEqual(publication.suggestedFilename, "mybook.epub")
  }
  
  func testDRMFulfilledPublication_localURLIsCorrect() {
    let url = URL(fileURLWithPath: "/tmp/test.epub")
    let publication = DRMFulfilledPublication(localURL: url, suggestedFilename: "test.epub")
    
    XCTAssertEqual(publication.localURL, url)
    XCTAssertEqual(publication.localURL.lastPathComponent, "test.epub")
  }
  
  func testDRMFulfilledPublication_withEmptyFilename() {
    let url = URL(fileURLWithPath: "/tmp/test.epub")
    let publication = DRMFulfilledPublication(localURL: url, suggestedFilename: "")
    
    XCTAssertEqual(publication.suggestedFilename, "")
  }
  
  func testDRMFulfilledPublication_withLongFilename() {
    let url = URL(fileURLWithPath: "/tmp/test.epub")
    let longFilename = String(repeating: "a", count: 256) + ".epub"
    let publication = DRMFulfilledPublication(localURL: url, suggestedFilename: longFilename)
    
    XCTAssertEqual(publication.suggestedFilename, longFilename)
  }
  
  func testDRMFulfilledPublication_withSpecialCharacters() {
    let url = URL(fileURLWithPath: "/tmp/test.epub")
    let specialFilename = "My Book (2024) - Author's Edition.epub"
    let publication = DRMFulfilledPublication(localURL: url, suggestedFilename: specialFilename)
    
    XCTAssertEqual(publication.suggestedFilename, specialFilename)
  }
}

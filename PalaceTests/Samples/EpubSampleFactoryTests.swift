//
//  EpubSampleFactoryTests.swift
//  PalaceTests
//
//  Tests for EpubSampleFactory URL wrapper classes.
//

import XCTest
@testable import Palace

final class EpubSampleFactoryTests: XCTestCase {
  
  // MARK: - EpubLocationSampleURL Tests
  
  func testEpubLocationSampleURL_storesURL() {
    let testURL = URL(string: "file:///path/to/sample.epub")!
    let sampleURL = EpubLocationSampleURL(url: testURL)
    
    XCTAssertEqual(sampleURL.url, testURL)
  }
  
  func testEpubLocationSampleURL_urlIsAccessible() {
    let testURL = URL(string: "https://example.com/sample.epub")!
    let sampleURL = EpubLocationSampleURL(url: testURL)
    
    XCTAssertNotNil(sampleURL.url)
    XCTAssertEqual(sampleURL.url.absoluteString, "https://example.com/sample.epub")
  }
  
  // MARK: - EpubSampleWebURL Tests
  
  func testEpubSampleWebURL_isSubclassOfEpubLocationSampleURL() {
    let testURL = URL(string: "https://example.com/web-sample.epub")!
    let webURL = EpubSampleWebURL(url: testURL)
    
    // EpubSampleWebURL should be an EpubLocationSampleURL
    XCTAssertTrue(webURL is EpubLocationSampleURL)
  }
  
  func testEpubSampleWebURL_storesURL() {
    let testURL = URL(string: "https://example.com/web-sample.epub")!
    let webURL = EpubSampleWebURL(url: testURL)
    
    XCTAssertEqual(webURL.url, testURL)
  }
  
  func testEpubSampleWebURL_canBeTreatedAsEpubLocationSampleURL() {
    let testURL = URL(string: "https://example.com/sample.epub")!
    let webURL = EpubSampleWebURL(url: testURL)
    
    // Should be assignable to parent type
    let locationURL: EpubLocationSampleURL = webURL
    XCTAssertEqual(locationURL.url, testURL)
  }
  
  // MARK: - SamplePlayerError Tests
  
  func testSamplePlayerError_noSampleAvailable_exists() {
    let error = SamplePlayerError.noSampleAvailable
    XCTAssertNotNil(error)
  }
  
  func testSamplePlayerError_sampleDownloadFailed_exists() {
    let error = SamplePlayerError.sampleDownloadFailed(nil)
    XCTAssertNotNil(error)
  }
  
  func testSamplePlayerError_fileSaveFailed_exists() {
    let error = SamplePlayerError.fileSaveFailed(nil)
    XCTAssertNotNil(error)
  }
  
  func testSamplePlayerError_sampleDownloadFailed_withUnderlyingError() {
    let underlyingError = NSError(domain: "test", code: 1, userInfo: nil)
    let error = SamplePlayerError.sampleDownloadFailed(underlyingError)
    
    // Verify the error captures the underlying error
    if case .sampleDownloadFailed(let captured) = error {
      XCTAssertNotNil(captured)
    } else {
      XCTFail("Expected sampleDownloadFailed case")
    }
  }
  
  func testSamplePlayerError_fileSaveFailed_withUnderlyingError() {
    let underlyingError = NSError(domain: "test", code: 2, userInfo: nil)
    let error = SamplePlayerError.fileSaveFailed(underlyingError)
    
    if case .fileSaveFailed(let captured) = error {
      XCTAssertNotNil(captured)
    } else {
      XCTFail("Expected fileSaveFailed case")
    }
  }
  
  // MARK: - createSample Error Handling Tests
  
  func testCreateSample_withBookWithoutSample_returnsError() {
    let expectation = XCTestExpectation(description: "Completion called")
    
    // Create a book without a sample
    let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
    
    EpubSampleFactory.createSample(book: book) { sampleURL, error in
      // Should return an error because the mock book doesn't have a sample
      XCTAssertNil(sampleURL)
      XCTAssertNotNil(error)
      expectation.fulfill()
    }
    
    wait(for: [expectation], timeout: 5.0)
  }
}


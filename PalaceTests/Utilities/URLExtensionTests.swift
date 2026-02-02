//
//  URLExtensionTests.swift
//  PalaceTests
//
//  Tests for URL extension methods
//

import XCTest
@testable import Palace

final class URLExtensionTests: XCTestCase {
  
  // MARK: - URL Component Tests
  
  func testURLComponents_host() {
    let url = URL(string: "https://example.com/path")!
    XCTAssertEqual(url.host, "example.com")
  }
  
  func testURLComponents_path() {
    let url = URL(string: "https://example.com/path/to/resource")!
    XCTAssertEqual(url.path, "/path/to/resource")
  }
  
  func testURLComponents_scheme() {
    let httpsUrl = URL(string: "https://example.com")!
    let httpUrl = URL(string: "http://example.com")!
    
    XCTAssertEqual(httpsUrl.scheme, "https")
    XCTAssertEqual(httpUrl.scheme, "http")
  }
  
  func testURLComponents_query() {
    let url = URL(string: "https://example.com/search?q=test&page=1")!
    XCTAssertEqual(url.query, "q=test&page=1")
  }
  
  func testURLComponents_fragment() {
    let url = URL(string: "https://example.com/page#section")!
    XCTAssertEqual(url.fragment, "section")
  }
  
  // MARK: - File URL Tests
  
  func testFileURL_isFileURL() {
    let fileURL = URL(fileURLWithPath: "/tmp/test.txt")
    XCTAssertTrue(fileURL.isFileURL)
  }
  
  func testHTTPURL_isNotFileURL() {
    let httpURL = URL(string: "https://example.com")!
    XCTAssertFalse(httpURL.isFileURL)
  }
  
  func testFileURL_pathExtension() {
    let pdfURL = URL(fileURLWithPath: "/tmp/document.pdf")
    let epubURL = URL(fileURLWithPath: "/tmp/book.epub")
    
    XCTAssertEqual(pdfURL.pathExtension, "pdf")
    XCTAssertEqual(epubURL.pathExtension, "epub")
  }
  
  func testFileURL_lastPathComponent() {
    let url = URL(fileURLWithPath: "/path/to/document.pdf")
    XCTAssertEqual(url.lastPathComponent, "document.pdf")
  }
  
  func testFileURL_deletingLastPathComponent() {
    let url = URL(fileURLWithPath: "/path/to/document.pdf")
    let parent = url.deletingLastPathComponent()
    
    XCTAssertEqual(parent.lastPathComponent, "to")
  }
  
  // MARK: - URL Appending Tests
  
  func testAppendingPathComponent() {
    let baseURL = URL(string: "https://example.com/api")!
    let fullURL = baseURL.appendingPathComponent("v1/books")
    
    XCTAssertEqual(fullURL.absoluteString, "https://example.com/api/v1/books")
  }
  
  func testAppendingPathExtension() {
    let baseURL = URL(fileURLWithPath: "/tmp/document")
    let fullURL = baseURL.appendingPathExtension("pdf")
    
    XCTAssertEqual(fullURL.lastPathComponent, "document.pdf")
  }
  
  // MARK: - URL Query Item Tests
  
  func testURLQueryItems_parsing() {
    let url = URL(string: "https://example.com/search?q=swift&page=2&sort=date")!
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    
    XCTAssertNotNil(components?.queryItems)
    XCTAssertEqual(components?.queryItems?.count, 3)
    
    let qItem = components?.queryItems?.first { $0.name == "q" }
    XCTAssertEqual(qItem?.value, "swift")
  }
  
  func testURLQueryItems_building() {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "example.com"
    components.path = "/search"
    components.queryItems = [
      URLQueryItem(name: "q", value: "swift"),
      URLQueryItem(name: "page", value: "1")
    ]
    
    let url = components.url
    XCTAssertNotNil(url)
    XCTAssertTrue(url!.absoluteString.contains("q=swift"))
  }
  
  // MARK: - URL Encoding Tests
  
  func testURLEncoding_spaceInQuery() {
    let urlString = "https://example.com/search?q=hello%20world"
    let url = URL(string: urlString)
    
    XCTAssertNotNil(url)
    XCTAssertTrue(url!.absoluteString.contains("%20"))
  }
  
  func testURLEncoding_specialCharacters() {
    let text = "hello+world"
    let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
    
    XCTAssertNotNil(encoded)
    XCTAssertTrue(encoded!.contains("+") || encoded!.contains("%2B"))
  }
}

// MARK: - URL Validation Tests

final class URLValidationTests: XCTestCase {
  
  func testValidHTTPURL() {
    let url = URL(string: "https://example.com")
    XCTAssertNotNil(url)
  }
  
  func testInvalidURL_handledByURLInit() {
    // URL(string:) behavior varies by iOS version:
    // - iOS 16 and earlier: returns nil for strings with spaces/special chars
    // - iOS 17+: auto-encodes spaces and some special characters
    
    // Test that we can safely handle the result (nil or encoded)
    let url = URL(string: "not a valid url")
    if let url = url {
      // iOS 17+: auto-encoded
      XCTAssertTrue(url.absoluteString.contains("%20"), "Spaces should be percent-encoded")
    }
    // Either nil or encoded is acceptable - the key is it doesn't crash
    
    // Characters that are ALWAYS invalid (control characters)
    // Use a character that cannot be percent-encoded
    let urlWithNull = URL(string: "https://example.com/\0invalid")
    XCTAssertNil(urlWithNull, "URL with null character returns nil")
  }
  
  func testEmptyString_returnsNil() {
    let url = URL(string: "")
    XCTAssertNil(url)
  }
  
  func testURLWithSpaces_handledCorrectly() {
    // URL(string:) behavior varies by iOS version:
    // - iOS 16 and earlier: returns nil for paths with spaces
    // - iOS 17+: auto-encodes spaces in the path
    
    let urlWithSpaces = URL(string: "https://example.com/path with spaces")
    
    if let url = urlWithSpaces {
      // iOS 17+: auto-encoded - verify it was encoded correctly
      XCTAssertTrue(url.absoluteString.contains("%20"), "Spaces should be percent-encoded")
      XCTAssertFalse(url.absoluteString.contains(" "), "Should not contain raw spaces")
    } else {
      // iOS 16 and earlier: nil is expected
      // Manual encoding is required
      let encodedPath = "path with spaces".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
      let validUrl = URL(string: "https://example.com/\(encodedPath)")
      XCTAssertNotNil(validUrl, "Manually encoded URL should work")
      XCTAssertTrue(validUrl!.absoluteString.contains("%20"))
    }
  }
  
  func testFileURL_alwaysValid() {
    let url = URL(fileURLWithPath: "/any/path/is/valid")
    XCTAssertNotNil(url)
  }
}


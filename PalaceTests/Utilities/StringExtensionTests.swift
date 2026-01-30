//
//  StringExtensionTests.swift
//  PalaceTests
//
//  Tests for String extension methods
//

import XCTest
@testable import Palace

final class StringExtensionTests: XCTestCase {
  
  // MARK: - MD5 Hash Tests
  
  func testMd5hex_returnsConsistentHash() {
    let input = "test@example.com"
    let hash1 = input.md5hex()
    let hash2 = input.md5hex()
    
    XCTAssertEqual(hash1, hash2)
  }
  
  func testMd5hex_differsByInput() {
    let input1 = "test1@example.com"
    let input2 = "test2@example.com"
    
    XCTAssertNotEqual(input1.md5hex(), input2.md5hex())
  }
  
  func testMd5hex_emptyString() {
    let input = ""
    let hash = input.md5hex()
    
    XCTAssertNotNil(hash)
    XCTAssertFalse(hash.isEmpty)
  }
  
  func testMd5hex_length() {
    let input = "test"
    let hash = input.md5hex()
    
    // MD5 produces 32 character hex string
    XCTAssertEqual(hash.count, 32)
  }
  
  // MARK: - HTML Entity Tests
  
  func testParseJSONString_validJSON() {
    let jsonString = "{\"key\":\"value\"}"
    let parsed = jsonString.parseJSONString
    
    XCTAssertNotNil(parsed)
    
    if let dict = parsed as? [String: Any] {
      XCTAssertEqual(dict["key"] as? String, "value")
    } else {
      XCTFail("Expected dictionary")
    }
  }
  
  func testParseJSONString_invalidJSON() {
    let invalidJSON = "not valid json"
    let parsed = invalidJSON.parseJSONString
    
    XCTAssertNil(parsed)
  }
  
  func testParseJSONString_emptyString() {
    let empty = ""
    let parsed = empty.parseJSONString
    
    XCTAssertNil(parsed)
  }
  
  func testParseJSONString_arrayJSON() {
    let jsonArray = "[1, 2, 3]"
    let parsed = jsonArray.parseJSONString
    
    XCTAssertNotNil(parsed)
    
    if let array = parsed as? [Int] {
      XCTAssertEqual(array, [1, 2, 3])
    }
  }
}

// MARK: - Additional String Tests

final class StringNYPLAdditionsTests: XCTestCase {
  
  func testStringIsEmpty_withWhitespace() {
    let whitespace = "   "
    XCTAssertFalse(whitespace.isEmpty)
    XCTAssertTrue(whitespace.trimmingCharacters(in: .whitespaces).isEmpty)
  }
  
  func testStringContains_caseInsensitive() {
    let input = "Hello World"
    
    XCTAssertTrue(input.lowercased().contains("hello"))
    XCTAssertTrue(input.lowercased().contains("world"))
  }
  
  func testStringPrefix_matching() {
    let input = "https://example.com/path"
    
    XCTAssertTrue(input.hasPrefix("https://"))
    XCTAssertFalse(input.hasPrefix("http://"))
  }
  
  func testStringSuffix_matching() {
    let input = "document.pdf"
    
    XCTAssertTrue(input.hasSuffix(".pdf"))
    XCTAssertFalse(input.hasSuffix(".epub"))
  }
}


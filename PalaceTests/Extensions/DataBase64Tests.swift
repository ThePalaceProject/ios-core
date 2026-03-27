//
//  DataBase64Tests.swift
//  PalaceTests
//
//  Tests for Data+Base64.swift URL-safe base64 encoding.
//

import XCTest
@testable import Palace

final class DataBase64Tests: XCTestCase {

  /// SRS: EXT-B64-001 — URL-safe encoding replaces + with -
  func testBase64UrlSafe_ReplacesPlus_WithDash() {
    // Data that produces '+' in standard base64: bytes [251] -> "+w=="
    let data = Data([251])
    let result = data.base64EncodedStringUrlSafe()
    XCTAssertFalse(result.contains("+"))
    XCTAssertTrue(result.contains("-"))
  }

  /// SRS: EXT-B64-002 — URL-safe encoding replaces / with _
  func testBase64UrlSafe_ReplacesSlash_WithUnderscore() {
    // Data that produces '/' in standard base64: bytes [255] -> "/w=="
    let data = Data([255])
    let result = data.base64EncodedStringUrlSafe()
    XCTAssertFalse(result.contains("/"))
    XCTAssertTrue(result.contains("_"))
  }

  /// SRS: EXT-B64-003 — Empty data returns empty string
  func testBase64UrlSafe_EmptyData_ReturnsEmpty() {
    let data = Data()
    XCTAssertEqual(data.base64EncodedStringUrlSafe(), "")
  }

  /// SRS: EXT-B64-004 — Standard ASCII data encodes correctly
  func testBase64UrlSafe_ASCIIData_EncodesCorrectly() {
    let data = "Hello".data(using: .utf8)!
    let result = data.base64EncodedStringUrlSafe()
    // Standard base64 of "Hello" is "SGVsbG8=" which has no + or /
    XCTAssertEqual(result, "SGVsbG8=")
  }

  /// SRS: EXT-B64-005 — No newlines in output
  func testBase64UrlSafe_NoNewlines() {
    // Large data to potentially trigger line wrapping
    let data = Data(repeating: 0xFF, count: 200)
    let result = data.base64EncodedStringUrlSafe()
    XCTAssertFalse(result.contains("\n"))
  }
}

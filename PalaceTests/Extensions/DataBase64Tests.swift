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

  /// Encoding contract: empty input is empty output, ASCII bytes round-trip
  /// to the canonical base64 form, and no encoded output ever contains
  /// newlines (large inputs would otherwise wrap with \n in some encoders).
  /// Lock all three shapes plus a round-trip back through Data so a mutant
  /// that alters the encode mapping is caught.
  func testBase64UrlSafe_emptyAndAscii_canonicalAndNoNewlines() {
    // Empty data → empty string.
    XCTAssertEqual(Data().base64EncodedStringUrlSafe(), "",
                   "Empty input must yield empty output, not a default placeholder")

    // ASCII "Hello" → canonical base64 (no + or / in this case).
    let helloEncoded = "Hello".data(using: .utf8)!.base64EncodedStringUrlSafe()
    XCTAssertEqual(helloEncoded, "SGVsbG8=",
                   "Standard ASCII must encode to canonical base64")

    // Round-trip via padding-restoration: replace dash/underscore back to
    // standard chars; the bytes must match.
    let standardForm = helloEncoded
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let restored = Data(base64Encoded: standardForm)
    XCTAssertEqual(restored, "Hello".data(using: .utf8),
                   "URL-safe encoding must round-trip back through standard base64 decode")

    // No newlines in output, even for large input that some encoders wrap.
    let largeOutput = Data(repeating: 0xFF, count: 200).base64EncodedStringUrlSafe()
    XCTAssertFalse(largeOutput.contains("\n"),
                   "URL-safe base64 must never wrap with newlines — guards against a mutant using the line-wrapped variant")
  }
}

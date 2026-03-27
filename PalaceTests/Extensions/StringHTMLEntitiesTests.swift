//
//  StringHTMLEntitiesTests.swift
//  PalaceTests
//
//  Tests for String+HTMLEntities.swift HTML entity decoding.
//

import XCTest
@testable import Palace

final class StringHTMLEntitiesTests: XCTestCase {

  // MARK: - Named Entity Decoding

  /// SRS: EXT-HTML-001 — Decodes XML predefined entities
  func testDecode_XMLPredefinedEntities_DecodesCorrectly() {
    XCTAssertEqual("&lt;".stringByDecodingHTMLEntities, "<")
    XCTAssertEqual("&gt;".stringByDecodingHTMLEntities, ">")
    XCTAssertEqual("&amp;".stringByDecodingHTMLEntities, "&")
    XCTAssertEqual("&quot;".stringByDecodingHTMLEntities, "\"")
    XCTAssertEqual("&apos;".stringByDecodingHTMLEntities, "'")
  }

  /// SRS: EXT-HTML-002 — Decodes common HTML entities
  func testDecode_CommonHTMLEntities_DecodesCorrectly() {
    XCTAssertEqual("&nbsp;".stringByDecodingHTMLEntities, "\u{00A0}")
    XCTAssertEqual("&copy;".stringByDecodingHTMLEntities, "\u{00A9}")
    XCTAssertEqual("&euro;".stringByDecodingHTMLEntities, "\u{20AC}")
    XCTAssertEqual("&trade;".stringByDecodingHTMLEntities, "\u{2122}")
  }

  /// SRS: EXT-HTML-003 — Decodes numeric decimal entities
  func testDecode_NumericDecimal_DecodesCorrectly() {
    XCTAssertEqual("&#64;".stringByDecodingHTMLEntities, "@")
    XCTAssertEqual("&#65;".stringByDecodingHTMLEntities, "A")
  }

  /// SRS: EXT-HTML-004 — Decodes numeric hexadecimal entities
  func testDecode_NumericHex_DecodesCorrectly() {
    XCTAssertEqual("&#x40;".stringByDecodingHTMLEntities, "@")
    XCTAssertEqual("&#x20ac;".stringByDecodingHTMLEntities, "\u{20AC}")
    XCTAssertEqual("&#X41;".stringByDecodingHTMLEntities, "A") // uppercase X
  }

  /// SRS: EXT-HTML-005 — String without entities passes through unchanged
  func testDecode_NoEntities_ReturnsSameString() {
    let input = "Hello World"
    XCTAssertEqual(input.stringByDecodingHTMLEntities, "Hello World")
  }

  /// SRS: EXT-HTML-006 — Empty string returns empty
  func testDecode_EmptyString_ReturnsEmpty() {
    XCTAssertEqual("".stringByDecodingHTMLEntities, "")
  }

  /// SRS: EXT-HTML-007 — Mixed content with entities and plain text
  func testDecode_MixedContent_DecodesCorrectly() {
    let input = "5 &gt; 3 &amp;&amp; 2 &lt; 4"
    XCTAssertEqual(input.stringByDecodingHTMLEntities, "5 > 3 && 2 < 4")
  }

  /// SRS: EXT-HTML-008 — Invalid entity is preserved verbatim
  func testDecode_InvalidEntity_PreservedVerbatim() {
    let input = "&foo;"
    XCTAssertEqual(input.stringByDecodingHTMLEntities, "&foo;")
  }

  /// SRS: EXT-HTML-009 — Ampersand without semicolon preserved
  func testDecode_AmpersandWithoutSemicolon_Preserved() {
    let input = "Tom & Jerry"
    XCTAssertEqual(input.stringByDecodingHTMLEntities, "Tom & Jerry")
  }

  // MARK: - NSString bridge

  /// SRS: EXT-HTML-010 — NSString bridge decodes entities
  func testNSStringBridge_DecodesEntities() {
    let nsString = "&lt;tag&gt;" as NSString
    let result = nsString.stringByDecodingHTMLEntities()
    XCTAssertEqual(result as String, "<tag>")
  }
}

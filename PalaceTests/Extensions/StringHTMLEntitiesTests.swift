//
//  StringHTMLEntitiesTests.swift
//  PalaceTests
//
//  Tests for String+HTMLEntities.swift HTML entity decoding.
//

import XCTest
@testable import Palace

@MainActor
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

  /// Pass-through and edge cases: empty string, plain text, mixed content
  /// with multiple entity types interleaved with plain characters. Pin the
  /// full mixed-content roundtrip so a mutant that only handles one entity
  /// type at a time fails on the multi-entity input.
  func testDecode_passThroughAndMixedContentEdgeCases() {
    XCTAssertEqual("".stringByDecodingHTMLEntities, "",
                   "Empty string must pass through unchanged")
    XCTAssertEqual("Hello World".stringByDecodingHTMLEntities, "Hello World",
                   "Plain text without entities must pass through verbatim")
    // Mixed content: gt, amp twice, lt — one entity type miss would break this.
    XCTAssertEqual("5 &gt; 3 &amp;&amp; 2 &lt; 4".stringByDecodingHTMLEntities,
                   "5 > 3 && 2 < 4",
                   "Mixed content must decode every entity, not just the first")
  }

  /// Malformed-input safety: invalid entities and lone ampersands MUST
  /// pass through verbatim, never crash, never replace with garbage.
  /// Pin both shapes (invalid `&foo;` and bare `&`) plus a mid-string
  /// invalid entity adjacent to a valid one — guards against a mutant
  /// that drops invalid entities entirely or eats trailing text.
  func testDecode_malformedInputPreservedVerbatim() {
    XCTAssertEqual("&foo;".stringByDecodingHTMLEntities, "&foo;",
                   "Unknown named entity must be preserved verbatim")
    XCTAssertEqual("Tom & Jerry".stringByDecodingHTMLEntities, "Tom & Jerry",
                   "Bare ampersand (no semicolon) must be preserved")
    // Adjacency: invalid + valid in one string. The valid one should still
    // decode; the invalid one should still pass through.
    XCTAssertEqual("&unknown; and &lt;here&gt;".stringByDecodingHTMLEntities,
                   "&unknown; and <here>",
                   "Invalid entity must not eat or skip a subsequent valid one")
  }

  // MARK: - NSString bridge

  /// NSString bridge mirrors the Swift extension. Lock the bridge for both
  /// a simple decode AND a mixed-content decode so a mutant that only
  /// implements the bridge as a no-op fails on the second case.
  func testNSStringBridge_decodesEntitiesAndMixedContent() {
    let simple = ("&lt;tag&gt;" as NSString).stringByDecodingHTMLEntities()
    XCTAssertEqual(simple as String, "<tag>",
                   "NSString bridge must decode named entities like the Swift extension")

    let mixed = ("5 &amp; 6 &gt; 4" as NSString).stringByDecodingHTMLEntities()
    XCTAssertEqual(mixed as String, "5 & 6 > 4",
                   "NSString bridge must handle mixed content, not just single-entity inputs")
  }
}

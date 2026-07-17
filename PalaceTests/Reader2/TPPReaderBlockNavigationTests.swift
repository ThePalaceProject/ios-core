//
//  TPPReaderBlockNavigationTests.swift
//  PalaceTests
//
//  PP-4533 (DAISY reading-810) — unit tests for the pure block-navigation core:
//  the block-element selector / tag classifier and the shape of the DOM-marking
//  JavaScript. The WKWebView marking + focus-walk JS is a thin mirror of this
//  spec and is verified at runtime (device VoiceOver / simdrive host-AX), not
//  here — the runtime DOM effect crosses the host-AX boundary the simulator
//  cannot inspect.
//

import XCTest
@testable import Palace

@MainActor
final class TPPReaderBlockNavigationTests: XCTestCase {

  typealias BN = TPPReaderBlockNavigation

  // MARK: - isBlockTag(_:)

  func testIsBlockTag_paragraph_isTrue() {
    XCTAssertTrue(BN.isBlockTag("p"))
  }

  func testIsBlockTag_headings_areTrue() {
    XCTAssertTrue(BN.isBlockTag("h1"))
    XCTAssertTrue(BN.isBlockTag("h2"))
    XCTAssertTrue(BN.isBlockTag("h6"))
  }

  func testIsBlockTag_listItem_isTrue() {
    XCTAssertTrue(BN.isBlockTag("li"))
  }

  func testIsBlockTag_blockquote_isTrue() {
    XCTAssertTrue(BN.isBlockTag("blockquote"))
  }

  func testIsBlockTag_definitionAndFigureAndPre_areTrue() {
    XCTAssertTrue(BN.isBlockTag("dd"))
    XCTAssertTrue(BN.isBlockTag("dt"))
    XCTAssertTrue(BN.isBlockTag("figcaption"))
    XCTAssertTrue(BN.isBlockTag("pre"))
  }

  func testIsBlockTag_inlineElements_areFalse() {
    XCTAssertFalse(BN.isBlockTag("span"))
    XCTAssertFalse(BN.isBlockTag("a"))
    XCTAssertFalse(BN.isBlockTag("em"))
  }

  func testIsBlockTag_isCaseInsensitive() {
    XCTAssertTrue(BN.isBlockTag("P"))
    XCTAssertTrue(BN.isBlockTag("BlockQuote"))
  }

  func testIsBlockTag_nilAndUnrelated_areFalse() {
    XCTAssertFalse(BN.isBlockTag(nil))
    XCTAssertFalse(BN.isBlockTag(""))
    XCTAssertFalse(BN.isBlockTag("div"))
  }

  // MARK: - blockSelector

  func testBlockSelector_containsKeyBlockTags() {
    let s = BN.blockSelector
    XCTAssertTrue(s.contains("p"))
    XCTAssertTrue(s.contains("h1"))
    XCTAssertTrue(s.contains("li"))
    XCTAssertTrue(s.contains("blockquote"))
    XCTAssertTrue(s.contains("[role=\"heading\"]"))
    XCTAssertTrue(s.contains("[role=\"listitem\"]"))
  }

  // MARK: - annotationJavaScript()

  func testAnnotationJS_isNonEmptyAndCarriesSelectorMarkerAndCount() {
    let js = BN.annotationJavaScript()
    XCTAssertFalse(js.isEmpty)
    // Mirrors the Swift selector spec and writes the atomic-stop marker.
    XCTAssertTrue(js.contains("querySelectorAll"))
    XCTAssertTrue(js.contains("blockquote"))
    XCTAssertTrue(js.contains("data-pp-block"))
    XCTAssertTrue(js.contains("tabindex"))
    // Returns a count for verification logging.
    XCTAssertTrue(js.contains("return n"))
  }

  func testAnnotationJS_skipsNestedBlocks() {
    // Only the OUTERMOST matching element is marked (an <li> wrapping a <p>
    // is one stop, not two), implemented via an ancestor `closest` check.
    let js = BN.annotationJavaScript()
    XCTAssertTrue(js.contains("closest"))
  }

  // MARK: - nextBlockJavaScript(forward:)

  func testNextBlockJS_forwardAndBackBothFocusAMarkedBlock() {
    let fwd = BN.nextBlockJavaScript(forward: true)
    let back = BN.nextBlockJavaScript(forward: false)
    XCTAssertFalse(fwd.isEmpty)
    XCTAssertFalse(back.isEmpty)
    for js in [fwd, back] {
      XCTAssertTrue(js.contains("data-pp-block"))
      XCTAssertTrue(js.contains("activeElement"))
      XCTAssertTrue(js.contains(".focus()"))
    }
    // Direction is carried into the DOM walk.
    XCTAssertTrue(fwd.contains("var FORWARD = true"))
    XCTAssertTrue(back.contains("var FORWARD = false"))
  }
}

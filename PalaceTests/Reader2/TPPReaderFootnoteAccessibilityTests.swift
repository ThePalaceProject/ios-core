//
//  TPPReaderFootnoteAccessibilityTests.swift
//  PalaceTests
//
//  PP-4531 (DAISY reading-420) — unit tests for the pure footnote-accessibility
//  core: epub:type/role classification and VoiceOver label composition. The
//  WKWebView annotation JS is a thin mirror of this spec and is verified at
//  runtime (device VoiceOver / simdrive host-AX), not here.
//

import XCTest
@testable import Palace

final class TPPReaderFootnoteAccessibilityTests: XCTestCase {

  typealias FA = TPPReaderFootnoteAccessibility

  // MARK: - role(forEPUBType:)

  func testRole_noteref_isReference() {
    XCTAssertEqual(FA.role(forEPUBType: "doc-noteref"), .reference)
  }

  func testRole_footnote_isNote() {
    XCTAssertEqual(FA.role(forEPUBType: "doc-footnote"), .note)
  }

  func testRole_endnoteAndRearnote_areNote() {
    XCTAssertEqual(FA.role(forEPUBType: "doc-endnote"), .note)
    XCTAssertEqual(FA.role(forEPUBType: "doc-rearnote"), .note)
  }

  func testRole_backlink_isBacklink() {
    XCTAssertEqual(FA.role(forEPUBType: "doc-backlink"), .backlink)
  }

  func testRole_toleratesMissingDocPrefix() {
    XCTAssertEqual(FA.role(forEPUBType: "noteref"), .reference)
    XCTAssertEqual(FA.role(forEPUBType: "backlink"), .backlink)
  }

  func testRole_isCaseInsensitive() {
    XCTAssertEqual(FA.role(forEPUBType: "DOC-NOTEREF"), .reference)
    XCTAssertEqual(FA.role(forEPUBType: "Doc-Footnote"), .note)
  }

  func testRole_multiTokenList_picksReferenceFirst() {
    // ARIA/epub:type can carry several space-separated tokens.
    XCTAssertEqual(FA.role(forEPUBType: "doc-noteref annotation"), .reference)
  }

  func testRole_ariaRoleVocabularyShared() {
    // The DAISY ARIA role vocabulary uses the same doc-* tokens.
    XCTAssertEqual(FA.role(forEPUBType: "doc-backlink"), .backlink)
  }

  func testRole_nilAndEmptyAndUnrelated_areNil() {
    XCTAssertNil(FA.role(forEPUBType: nil))
    XCTAssertNil(FA.role(forEPUBType: ""))
    XCTAssertNil(FA.role(forEPUBType: "doc-chapter"))
    XCTAssertNil(FA.role(forEPUBType: "section"))
  }

  // MARK: - accessibilityLabel(role:marker:)

  func testLabel_referenceWithMarker_includesMarker() {
    XCTAssertEqual(FA.accessibilityLabel(role: .reference, marker: "3"), "Footnote 3")
  }

  func testLabel_referenceWithNonNumericMarker_includesMarker() {
    XCTAssertEqual(FA.accessibilityLabel(role: .reference, marker: "*"), "Footnote *")
    XCTAssertEqual(FA.accessibilityLabel(role: .reference, marker: "a"), "Footnote a")
  }

  func testLabel_referenceTrimsMarker() {
    XCTAssertEqual(FA.accessibilityLabel(role: .reference, marker: "  12\n"), "Footnote 12")
  }

  func testLabel_referenceWithEmptyOrWhitespaceMarker_isGeneric() {
    XCTAssertEqual(FA.accessibilityLabel(role: .reference, marker: nil), "Footnote reference")
    XCTAssertEqual(FA.accessibilityLabel(role: .reference, marker: ""), "Footnote reference")
    XCTAssertEqual(FA.accessibilityLabel(role: .reference, marker: "   "), "Footnote reference")
  }

  func testLabel_note_isFootnote() {
    XCTAssertEqual(FA.accessibilityLabel(role: .note, marker: nil), "Footnote")
  }

  func testLabel_backlink_isBackToReference() {
    XCTAssertEqual(FA.accessibilityLabel(role: .backlink, marker: nil), "Back to reference")
  }

  // MARK: - annotationJavaScript()

  func testAnnotationJS_isNonEmptyAndCarriesLabelsAndSelectors() {
    let js = FA.annotationJavaScript()
    XCTAssertFalse(js.isEmpty)
    // Mirrors the Swift rule: detects the doc-* tokens and writes aria-label.
    XCTAssertTrue(js.contains("noteref"))
    XCTAssertTrue(js.contains("backlink"))
    XCTAssertTrue(js.contains("aria-label"))
    // Localized templates are interpolated into the DOM walker.
    XCTAssertTrue(js.contains("Footnote"))
    XCTAssertTrue(js.contains("Back to reference"))
  }
}

//
//  TPPReaderPageBreakLocatorTests.swift
//  The Palace Project
//
//  Tests the REAL TPPReaderPageBreakLocator — the pure JS-construction and
//  result-parsing layer that finds the nearest preceding print page-break in the
//  rendered chapter (DAISY nav-310 page component, PP-4527).
//
//  Why this replaces the previous approach: the shipped code asked
//  `publication.locate(link).locations.totalProgression` for every page-list
//  entry, but Readium's DefaultLocatorService NEVER sets totalProgression on a
//  locator built from a Link — for a fragmented page-list href it sets neither
//  totalProgression nor progression. Measured on device 2026-09-18:
//  "entries=182 resolved=0 nil=182". The page number could never appear, for any
//  title, at any position. The page-break markers DO exist in the rendered DOM,
//  so that is where they are read from now.
//

import XCTest
@testable import Palace

final class TPPReaderPageBreakLocatorTests: XCTestCase {

    // MARK: - Result parsing

    func testParse_withALabel_returnsIt() {
        XCTAssertEqual(TPPReaderPageBreakLocator.parse("42"), "42")
    }

    func testParse_trimsSurroundingWhitespace() {
        // Page-break labels are frequently authored as `<span> 42 </span>`.
        XCTAssertEqual(TPPReaderPageBreakLocator.parse("  ix \n"), "ix")
    }

    func testParse_withRomanNumeral_isPreserved() {
        // Front matter uses roman numerals; they must not be coerced to numbers.
        XCTAssertEqual(TPPReaderPageBreakLocator.parse("xiv"), "xiv")
    }

    func testParse_ofEmptyString_isNil() {
        XCTAssertNil(TPPReaderPageBreakLocator.parse(""))
    }

    func testParse_ofWhitespaceOnly_isNil() {
        XCTAssertNil(TPPReaderPageBreakLocator.parse("   \n "))
    }

    func testParse_ofNil_isNil() {
        // No break precedes the reader — the AC says this must not error.
        XCTAssertNil(TPPReaderPageBreakLocator.parse(nil))
    }

    func testParse_ofNonString_isNil() {
        // evaluateJavaScript returns Any?; a null round-trips as NSNull.
        XCTAssertNil(TPPReaderPageBreakLocator.parse(NSNull()))
    }

    func testParse_stripsAnEmbeddedPagePrefix() {
        // ReadiumCSS renders the marker as "Page 42"; some EPUBs author the
        // title attribute the same way. The composer adds its own "Page " prefix,
        // so leaving this in would announce "Page Page 42".
        XCTAssertEqual(TPPReaderPageBreakLocator.parse("Page 42"), "42")
    }

    // MARK: - The JavaScript contract

    func testJavaScript_doesNotUseANamespacedAttributeSelector() {
        // THE trap on this project: Readium's spine documents are XML-parsed, so
        // a CSS attribute selector like [epub\:type] matches NOTHING. PP-4531
        // shipped exactly that and labelled zero elements for four months. The
        // walk must read the attribute, not select on it.
        let js = TPPReaderPageBreakLocator.nearestPrecedingJavaScript(scrolled: false)
        XCTAssertFalse(js.contains("epub\\:type"),
                       "namespaced CSS attribute selectors match nothing in XML-parsed spine docs")
        XCTAssertTrue(js.contains("getAttribute('epub:type')"),
                      "epub:type must be read via getAttribute")
    }

    func testJavaScript_matchesBothTheEPUBTypeAndTheARIARole() {
        // A book may mark page-breaks with epub:type="pagebreak", with
        // role="doc-pagebreak", or with both. Missing either halves coverage.
        let js = TPPReaderPageBreakLocator.nearestPrecedingJavaScript(scrolled: false)
        XCTAssertTrue(js.contains("getAttribute('epub:type')"))
        XCTAssertTrue(js.contains("getAttribute('role')"))
        XCTAssertTrue(js.contains("pagebreak"))
    }

    func testJavaScript_paginatedAndScrolledCompareOnDifferentAxes() {
        // Paginated layout translates content horizontally, so preceding breaks
        // sit at negative x; scrolled layout stacks vertically. Comparing on the
        // wrong axis returns the wrong page — or always the first one.
        let paginated = TPPReaderPageBreakLocator.nearestPrecedingJavaScript(scrolled: false)
        let scrolled = TPPReaderPageBreakLocator.nearestPrecedingJavaScript(scrolled: true)
        XCTAssertTrue(paginated.contains("rect.left"))
        XCTAssertTrue(scrolled.contains("rect.top"))
        XCTAssertNotEqual(paginated, scrolled)
    }

    func testJavaScript_readsLabelFromTitleAriaLabelOrText() {
        // Page-break elements are usually empty; the label lives in an attribute.
        let js = TPPReaderPageBreakLocator.nearestPrecedingJavaScript(scrolled: false)
        XCTAssertTrue(js.contains("title"))
        XCTAssertTrue(js.contains("aria-label"))
        XCTAssertTrue(js.contains("textContent"))
    }
}

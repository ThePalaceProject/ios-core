//
//  TPPReaderPageListBusinessLogicTests.swift
//  PalaceTests
//
//  Tests the REAL TPPReaderPageListBusinessLogic — the shared print-page
//  mapping layer behind DAISY nav-110 (PP-4529) and nav-310 (PP-4527).
//

import XCTest
import ReadiumShared
@testable import Palace

final class TPPReaderPageListBusinessLogicTests: XCTestCase {

    // MARK: - Publication builders

    /// A publication whose EPUB `page-list` carries the given (label, href) pairs.
    private func makePublication(pages: [(label: String?, href: String)]) -> Publication {
        let pageLinks = pages.map { page in
            Link(href: page.href, mediaType: .xhtml, title: page.label)
        }
        let manifest = Manifest(
            metadata: Metadata(title: "Test Book", languages: ["en"]),
            readingOrder: [
                Link(href: "/chapter1.xhtml", mediaType: .xhtml),
                Link(href: "/chapter2.xhtml", mediaType: .xhtml)
            ],
            subcollections: ["pageList": [PublicationCollection(links: pageLinks)]]
        )
        return Publication(manifest: manifest)
    }

    /// Standard numeric page list: pages "1"…"5" across two chapters.
    private func makeNumericPublication() -> Publication {
        makePublication(pages: [
            ("1", "/chapter1.xhtml#p1"),
            ("2", "/chapter1.xhtml#p2"),
            ("3", "/chapter1.xhtml#p3"),
            ("4", "/chapter2.xhtml#p4"),
            ("5", "/chapter2.xhtml#p5")
        ])
    }

    // MARK: - hasPageList / loading

    func testHasPageList_whenPublicationHasPages_isTrue() {
        let sut = TPPReaderPageListBusinessLogic(publication: makeNumericPublication())
        XCTAssertTrue(sut.hasPageList)
        XCTAssertEqual(sut.pageCount, 5)
    }

    func testHasPageList_whenPublicationHasNoPageList_isFalse() {
        // Reading-order-only publication, no pageList subcollection at all.
        let manifest = Manifest(
            metadata: Metadata(title: "No Pages"),
            readingOrder: [Link(href: "/c1.xhtml", mediaType: .xhtml)]
        )
        let sut = TPPReaderPageListBusinessLogic(publication: Publication(manifest: manifest))
        XCTAssertFalse(sut.hasPageList)
        XCTAssertEqual(sut.pageCount, 0)
    }

    func testInit_dropsEntriesWithEmptyOrWhitespaceLabels() {
        let sut = TPPReaderPageListBusinessLogic(publication: makePublication(pages: [
            ("1", "/c.xhtml#p1"),
            (nil, "/c.xhtml#pNil"),
            ("", "/c.xhtml#pEmpty"),
            ("   ", "/c.xhtml#pBlank"),
            ("2", "/c.xhtml#p2")
        ]))
        // Only the two labeled pages survive; nil/empty/whitespace are dropped.
        XCTAssertEqual(sut.pageCount, 2)
        XCTAssertEqual(sut.label(at: 0), "1")
        XCTAssertEqual(sut.label(at: 1), "2")
    }

    func testInit_trimsWhitespaceFromLabels() {
        let sut = TPPReaderPageListBusinessLogic(publication: makePublication(pages: [
            ("  42  ", "/c.xhtml#p42")
        ]))
        XCTAssertEqual(sut.label(at: 0), "42")
    }

    // MARK: - label(at:)

    func testLabelAt_validIndex_returnsLabel() {
        let sut = TPPReaderPageListBusinessLogic(publication: makeNumericPublication())
        XCTAssertEqual(sut.label(at: 0), "1")
        XCTAssertEqual(sut.label(at: 4), "5")
    }

    func testLabelAt_outOfRange_returnsNil() {
        let sut = TPPReaderPageListBusinessLogic(publication: makeNumericPublication())
        XCTAssertNil(sut.label(at: 5))
        XCTAssertNil(sut.label(at: -1))
    }

    // MARK: - locator(at:) bounds

    func testLocatorAt_outOfRange_returnsNil() async {
        let sut = TPPReaderPageListBusinessLogic(publication: makeNumericPublication())
        let above = await sut.locator(at: 99)
        let below = await sut.locator(at: -1)
        XCTAssertNil(above)
        XCTAssertNil(below)
    }

    // MARK: - indexForPage exact match

    func testIndexForPage_exactNumericMatch_returnsThatIndex() {
        let sut = TPPReaderPageListBusinessLogic(publication: makeNumericPublication())
        XCTAssertEqual(sut.indexForPage(labeled: "3"), 2)
        XCTAssertEqual(sut.indexForPage(labeled: "1"), 0)
        XCTAssertEqual(sut.indexForPage(labeled: "5"), 4)
    }

    func testIndexForPage_exactMatchIsCaseInsensitive_forRomanNumerals() {
        let sut = TPPReaderPageListBusinessLogic(publication: makePublication(pages: [
            ("i", "/front.xhtml#i"),
            ("ii", "/front.xhtml#ii"),
            ("iii", "/front.xhtml#iii")
        ]))
        XCTAssertEqual(sut.indexForPage(labeled: "II"), 1)
        XCTAssertEqual(sut.indexForPage(labeled: "iii"), 2)
    }

    func testIndexForPage_trimsRequestWhitespace() {
        let sut = TPPReaderPageListBusinessLogic(publication: makeNumericPublication())
        XCTAssertEqual(sut.indexForPage(labeled: "  3  "), 2)
    }

    func testIndexForPage_emptyOrWhitespaceRequest_returnsNil() {
        let sut = TPPReaderPageListBusinessLogic(publication: makeNumericPublication())
        XCTAssertNil(sut.indexForPage(labeled: ""))
        XCTAssertNil(sut.indexForPage(labeled: "   "))
    }

    // MARK: - indexForPage nearest-preceding numeric fallback

    func testIndexForPage_noExactNumericMatch_fallsBackToNearestPreceding() {
        // Non-contiguous page list: 1, 5, 10. Request 7 → nearest preceding = 5 (index 1).
        let sut = TPPReaderPageListBusinessLogic(publication: makePublication(pages: [
            ("1", "/c.xhtml#p1"),
            ("5", "/c.xhtml#p5"),
            ("10", "/c.xhtml#p10")
        ]))
        XCTAssertEqual(sut.indexForPage(labeled: "7"), 1, "page 7 should resolve to the nearest preceding page 5")
        XCTAssertEqual(sut.indexForPage(labeled: "5"), 1, "exact match still wins")
        XCTAssertEqual(sut.indexForPage(labeled: "10"), 2)
    }

    func testIndexForPage_duplicateNumericLabels_resolvesToFirstPrecedingBoundary() {
        // Two boundaries both labeled "5". Nearest-preceding for an inexact
        // request (6) must land on the FIRST "5" boundary (index 1, the start of
        // page 5), not a later duplicate — `>` keeps the first; `>=` would drift
        // to the last. Pins first-occurrence-among-ties.
        let sut = TPPReaderPageListBusinessLogic(publication: makePublication(pages: [
            ("4", "/c.xhtml#p4"),
            ("5", "/c.xhtml#p5a"),
            ("5", "/c.xhtml#p5b"),
            ("8", "/c.xhtml#p8")
        ]))
        XCTAssertEqual(sut.indexForPage(labeled: "6"), 1, "page 6 resolves to the first page-5 boundary")
        XCTAssertEqual(sut.indexForPage(labeled: "7"), 1)
    }

    func testIndexForPage_aboveHighestNumericPage_returnsLastNumericPage() {
        // Request 50 beyond range [1,5] → nearest preceding = 5 (index 4).
        let sut = TPPReaderPageListBusinessLogic(publication: makeNumericPublication())
        XCTAssertEqual(sut.indexForPage(labeled: "50"), 4)
    }

    func testIndexForPage_belowLowestNumericPage_returnsNil() {
        // Pages start at 5; request 2 has no preceding numeric page.
        let sut = TPPReaderPageListBusinessLogic(publication: makePublication(pages: [
            ("5", "/c.xhtml#p5"),
            ("6", "/c.xhtml#p6")
        ]))
        XCTAssertNil(sut.indexForPage(labeled: "2"))
    }

    func testIndexForPage_nonNumericRequestNoExactMatch_returnsNil() {
        // Numeric-only page list; a roman-numeral request has no exact match and
        // is not numeric → nil (we never numerically coerce non-numeric requests).
        let sut = TPPReaderPageListBusinessLogic(publication: makeNumericPublication())
        XCTAssertNil(sut.indexForPage(labeled: "iv"))
    }

    func testIndexForPage_numericRequestSkipsNonNumericLabels_forFallback() {
        // Mixed front-matter (roman) + body (arabic). Request 3 with no exact
        // arabic "3" present → nearest preceding numeric is "2" (index 3),
        // never a roman-numeral entry.
        let sut = TPPReaderPageListBusinessLogic(publication: makePublication(pages: [
            ("i", "/front.xhtml#i"),
            ("ii", "/front.xhtml#ii"),
            ("1", "/body.xhtml#p1"),
            ("2", "/body.xhtml#p2"),
            ("5", "/body.xhtml#p5")
        ]))
        XCTAssertEqual(sut.indexForPage(labeled: "3"), 3, "nearest preceding numeric for 3 is page 2")
        XCTAssertEqual(sut.indexForPage(labeled: "ii"), 1, "exact roman match still resolves")
    }
}

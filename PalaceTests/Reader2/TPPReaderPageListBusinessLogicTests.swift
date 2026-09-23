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

@MainActor
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

    func testIndexForPage_numericValueEqualsRequestButLabelDiffers_resolvesViaInclusiveFallback() {
        // "07" is numerically 7 but is not an exact string match for "7", so it
        // resolves through the numeric fallback. The nearest preceding numeric
        // <= 7 is "07" itself (value 7). Pins the fallback bound as inclusive
        // (`<=`): the mutant `<` would skip the numerically-equal page and drift
        // down to "5".
        let sut = TPPReaderPageListBusinessLogic(publication: makePublication(pages: [
            ("5", "/c.xhtml#p5"),
            ("07", "/c.xhtml#p07")
        ]))
        XCTAssertEqual(sut.indexForPage(labeled: "7"), 1,
                       "page 7 resolves to the numerically-equal '07' boundary via the inclusive <= fallback")
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

    // MARK: - nearestPrecedingIndex (PP-4527 "Where am I?" current-page selection)
    //
    // Pure progression-based selection: given each page entry's book
    // progression and the patron's current progression, pick the nearest
    // PRECEDING print page (largest progression <= current). This is the
    // mutation-tested core behind currentPageLabel(for:).

    func testNearestPreceding_picksLargestAtOrBelowCurrent() {
        let progressions: [Double?] = [0.0, 0.25, 0.5, 0.75]
        XCTAssertEqual(
            TPPReaderPageListBusinessLogic.nearestPrecedingIndex(progressions: progressions, current: 0.6),
            2, "current 0.6 lands on the page at 0.5, not 0.75"
        )
    }

    func testNearestPreceding_exactMatchIsInclusive() {
        // current == a boundary's progression must select THAT boundary (<=),
        // not the prior one. The mutant `<` would drift down to index 1.
        let progressions: [Double?] = [0.0, 0.25, 0.5, 0.75]
        XCTAssertEqual(
            TPPReaderPageListBusinessLogic.nearestPrecedingIndex(progressions: progressions, current: 0.5),
            2
        )
    }

    func testNearestPreceding_currentBeforeFirstBoundary_returnsNil() {
        // No page boundary at or before the current position → no page to report.
        let progressions: [Double?] = [0.5, 0.75]
        XCTAssertNil(
            TPPReaderPageListBusinessLogic.nearestPrecedingIndex(progressions: progressions, current: 0.2)
        )
    }

    func testNearestPreceding_skipsUnresolvedProgressions() {
        // Page entries whose locator could not be resolved (nil progression) are
        // skipped, never selected.
        let progressions: [Double?] = [nil, 0.2, nil, 0.4]
        XCTAssertEqual(
            TPPReaderPageListBusinessLogic.nearestPrecedingIndex(progressions: progressions, current: 0.5),
            3
        )
    }

    func testNearestPreceding_tiesSelectFirstBoundary() {
        // Two boundaries at the same progression: keep the FIRST (strict `>`).
        // The mutant `>=` would drift to the last duplicate (index 1).
        let progressions: [Double?] = [0.3, 0.3]
        XCTAssertEqual(
            TPPReaderPageListBusinessLogic.nearestPrecedingIndex(progressions: progressions, current: 0.5),
            0
        )
    }

    func testNearestPreceding_allUnresolved_returnsNil() {
        let progressions: [Double?] = [nil, nil]
        XCTAssertNil(
            TPPReaderPageListBusinessLogic.nearestPrecedingIndex(progressions: progressions, current: 0.5)
        )
    }

    func testNearestPreceding_emptyProgressions_returnsNil() {
        XCTAssertNil(
            TPPReaderPageListBusinessLogic.nearestPrecedingIndex(progressions: [], current: 0.5)
        )
    }

    // MARK: - currentPageLabel(for:) guards

    func testCurrentPageLabel_locatorWithoutProgression_returnsNil() async {
        // No totalProgression on the locator → cannot place the reader on a print
        // page; returns nil rather than guessing (AC: absence does not error).
        let sut = TPPReaderPageListBusinessLogic(publication: makeNumericPublication())
        let locator = Locator(
            href: AnyURL(string: "/chapter1.xhtml")!,
            mediaType: .xhtml,
            locations: Locator.Locations(progression: 0.5, totalProgression: nil)
        )
        let label = await sut.currentPageLabel(for: locator)
        XCTAssertNil(label)
    }

    func testCurrentPageLabel_noPageList_returnsNil() async {
        // Title with no page-list: no page can be reported (AC), no error.
        let manifest = Manifest(
            metadata: Metadata(title: "No Pages"),
            readingOrder: [Link(href: "/c1.xhtml", mediaType: .xhtml)]
        )
        let sut = TPPReaderPageListBusinessLogic(publication: Publication(manifest: manifest))
        let locator = Locator(
            href: AnyURL(string: "/c1.xhtml")!,
            mediaType: .xhtml,
            locations: Locator.Locations(progression: 0.5, totalProgression: 0.5)
        )
        let label = await sut.currentPageLabel(for: locator)
        XCTAssertNil(label)
    }
}

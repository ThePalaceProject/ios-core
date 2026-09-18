//
//  TPPReaderPageBreakLocatorTests.swift
//  The Palace Project
//
//  Tests the REAL TPPReaderPageBreakLocator — the print-page component of the
//  DAISY nav-310 "Where am I?" announcement (PP-4527).
//
//  Why this type exists: the shipped code asked
//  `publication.locate(link).locations.totalProgression` for every page-list
//  entry, but Readium's DefaultLocatorService never sets totalProgression on a
//  locator built from a Link. Measured on device 2026-09-18:
//  "entries=182 resolved=0 nil=182" — the page number could never appear, for
//  any title, at any position.
//
//  Why these tests look like this: a first draft made the SELECTION decision
//  inside the injected JavaScript and asserted only that the JS string CONTAINED
//  certain substrings. Mutation scored it 0/12 — quoting logic is not executing
//  it. Selection moved into Swift, and the score went to 18% because the
//  COLLECTION logic was still only quoted. So the collector is now executed for
//  real against a stub DOM via JavaScriptCore, and the selection boundaries are
//  driven with explicit candidates.
//

import XCTest
import JavaScriptCore
@testable import Palace

final class TPPReaderPageBreakLocatorTests: XCTestCase {

    private typealias Candidate = TPPReaderPageBreakLocator.Candidate

    private func candidate(_ label: String, left: Double = 0, top: Double = 0) -> Candidate {
        Candidate(label: label, left: left, top: top)
    }

    // MARK: - Selection: paginated layout (horizontal axis)

    func testNearestPreceding_paginated_picksTheGreatestLeftBeforeTheViewportEdge() {
        // Preceding pages sit at negative x once the column is translated away.
        let candidates = [
            candidate("10", left: -900),
            candidate("11", left: -300),
            candidate("12", left: 500)   // not reached yet
        ]
        XCTAssertEqual(
            TPPReaderPageBreakLocator.nearestPreceding(in: candidates, scrolled: false, viewportExtent: 400),
            "11"
        )
    }

    func testNearestPreceding_paginated_ignoresMarkersBeyondTheViewport() {
        let candidates = [candidate("20", left: 800), candidate("21", left: 1200)]
        XCTAssertNil(
            TPPReaderPageBreakLocator.nearestPreceding(in: candidates, scrolled: false, viewportExtent: 400)
        )
    }

    func testNearestPreceding_paginated_markerOnScreenCountsAsReached() {
        // A break inside the visible column IS the page the patron is on.
        let candidates = [candidate("30", left: -100), candidate("31", left: 50)]
        XCTAssertEqual(
            TPPReaderPageBreakLocator.nearestPreceding(in: candidates, scrolled: false, viewportExtent: 400),
            "31"
        )
    }

    // MARK: - Selection: scrolled layout (vertical axis)

    func testNearestPreceding_scrolled_usesTopNotLeft() {
        // Same candidates, different axis. In scroll mode `left` is constant and
        // `top` carries the ordering; reading the wrong axis returns the wrong
        // page — or the same one forever.
        let candidates = [
            candidate("40", left: 0, top: -600),
            candidate("41", left: 0, top: -50),
            candidate("42", left: 0, top: 900)
        ]
        XCTAssertEqual(
            TPPReaderPageBreakLocator.nearestPreceding(in: candidates, scrolled: true, viewportExtent: 800),
            "41"
        )
    }

    func testNearestPreceding_sameCandidates_differByAxis() {
        // Pins that the axis switch actually changes the answer, so a flip
        // between them cannot pass unnoticed.
        let candidates = [
            candidate("left-winner", left: 100, top: -900),
            candidate("top-winner", left: -900, top: 100)
        ]
        XCTAssertEqual(
            TPPReaderPageBreakLocator.nearestPreceding(in: candidates, scrolled: false, viewportExtent: 400),
            "left-winner"
        )
        XCTAssertEqual(
            TPPReaderPageBreakLocator.nearestPreceding(in: candidates, scrolled: true, viewportExtent: 400),
            "top-winner"
        )
    }

    // MARK: - Selection: exact boundaries (both found by mutation)

    func testNearestPreceding_markerExactlyAtTheViewportEdge_isNotYetReached() {
        // `< viewportExtent` and `<=` differ at exactly one value, and nothing
        // exercised it. A marker sitting precisely at the edge is the first thing
        // on the NEXT page, so it must not be reported as the current one.
        let candidates = [candidate("8", left: -50), candidate("9", left: 400)]
        XCTAssertEqual(
            TPPReaderPageBreakLocator.nearestPreceding(in: candidates, scrolled: false, viewportExtent: 400),
            "8"
        )
    }

    func testNearestPreceding_twoMarkersAtTheSamePosition_isDeterministic() {
        // Ties happen when a chapter opens with a page-break and a heading that
        // share a layout position. `max(by:)` keeps the EARLIER element when
        // neither compares less, so document order decides — deterministically,
        // rather than by whichever the sort happened to visit last.
        let candidates = [candidate("first", left: -100), candidate("second", left: -100)]
        XCTAssertEqual(
            TPPReaderPageBreakLocator.nearestPreceding(in: candidates, scrolled: false, viewportExtent: 400),
            "first"
        )
    }

    // MARK: - Selection: edges (absence must not error — AC)

    func testNearestPreceding_withNoCandidates_isNil() {
        XCTAssertNil(
            TPPReaderPageBreakLocator.nearestPreceding(in: [], scrolled: false, viewportExtent: 400)
        )
    }

    func testNearestPreceding_unorderedCandidates_stillPicksTheNearest() {
        // DOM order is document order, which is not necessarily visual order
        // after layout; selection must not depend on the array being sorted.
        let candidates = [
            candidate("c", left: -100),
            candidate("a", left: -900),
            candidate("b", left: -500)
        ]
        XCTAssertEqual(
            TPPReaderPageBreakLocator.nearestPreceding(in: candidates, scrolled: false, viewportExtent: 400),
            "c"
        )
    }

    // MARK: - The collector JavaScript, actually executed

    /// Runs the real collector JS against a stub DOM.
    ///
    /// The point is execution. Asserting the JS string contains a substring
    /// leaves every operator inside it free to be wrong — which is exactly how
    /// the first draft scored 0/12.
    private func runCollector(elementsJS: String) -> [Candidate] {
        guard let context = JSContext() else {
            XCTFail("could not create a JSContext")
            return []
        }
        let prelude = """
        function el(attrs, left, top, text) {
          return {
            attrs: attrs,
            textContent: text,
            getAttribute: function(n) { return (n in this.attrs) ? this.attrs[n] : null; },
            getBoundingClientRect: function() { return { left: left, top: top }; }
          };
        }
        var document = { body: { getElementsByTagName: function(_) { return ELEMENTS; } } };
        """.replacingOccurrences(of: "ELEMENTS", with: elementsJS)

        context.evaluateScript(prelude)
        let result = context.evaluateScript(TPPReaderPageBreakLocator.collectCandidatesJavaScript())
        return TPPReaderPageBreakLocator.parseCandidates(result?.toString())
    }

    func testCollectorJS_findsMarkersByEPUBTypeAndByARIARole() {
        // Both spellings must be found; matching only one halves coverage.
        let candidates = runCollector(elementsJS: """
        [ el({'epub:type':'pagebreak','title':'5'}, -100, 0, ''),
          el({'role':'doc-pagebreak','title':'6'}, -50, 0, ''),
          el({'class':'ordinary'}, -10, 0, 'body text') ]
        """)
        XCTAssertEqual(candidates.map(\.label), ["5", "6"])
    }

    func testCollectorJS_readsLabelFromTitleThenAriaLabelThenText() {
        // The `||` fallback chain — each link in it must actually be reachable.
        let candidates = runCollector(elementsJS: """
        [ el({'epub:type':'pagebreak','title':'from-title'}, -30, 0, 'ignored'),
          el({'epub:type':'pagebreak','aria-label':'from-aria'}, -20, 0, 'ignored'),
          el({'epub:type':'pagebreak'}, -10, 0, 'from-text') ]
        """)
        XCTAssertEqual(candidates.map(\.label), ["from-title", "from-aria", "from-text"])
    }

    func testCollectorJS_visitsEveryElement() {
        // Pins the loop bound: a flipped comparison collects nothing at all.
        let candidates = runCollector(elementsJS: """
        [ el({'epub:type':'pagebreak','title':'a'}, -30, 0, ''),
          el({'epub:type':'pagebreak','title':'b'}, -20, 0, ''),
          el({'epub:type':'pagebreak','title':'c'}, -10, 0, '') ]
        """)
        XCTAssertEqual(candidates.count, 3)
    }

    func testCollectorJS_reportsPositions() {
        let candidates = runCollector(elementsJS: """
        [ el({'epub:type':'pagebreak','title':'7'}, -123.5, 44.25, '') ]
        """)
        XCTAssertEqual(candidates, [Candidate(label: "7", left: -123.5, top: 44.25)])
    }

    func testCollectorJS_withNoMarkers_returnsNothing() {
        let candidates = runCollector(elementsJS: "[ el({'class':'p'}, 0, 0, 'text') ]")
        XCTAssertTrue(candidates.isEmpty)
    }

    // MARK: - Decoding what the web view returns

    func testParseCandidates_decodesLabelAndPosition() {
        let json = #"[{"label":"42","left":-120.5,"top":8.0}]"#
        XCTAssertEqual(
            TPPReaderPageBreakLocator.parseCandidates(json),
            [Candidate(label: "42", left: -120.5, top: 8.0)]
        )
    }

    func testParseCandidates_dropsEntriesWithBlankLabels() {
        // An empty <span epub:type="pagebreak"/> carries no page number; keeping
        // it would let an unlabelled marker mask a real one behind it.
        let json = #"[{"label":"  ","left":-10,"top":0},{"label":"7","left":-5,"top":0}]"#
        XCTAssertEqual(
            TPPReaderPageBreakLocator.parseCandidates(json),
            [Candidate(label: "7", left: -5, top: 0)]
        )
    }

    func testParseCandidates_ofMalformedJSON_isEmpty() {
        XCTAssertEqual(TPPReaderPageBreakLocator.parseCandidates("not json"), [])
    }

    func testParseCandidates_ofNil_isEmpty() {
        XCTAssertEqual(TPPReaderPageBreakLocator.parseCandidates(nil), [])
    }

    func testParseCandidates_ofNSNull_isEmpty() {
        // evaluateJavaScript returns Any?; a JS null arrives as NSNull.
        XCTAssertEqual(TPPReaderPageBreakLocator.parseCandidates(NSNull()), [])
    }

    // MARK: - Label normalisation

    func testNormalize_trimsWhitespace() {
        XCTAssertEqual(TPPReaderPageBreakLocator.normalize("  ix \n"), "ix")
    }

    func testNormalize_preservesRomanNumerals() {
        // Front matter is numbered i, ii, iii; coercing to Int would misreport.
        XCTAssertEqual(TPPReaderPageBreakLocator.normalize("xiv"), "xiv")
    }

    func testNormalize_stripsAnEmbeddedPagePrefix() {
        // The composer adds its own "Page " prefix; otherwise: "Page Page 42".
        XCTAssertEqual(TPPReaderPageBreakLocator.normalize("Page 42"), "42")
    }

    func testNormalize_ofWhitespaceOnly_isNil() {
        XCTAssertNil(TPPReaderPageBreakLocator.normalize("   \n "))
    }

    func testNormalize_ofNonString_isNil() {
        XCTAssertNil(TPPReaderPageBreakLocator.normalize(NSNull()))
    }

    // MARK: - The JavaScript contract

    func testJavaScript_doesNotUseANamespacedAttributeSelector() {
        // THE trap on this project: Readium's spine documents are XML-parsed, so
        // a CSS attribute selector like [epub\:type] matches NOTHING. PP-4531
        // shipped exactly that and annotated zero elements for four months.
        let js = TPPReaderPageBreakLocator.collectCandidatesJavaScript()
        XCTAssertFalse(js.contains("epub\\:type"),
                       "namespaced CSS attribute selectors match nothing in XML-parsed spine docs")
        XCTAssertTrue(js.contains("getAttribute('epub:type')"))
        XCTAssertTrue(js.contains("getAttribute('role')"))
    }
}

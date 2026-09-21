//
//  EPUBPositionDialectTests.swift
//  PalaceTests
//
//  PP-5138: `EPUBPositionDialect` is the read-side reconciliation between the
//  two JSON dialects an EPUB reading position can arrive in. These tests pin
//  both dialects, the precedence rule between them, and the same-page
//  comparison that decides whether the patron sees a sync prompt.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class EPUBPositionDialectTests: XCTestCase {

    // MARK: - Fixtures
    //
    // Both strings describe the SAME page — 62% through chapter 1, 17% through
    // the book, page 58. `readiumDialect` is verbatim what
    // `TPPLastReadPositionPoster` POSTs (captured from
    // `Locator.jsonString()`); `flatDialect` is verbatim what
    // `TPPBookLocation(locator:type:publication:)` writes to the registry.

    private let readiumDialect = """
    {"href":"/chapter1.xhtml","locations":{"position":58,"progression":0.62,\
    "totalProgression":0.17},"title":"Chapter One","type":"application/xhtml+xml"}
    """

    private let flatDialect = """
    {"title":"Chapter One","href":"/chapter1.xhtml","position":58,\
    "cssSelector":"","@type":"LocatorHrefProgression","progressWithinBook":0.17,\
    "progressWithinChapter":0.62}
    """

    // MARK: - Parsing each dialect

    func testParse_ReadiumLocatorDialect_ReadsNestedLocations() throws {
        let fields = try XCTUnwrap(EPUBPositionDialect(jsonString: readiumDialect))

        XCTAssertEqual(fields.href, "/chapter1.xhtml")
        XCTAssertEqual(fields.title, "Chapter One")
        XCTAssertEqual(fields.progression, 0.62)
        XCTAssertEqual(fields.totalProgression, 0.17)
        XCTAssertEqual(fields.position, 58)
    }

    func testParse_FlatPalaceDialect_ReadsTopLevelKeys() throws {
        let fields = try XCTUnwrap(EPUBPositionDialect(jsonString: flatDialect))

        XCTAssertEqual(fields.href, "/chapter1.xhtml")
        XCTAssertEqual(fields.title, "Chapter One")
        XCTAssertEqual(fields.progression, 0.62)
        XCTAssertEqual(fields.totalProgression, 0.17)
        XCTAssertEqual(fields.position, 58)
    }

    /// The two dialects must parse to the same fields — that equivalence is
    /// the whole point of the type, and it is what makes the same-page
    /// comparison work across a device boundary.
    func testParse_BothDialects_YieldIdenticalFields() throws {
        let fromReadium = try XCTUnwrap(EPUBPositionDialect(jsonString: readiumDialect))
        let fromFlat = try XCTUnwrap(EPUBPositionDialect(jsonString: flatDialect))

        XCTAssertEqual(fromReadium.positionIdentity, fromFlat.positionIdentity)
    }

    /// A payload carrying both shapes must resolve to the Readium reading
    /// rather than a mix of the two. `EPUBPositionTests` has a fixture of
    /// exactly this shape, so it is not hypothetical.
    func testParse_MixedDialect_PrefersNestedLocations() throws {
        let mixed = """
        {"@type":"LocatorHrefProgression","href":"/chapter1.xhtml",\
        "progressWithinChapter":0.11,"progressWithinBook":0.22,"position":3,\
        "locations":{"progression":0.62,"totalProgression":0.17,"position":58}}
        """
        let fields = try XCTUnwrap(EPUBPositionDialect(jsonString: mixed))

        XCTAssertEqual(fields.progression, 0.62, "nested progression must win over the flat key")
        XCTAssertEqual(fields.totalProgression, 0.17, "nested totalProgression must win over the flat key")
        XCTAssertEqual(fields.position, 58, "nested position must win over the flat key")
    }

    /// `cssSelector` rides inside `locations` in the Readium dialect (Readium
    /// folds `otherLocations` into that object) and at the top level in the
    /// flat one. Both must be found.
    func testParse_CSSSelector_FoundInEitherDialect() throws {
        let selector = "body > p:nth-child(7)"
        let nested = try XCTUnwrap(EPUBPositionDialect(
            jsonString: #"{"href":"/c.xhtml","locations":{"progression":0.5,"cssSelector":"body > p:nth-child(7)"}}"#
        ))
        let flat = try XCTUnwrap(EPUBPositionDialect(
            jsonString: #"{"href":"/c.xhtml","progressWithinChapter":0.5,"cssSelector":"body > p:nth-child(7)"}"#
        ))

        XCTAssertEqual(nested.cssSelector, selector)
        XCTAssertEqual(flat.cssSelector, selector)
    }

    /// A position written as `58.0` must not be dropped. A plain `as? Int`
    /// bridge returns nil for a fractional `NSNumber`, which would silently
    /// lose the page.
    func testParse_IntegralPositionWrittenAsDouble_IsRead() throws {
        let fields = try XCTUnwrap(EPUBPositionDialect(
            jsonString: #"{"href":"/c.xhtml","locations":{"position":58.0}}"#
        ))

        XCTAssertEqual(fields.position, 58)
    }

    func testParse_MalformedJSON_ReturnsNil() {
        XCTAssertNil(EPUBPositionDialect(jsonString: "not json"))
        XCTAssertNil(EPUBPositionDialect(jsonString: ""))
        XCTAssertNil(EPUBPositionDialect(jsonString: "[1,2,3]"),
                     "a JSON array is well-formed JSON but not a position object")
    }

    // MARK: - Same-page comparison

    /// The PP-5138 case: device A posted in the Readium dialect, device B
    /// holds the same page in the flat dialect. No prompt is warranted.
    func testSamePosition_AcrossDialects_IsTrue() {
        XCTAssertTrue(EPUBPositionDialect.samePosition(flatDialect, readiumDialect),
                      "the same page in two dialects must compare equal — this is the prompt-never-settles bug")
    }

    func testSamePosition_DifferentPages_IsFalse() {
        let elsewhere = """
        {"href":"/chapter4.xhtml","locations":{"position":210,"progression":0.3,\
        "totalProgression":0.71},"title":"Chapter Four","type":"application/xhtml+xml"}
        """
        XCTAssertFalse(EPUBPositionDialect.samePosition(flatDialect, elsewhere),
                       "a genuinely different page must still produce a prompt")
    }

    /// A page turn within the same chapter must register as a different
    /// position — otherwise the prompt is suppressed when it is warranted.
    func testSamePosition_SameChapterDifferentProgression_IsFalse() {
        let later = """
        {"href":"/chapter1.xhtml","locations":{"position":59,"progression":0.64,\
        "totalProgression":0.18},"title":"Chapter One","type":"application/xhtml+xml"}
        """
        XCTAssertFalse(EPUBPositionDialect.samePosition(flatDialect, later))
    }

    /// Same progression, different chapter — the href has to be part of the
    /// identity or two chapters at the same relative offset collapse together.
    func testSamePosition_SameProgressionDifferentHref_IsFalse() {
        let otherChapter = """
        {"href":"/chapter9.xhtml","locations":{"position":58,"progression":0.62,\
        "totalProgression":0.17},"title":"Chapter Nine","type":"application/xhtml+xml"}
        """
        XCTAssertFalse(EPUBPositionDialect.samePosition(flatDialect, otherChapter))
    }

    /// The dialects disagree about absence: the flat writer coerces nil to
    /// `0.0` and emits the key, the Readium writer omits it. Those must
    /// normalize to the same identity, or absence alone triggers a prompt.
    func testSamePosition_AbsentVersusZero_IsTrue() {
        let omitted = #"{"href":"/c.xhtml","locations":{"progression":0.5}}"#
        let explicitZeros = """
        {"href":"/c.xhtml","progressWithinChapter":0.5,"progressWithinBook":0,\
        "position":0,"cssSelector":""}
        """
        XCTAssertTrue(EPUBPositionDialect.samePosition(omitted, explicitZeros))
    }

    /// Title is descriptive, not positional. Two records of the same page
    /// whose chapter titles were resolved differently (a TOC lookup that
    /// succeeded on one device and not the other) are still the same page.
    func testSamePosition_DifferingTitles_IsTrue() {
        let untitled = """
        {"href":"/chapter1.xhtml","locations":{"position":58,"progression":0.62,\
        "totalProgression":0.17},"type":"application/xhtml+xml"}
        """
        XCTAssertTrue(EPUBPositionDialect.samePosition(flatDialect, untitled))
    }

    /// Unparseable input falls back to byte equality — the pre-PP-5138
    /// behavior. An unrecognized payload must never be treated as matching
    /// something it does not.
    func testSamePosition_UnparseableInput_FallsBackToByteEquality() {
        XCTAssertTrue(EPUBPositionDialect.samePosition("garbage", "garbage"))
        XCTAssertFalse(EPUBPositionDialect.samePosition("garbage", "other garbage"))
        XCTAssertFalse(EPUBPositionDialect.samePosition("garbage", flatDialect),
                       "one side unparseable must not compare equal to a valid position")
    }
}

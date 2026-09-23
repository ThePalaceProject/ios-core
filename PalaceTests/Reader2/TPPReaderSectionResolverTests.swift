//
//  TPPReaderSectionResolverTests.swift
//  The Palace Project
//
//  Tests the REAL TPPReaderSectionResolver — the pure "which section am I in?"
//  derivation behind the DAISY nav-310 "Where am I?" announcement (PP-4527).
//
//  Why this type exists: the shipped implementation read `locator.title`, which
//  Readium populates ONLY when the locator came from a ToC/nav link. Reading
//  normally into a chapter leaves it nil, so the section silently vanished from
//  the announcement — measured on device 2026-09-18 as a bare "38% read" on
//  page 1 of Chapter 3. The AC requires the section be "derived from the nearest
//  preceding ToC/nav entry for the current position", which is what this does.
//

import XCTest
@testable import Palace

final class TPPReaderSectionResolverTests: XCTestCase {

    // A flattened ToC: reading-order index of the entry's resource, plus the
    // entry's progression within that resource when it points at a fragment.
    private func entry(_ title: String, resource: Int, progression: Double? = nil)
        -> TPPReaderSectionResolver.Entry {
        TPPReaderSectionResolver.Entry(title: title, resourceIndex: resource, progression: progression)
    }

    // MARK: - The defect this type exists to fix

    func testSection_whenReadingMidChapter_resolvesFromNearestPrecedingEntry() {
        // The device case: no ToC navigation happened, so nothing supplies a
        // title; the section must still be derived from position alone.
        let toc = [
            entry("Cover", resource: 0),
            entry("Introduction", resource: 3),
            entry("Chapter 3 Creating the World", resource: 7)
        ]
        XCTAssertEqual(
            TPPReaderSectionResolver.section(in: toc, resourceIndex: 7, progression: 0.5),
            "Chapter 3 Creating the World"
        )
    }

    func testSection_whenPositionIsInsideAnUnlistedResource_usesThePrecedingEntry() {
        // Resource 8 has no ToC entry of its own — a chapter split across files.
        // The reader is still "in" Chapter 3 and must be told so, not told nothing.
        let toc = [entry("Introduction", resource: 3), entry("Chapter 3", resource: 7)]
        XCTAssertEqual(
            TPPReaderSectionResolver.section(in: toc, resourceIndex: 8, progression: 0.1),
            "Chapter 3"
        )
    }

    // MARK: - Sub-sections within one resource

    func testSection_withSeveralEntriesInOneResource_picksTheNearestPreceding() {
        let toc = [
            entry("Part One", resource: 4, progression: 0.0),
            entry("Section A", resource: 4, progression: 0.25),
            entry("Section B", resource: 4, progression: 0.75)
        ]
        XCTAssertEqual(
            TPPReaderSectionResolver.section(in: toc, resourceIndex: 4, progression: 0.5),
            "Section A"
        )
    }

    func testSection_exactlyOnASubSectionBoundary_belongsToThatSubSection() {
        // Boundary cell: a position exactly ON an entry is inside it, not before it.
        let toc = [
            entry("Section A", resource: 4, progression: 0.25),
            entry("Section B", resource: 4, progression: 0.75)
        ]
        XCTAssertEqual(
            TPPReaderSectionResolver.section(in: toc, resourceIndex: 4, progression: 0.75),
            "Section B"
        )
    }

    func testSection_entryWithoutProgression_treatedAsStartOfItsResource() {
        let toc = [entry("Chapter 2", resource: 5), entry("A Sub Heading", resource: 5, progression: 0.6)]
        XCTAssertEqual(
            TPPReaderSectionResolver.section(in: toc, resourceIndex: 5, progression: 0.1),
            "Chapter 2"
        )
    }

    // MARK: - Edge cases (absence must not error — AC)

    func testSection_whenBeforeTheFirstEntry_isNil() {
        let toc = [entry("Introduction", resource: 3)]
        XCTAssertNil(TPPReaderSectionResolver.section(in: toc, resourceIndex: 1, progression: 0.0))
    }

    func testSection_whenTableOfContentsIsEmpty_isNil() {
        XCTAssertNil(TPPReaderSectionResolver.section(in: [], resourceIndex: 4, progression: 0.5))
    }

    func testSection_ignoresEntriesWithBlankTitles() {
        // A nav doc with an untitled landmark must not blank out the section.
        let toc = [entry("Chapter 1", resource: 2), entry("   ", resource: 3)]
        XCTAssertEqual(
            TPPReaderSectionResolver.section(in: toc, resourceIndex: 3, progression: 0.5),
            "Chapter 1"
        )
    }

    func testSection_whenEntriesTie_prefersNavOrder() {
        // Every fragment-anchored entry is assigned progression 0.0 (the nav
        // document says WHICH element an entry points at, not where it sits), so
        // a chapter and its sub-headings all tie. The tie must resolve to the
        // entry declared first — the chapter — and must be deterministic rather
        // than whichever the sort happened to land on.
        //
        // Surfaced by mutation: `<` -> `<=` in the comparator survived, because
        // nothing exercised a tie. That flip makes max(by:) keep the LAST tied
        // entry, announcing an arbitrary sub-heading instead of the chapter.
        let toc = [
            entry("Chapter 2", resource: 5),
            entry("A Sub Heading", resource: 5, progression: 0.0),
            entry("Another Sub Heading", resource: 5, progression: 0.0)
        ]
        XCTAssertEqual(
            TPPReaderSectionResolver.section(in: toc, resourceIndex: 5, progression: 0.9),
            "Chapter 2"
        )
    }

    func testSection_unorderedTableOfContents_stillResolvesByPosition() {
        // Nav order is not guaranteed to be reading order; resolution must not
        // depend on the array already being sorted.
        let toc = [entry("Chapter 5", resource: 9), entry("Chapter 1", resource: 2)]
        XCTAssertEqual(
            TPPReaderSectionResolver.section(in: toc, resourceIndex: 3, progression: 0.0),
            "Chapter 1"
        )
    }
}

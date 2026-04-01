//
//  CatalogFilterServiceTests.swift
//  PalaceTests
//
//  Unit tests for CatalogFilterService — key management, selection logic,
//  group priority, URL categorisation, and filter ordering.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

/// SRS: CAT-005 — Filter service manages catalog facet state consistently
final class CatalogFilterServiceTests: XCTestCase {

    // MARK: - Helpers

    private func makeFilter(title: String, href: String? = nil, active: Bool = false) -> CatalogFilter {
        CatalogFilter(
            id: UUID().uuidString,
            title: title,
            href: href.flatMap { URL(string: $0) },
            active: active
        )
    }

    private func makeGroup(name: String, filters: [CatalogFilter]) -> CatalogFilterGroup {
        CatalogFilterGroup(id: UUID().uuidString, name: name, filters: filters)
    }

    // MARK: - makeKey / parseKey round-trip

    func testMakeKey_producesCanonicalFormat() {
        let key = CatalogFilterService.makeKey(group: "Format", title: "EPUB", hrefString: "https://example.com/epub")
        XCTAssertEqual(key, "Format|EPUB|https://example.com/epub")
    }

    func testMakeGroupTitleKey_omitsHref() {
        let key = CatalogFilterService.makeGroupTitleKey(group: "Format", title: "PDF")
        XCTAssertEqual(key, "Format|PDF")
    }

    func testParseKey_roundTrips() {
        let key = CatalogFilterService.makeKey(group: "Collection", title: "Fiction", hrefString: "https://lib.org/fiction")
        let parsed = CatalogFilterService.parseKey(key)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.group, "Collection")
        XCTAssertEqual(parsed?.title, "Fiction")
        XCTAssertEqual(parsed?.hrefString, "https://lib.org/fiction")
    }

    func testParseKey_returnsNilForInvalidKey() {
        XCTAssertNil(CatalogFilterService.parseKey("onlyonepart"))
        XCTAssertNil(CatalogFilterService.parseKey("two|parts"))
    }

    func testParseKey_handlesEmptyComponents() {
        let key = "||"
        let parsed = CatalogFilterService.parseKey(key)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.group, "")
        XCTAssertEqual(parsed?.title, "")
        XCTAssertEqual(parsed?.hrefString, "")
    }

    // MARK: - ParsedKey.isDefaultTitle

    func testParsedKey_isDefaultTitle_detectsAllVariants() {
        let defaults = ["All", "all", "ALL FORMATS", "all collections", "All Distributors", "  all  "]
        for title in defaults {
            let pk = CatalogFilterService.ParsedKey(group: "G", title: title, hrefString: "")
            XCTAssertTrue(pk.isDefaultTitle, "'\(title)' should be a default title")
        }
    }

    func testParsedKey_isDefaultTitle_rejectsNonDefaults() {
        let nonDefaults = ["Fiction", "eBooks", "Available Now"]
        for title in nonDefaults {
            let pk = CatalogFilterService.ParsedKey(group: "G", title: title, hrefString: "")
            XCTAssertFalse(pk.isDefaultTitle, "'\(title)' should NOT be a default title")
        }
    }

    // MARK: - normalizeTitle

    func testNormalizeTitle_trimsAndLowercases() {
        XCTAssertEqual(CatalogFilterService.normalizeTitle("  EPUB  "), "epub")
        XCTAssertEqual(CatalogFilterService.normalizeTitle("Fiction"), "fiction")
    }

    // MARK: - selectionKeysFromActiveFacets

    func testSelectionKeys_excludesSortGroups() {
        let sortFilter = makeFilter(title: "Title A-Z", href: "https://lib.org/sort-title", active: true)
        let sortGroup = makeGroup(name: "Sort by", filters: [sortFilter])

        let formatFilter = makeFilter(title: "EPUB", href: "https://lib.org/epub", active: true)
        let formatGroup = makeGroup(name: "Format", filters: [formatFilter])

        let keys = CatalogFilterService.selectionKeysFromActiveFacets(
            facetGroups: [sortGroup, formatGroup],
            includeDefaults: true
        )

        XCTAssertEqual(keys.count, 1, "Sort group facets should be excluded")
        XCTAssertTrue(keys.first?.hasPrefix("Format|") ?? false)
    }

    func testSelectionKeys_excludesDefaultsWhenFlagFalse() {
        let allFilter = makeFilter(title: "All", href: "https://lib.org/all", active: true)
        let epubFilter = makeFilter(title: "EPUB", href: "https://lib.org/epub", active: true)
        let group = makeGroup(name: "Format", filters: [allFilter, epubFilter])

        let keys = CatalogFilterService.selectionKeysFromActiveFacets(
            facetGroups: [group],
            includeDefaults: false
        )

        XCTAssertEqual(keys.count, 1, "Default 'All' filter should be excluded")
        XCTAssertTrue(keys.first?.contains("EPUB") ?? false)
    }

    func testSelectionKeys_includesDefaultsWhenFlagTrue() {
        let allFilter = makeFilter(title: "All", href: "https://lib.org/all", active: true)
        let group = makeGroup(name: "Format", filters: [allFilter])

        let keys = CatalogFilterService.selectionKeysFromActiveFacets(
            facetGroups: [group],
            includeDefaults: true
        )

        XCTAssertEqual(keys.count, 1, "Default should be included when flag is true")
    }

    // MARK: - activeFiltersCount

    func testActiveFiltersCount_excludesDefaults() {
        let selections: Set<String> = [
            "Format|All|https://lib.org/all",
            "Format|EPUB|https://lib.org/epub",
            "Collection|All Collections|https://lib.org/collections"
        ]
        XCTAssertEqual(CatalogFilterService.activeFiltersCount(appliedSelections: selections), 1,
                       "Only non-default filters should be counted")
    }

    func testActiveFiltersCount_emptySet_returnsZero() {
        XCTAssertEqual(CatalogFilterService.activeFiltersCount(appliedSelections: []), 0)
    }

    // MARK: - getGroupPriority

    func testGroupPriority_collectionIsHighest() {
        XCTAssertEqual(CatalogFilterService.getGroupPriority("My Collection"), 1)
        XCTAssertEqual(CatalogFilterService.getGroupPriority("Library"), 1)
    }

    func testGroupPriority_distributorBeforeFormat() {
        let distribPriority = CatalogFilterService.getGroupPriority("Distributor")
        let formatPriority = CatalogFilterService.getGroupPriority("Format")
        XCTAssertLessThan(distribPriority, formatPriority)
    }

    func testGroupPriority_unknownGroupReturnsFallback() {
        XCTAssertEqual(CatalogFilterService.getGroupPriority("Something Unknown"), 10)
    }

    func testGroupPriority_caseInsensitive() {
        XCTAssertEqual(CatalogFilterService.getGroupPriority("FORMAT"), 3)
        XCTAssertEqual(CatalogFilterService.getGroupPriority("availability"), 4)
        XCTAssertEqual(CatalogFilterService.getGroupPriority("LANGUAGE"), 5)
        XCTAssertEqual(CatalogFilterService.getGroupPriority("Genre"), 6)
    }

    // MARK: - categorizeFacetURL

    func testCategorizeFacetURL_categorisesCorrectly() {
        let testCases: [(String, String)] = [
            ("https://lib.org/collection/fiction", "Collection"),
            ("https://lib.org/library/branch1", "Collection"),
            ("https://lib.org/format/epub", "Format"),
            ("https://lib.org/media/audiobook", "Format"),
            ("https://lib.org/availability/now", "Availability"),
            ("https://lib.org/available/yes", "Availability"),
            ("https://lib.org/language/en", "Language"),
            ("https://lib.org/lang/fr", "Language"),
            ("https://lib.org/subject/mystery", "Subject"),
            ("https://lib.org/genre/sci-fi", "Subject"),
            ("https://lib.org/something/else", "Other"),
        ]

        for (urlString, expected) in testCases {
            let url = URL(string: urlString)!
            XCTAssertEqual(CatalogFilterService.categorizeFacetURL(url), expected,
                           "URL '\(urlString)' should categorise as '\(expected)'")
        }
    }

    // MARK: - findFacetGroupName

    func testFindFacetGroupName_matchesURL() {
        let filter = makeFilter(title: "EPUB", href: "https://lib.org/epub", active: false)
        let group = makeGroup(name: "Format", filters: [filter])

        let found = CatalogFilterService.findFacetGroupName(
            for: URL(string: "https://lib.org/epub")!,
            in: [group]
        )
        XCTAssertEqual(found, "Format")
    }

    func testFindFacetGroupName_returnsNilForUnknownURL() {
        let filter = makeFilter(title: "EPUB", href: "https://lib.org/epub", active: false)
        let group = makeGroup(name: "Format", filters: [filter])

        let found = CatalogFilterService.findFacetGroupName(
            for: URL(string: "https://lib.org/unknown")!,
            in: [group]
        )
        XCTAssertNil(found)
    }

    // MARK: - findFilterInCurrentFacets

    func testFindFilterInCurrentFacets_caseInsensitiveMatch() {
        let filter = makeFilter(title: "EPUB", href: "https://lib.org/epub", active: false)
        let group = makeGroup(name: "Format", filters: [filter])

        let parsed = CatalogFilterService.ParsedKey(group: "format", title: "epub", hrefString: "")
        let url = CatalogFilterService.findFilterInCurrentFacets(parsed, in: [group])
        XCTAssertEqual(url?.absoluteString, "https://lib.org/epub")
    }

    func testFindFilterInCurrentFacets_returnsNilWhenNotFound() {
        let filter = makeFilter(title: "EPUB", href: "https://lib.org/epub", active: false)
        let group = makeGroup(name: "Format", filters: [filter])

        let parsed = CatalogFilterService.ParsedKey(group: "Format", title: "PDF", hrefString: "")
        let url = CatalogFilterService.findFilterInCurrentFacets(parsed, in: [group])
        XCTAssertNil(url)
    }

    // MARK: - prioritizeSelectedFilters

    func testPrioritizeSelectedFilters_ordersCollectionBeforeFormat() {
        let collectionURL = URL(string: "https://lib.org/collection/fiction")!
        let formatURL = URL(string: "https://lib.org/format/epub")!

        let collectionFilter = makeFilter(title: "Fiction", href: collectionURL.absoluteString, active: true)
        let formatFilter = makeFilter(title: "EPUB", href: formatURL.absoluteString, active: true)

        let collGroup = makeGroup(name: "Collection", filters: [collectionFilter])
        let fmtGroup = makeGroup(name: "Format", filters: [formatFilter])

        let prioritized = CatalogFilterService.prioritizeSelectedFilters(
            [formatURL, collectionURL],
            currentFacetGroups: [fmtGroup, collGroup]
        )

        XCTAssertEqual(prioritized.count, 2)
        XCTAssertEqual(prioritized.first, collectionURL, "Collection URL should come first")
    }

    // MARK: - activeFacetHrefs

    func testActiveFacetHrefs_returnsActiveURLs() {
        let active = makeFilter(title: "EPUB", href: "https://lib.org/epub", active: true)
        let inactive = makeFilter(title: "PDF", href: "https://lib.org/pdf", active: false)
        let group = makeGroup(name: "Format", filters: [active, inactive])

        let hrefs = CatalogFilterService.activeFacetHrefs(facetGroups: [group], includeDefaults: true)
        XCTAssertEqual(hrefs.count, 1)
        XCTAssertEqual(hrefs.first?.absoluteString, "https://lib.org/epub")
    }

    func testActiveFacetHrefs_excludesDefaultsWhenFlagFalse() {
        let allFilter = makeFilter(title: "All", href: "https://lib.org/all", active: true)
        let group = makeGroup(name: "Format", filters: [allFilter])

        let hrefs = CatalogFilterService.activeFacetHrefs(facetGroups: [group], includeDefaults: false)
        XCTAssertTrue(hrefs.isEmpty, "Default 'All' filter href should be excluded")
    }

    // MARK: - reconstructSelectionsFromCurrentFacets

    func testReconstructSelections_matchesByGroupAndTitle() {
        let filter = makeFilter(title: "EPUB", href: "https://lib.org/epub-v2", active: false)
        let group = makeGroup(name: "Format", filters: [filter])

        let applied: Set<String> = ["Format|EPUB|https://lib.org/epub-old"]
        let reconstructed = CatalogFilterService.reconstructSelectionsFromCurrentFacets(
            appliedSelections: applied,
            facetGroups: [group]
        )

        XCTAssertEqual(reconstructed.count, 1)
        let key = reconstructed.first!
        XCTAssertTrue(key.contains("epub-v2"), "Reconstructed key should use current href")
    }

    func testReconstructSelections_skipsInvalidKeys() {
        let filter = makeFilter(title: "EPUB", href: "https://lib.org/epub", active: false)
        let group = makeGroup(name: "Format", filters: [filter])

        let applied: Set<String> = ["badkey"]
        let reconstructed = CatalogFilterService.reconstructSelectionsFromCurrentFacets(
            appliedSelections: applied,
            facetGroups: [group]
        )
        XCTAssertTrue(reconstructed.isEmpty)
    }

    // MARK: - keysForCurrentFacets

    func testKeysForCurrentFacets_mapsGroupTitleKeysToFullKeys() {
        let filter = makeFilter(title: "EPUB", href: "https://lib.org/epub", active: false)
        let group = makeGroup(name: "Format", filters: [filter])

        let groupTitleKeys: Set<String> = ["Format|EPUB"]
        let fullKeys = CatalogFilterService.keysForCurrentFacets(
            fromGroupTitleKeys: groupTitleKeys,
            facetGroups: [group]
        )

        XCTAssertEqual(fullKeys.count, 1)
        XCTAssertTrue(fullKeys.first?.contains("https://lib.org/epub") ?? false)
    }

    func testKeysForCurrentFacets_excludesSortGroups() {
        let sortFilter = makeFilter(title: "Title", href: "https://lib.org/sort", active: false)
        let sortGroup = makeGroup(name: "Sort by", filters: [sortFilter])

        let keys: Set<String> = ["Sort by|Title"]
        let result = CatalogFilterService.keysForCurrentFacets(
            fromGroupTitleKeys: keys,
            facetGroups: [sortGroup]
        )

        XCTAssertTrue(result.isEmpty, "Sort group facets should be excluded")
    }
}

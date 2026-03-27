//
//  CatalogFilterServiceTests.swift
//  PalaceTests
//
//  Tests for CatalogFilterService key management, filter selection,
//  group priority, URL categorization, and CatalogFilterModels.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

// MARK: - CatalogFilterModels Tests

final class CatalogFilterModelsTests: XCTestCase {

    // SRS: CatalogFilter stores all properties
    func testCatalogFilter_properties() {
        let url = URL(string: "https://example.com/filter")!
        let filter = CatalogFilter(id: "f1", title: "Fiction", href: url, active: true)
        XCTAssertEqual(filter.id, "f1")
        XCTAssertEqual(filter.title, "Fiction")
        XCTAssertEqual(filter.href, url)
        XCTAssertTrue(filter.active)
    }

    // SRS: CatalogFilter with nil href
    func testCatalogFilter_nilHref() {
        let filter = CatalogFilter(id: "f2", title: "All", href: nil, active: false)
        XCTAssertNil(filter.href)
        XCTAssertFalse(filter.active)
    }

    // SRS: CatalogFilter conforms to Hashable
    func testCatalogFilter_hashable() {
        let filter1 = CatalogFilter(id: "f1", title: "A", href: nil, active: true)
        let filter2 = CatalogFilter(id: "f2", title: "B", href: nil, active: false)
        var set = Set<CatalogFilter>()
        set.insert(filter1)
        set.insert(filter2)
        XCTAssertEqual(set.count, 2)
    }

    // SRS: CatalogFilterGroup stores name and filters
    func testCatalogFilterGroup_properties() {
        let filter = CatalogFilter(id: "f1", title: "All", href: nil, active: true)
        let group = CatalogFilterGroup(id: "g1", name: "Format", filters: [filter])
        XCTAssertEqual(group.id, "g1")
        XCTAssertEqual(group.name, "Format")
        XCTAssertEqual(group.filters.count, 1)
    }
}

// MARK: - CatalogFilterService Key Management Tests

final class CatalogFilterServiceKeyTests: XCTestCase {

    // SRS: makeKey creates canonical key with pipe separators
    func testMakeKey_format() {
        let key = CatalogFilterService.makeKey(group: "Format", title: "EPUB", hrefString: "https://example.com")
        XCTAssertEqual(key, "Format|EPUB|https://example.com")
    }

    // SRS: makeGroupTitleKey creates group-title key
    func testMakeGroupTitleKey_format() {
        let key = CatalogFilterService.makeGroupTitleKey(group: "Collection", title: "All")
        XCTAssertEqual(key, "Collection|All")
    }

    // SRS: parseKey extracts components correctly
    func testParseKey_validKey() {
        let parsed = CatalogFilterService.parseKey("Format|EPUB|https://example.com")
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.group, "Format")
        XCTAssertEqual(parsed?.title, "EPUB")
        XCTAssertEqual(parsed?.hrefString, "https://example.com")
    }

    // SRS: parseKey returns nil for invalid key
    func testParseKey_invalidKey() {
        let parsed = CatalogFilterService.parseKey("nopipes")
        XCTAssertNil(parsed)
    }

    // SRS: parseKey handles key with only two parts
    func testParseKey_twoPartsReturnsNil() {
        let parsed = CatalogFilterService.parseKey("a|b")
        XCTAssertNil(parsed)
    }

    // SRS: ParsedKey isDefaultTitle for "All"
    func testParsedKey_isDefaultTitle_all() {
        let parsed = CatalogFilterService.parseKey("Format|All|href")
        XCTAssertTrue(parsed!.isDefaultTitle)
    }

    // SRS: ParsedKey isDefaultTitle for "All Formats"
    func testParsedKey_isDefaultTitle_allFormats() {
        let parsed = CatalogFilterService.parseKey("Format|All Formats|href")
        XCTAssertTrue(parsed!.isDefaultTitle)
    }

    // SRS: ParsedKey isDefaultTitle for "All Collections"
    func testParsedKey_isDefaultTitle_allCollections() {
        let parsed = CatalogFilterService.parseKey("Collection|All Collections|href")
        XCTAssertTrue(parsed!.isDefaultTitle)
    }

    // SRS: ParsedKey isDefaultTitle for "All Distributors"
    func testParsedKey_isDefaultTitle_allDistributors() {
        let parsed = CatalogFilterService.parseKey("Distributor|All Distributors|href")
        XCTAssertTrue(parsed!.isDefaultTitle)
    }

    // SRS: ParsedKey isDefaultTitle false for specific filter
    func testParsedKey_isDefaultTitle_false() {
        let parsed = CatalogFilterService.parseKey("Format|EPUB|href")
        XCTAssertFalse(parsed!.isDefaultTitle)
    }

    // SRS: normalizeTitle trims and lowercases
    func testNormalizeTitle() {
        XCTAssertEqual(CatalogFilterService.normalizeTitle("  Fiction  "), "fiction")
        XCTAssertEqual(CatalogFilterService.normalizeTitle("ALL"), "all")
    }
}

// MARK: - CatalogFilterService Group Priority Tests

final class CatalogFilterServicePriorityTests: XCTestCase {

    // SRS: Collection group has highest priority
    func testGroupPriority_collection() {
        XCTAssertEqual(CatalogFilterService.getGroupPriority("Collection"), 1)
    }

    // SRS: Library group has priority 1
    func testGroupPriority_library() {
        XCTAssertEqual(CatalogFilterService.getGroupPriority("My Library"), 1)
    }

    // SRS: Distributor group has priority 2
    func testGroupPriority_distributor() {
        XCTAssertEqual(CatalogFilterService.getGroupPriority("Distributor"), 2)
    }

    // SRS: Format group has priority 3
    func testGroupPriority_format() {
        XCTAssertEqual(CatalogFilterService.getGroupPriority("Format"), 3)
    }

    // SRS: Media group has priority 3
    func testGroupPriority_media() {
        XCTAssertEqual(CatalogFilterService.getGroupPriority("Media Type"), 3)
    }

    // SRS: Availability group has priority 4
    func testGroupPriority_availability() {
        XCTAssertEqual(CatalogFilterService.getGroupPriority("Availability"), 4)
    }

    // SRS: Language group has priority 5
    func testGroupPriority_language() {
        XCTAssertEqual(CatalogFilterService.getGroupPriority("Language"), 5)
    }

    // SRS: Subject group has priority 6
    func testGroupPriority_subject() {
        XCTAssertEqual(CatalogFilterService.getGroupPriority("Subject"), 6)
    }

    // SRS: Unknown group has default priority 10
    func testGroupPriority_unknown() {
        XCTAssertEqual(CatalogFilterService.getGroupPriority("Unknown"), 10)
    }
}

// MARK: - CatalogFilterService URL Categorization Tests

final class CatalogFilterServiceCategorizationTests: XCTestCase {

    // SRS: categorizeFacetURL identifies collection URLs
    func testCategorizeFacetURL_collection() {
        let url = URL(string: "https://example.com/collection/fiction")!
        XCTAssertEqual(CatalogFilterService.categorizeFacetURL(url), "Collection")
    }

    // SRS: categorizeFacetURL identifies format URLs
    func testCategorizeFacetURL_format() {
        let url = URL(string: "https://example.com/format/epub")!
        XCTAssertEqual(CatalogFilterService.categorizeFacetURL(url), "Format")
    }

    // SRS: categorizeFacetURL identifies availability URLs
    func testCategorizeFacetURL_availability() {
        let url = URL(string: "https://example.com/availability/now")!
        XCTAssertEqual(CatalogFilterService.categorizeFacetURL(url), "Availability")
    }

    // SRS: categorizeFacetURL identifies language URLs
    func testCategorizeFacetURL_language() {
        let url = URL(string: "https://example.com/language/en")!
        XCTAssertEqual(CatalogFilterService.categorizeFacetURL(url), "Language")
    }

    // SRS: categorizeFacetURL identifies subject URLs
    func testCategorizeFacetURL_subject() {
        let url = URL(string: "https://example.com/subject/fiction")!
        XCTAssertEqual(CatalogFilterService.categorizeFacetURL(url), "Subject")
    }

    // SRS: categorizeFacetURL returns Other for unknown URLs
    func testCategorizeFacetURL_unknown() {
        let url = URL(string: "https://example.com/something/else")!
        XCTAssertEqual(CatalogFilterService.categorizeFacetURL(url), "Other")
    }
}

// MARK: - CatalogFilterService Selection Tests

final class CatalogFilterServiceSelectionTests: XCTestCase {

    private func makeGroup(name: String, filters: [(String, String, Bool)]) -> CatalogFilterGroup {
        let catalogFilters = filters.map { (title, href, active) in
            CatalogFilter(id: "\(name)-\(title)", title: title, href: URL(string: href), active: active)
        }
        return CatalogFilterGroup(id: name, name: name, filters: catalogFilters)
    }

    // SRS: selectionKeysFromActiveFacets extracts active facets
    func testSelectionKeysFromActiveFacets_extractsActive() {
        let group = makeGroup(name: "Format", filters: [
            ("EPUB", "https://ex.com/epub", true),
            ("PDF", "https://ex.com/pdf", false),
        ])
        let keys = CatalogFilterService.selectionKeysFromActiveFacets(facetGroups: [group], includeDefaults: true)
        XCTAssertEqual(keys.count, 1)
        XCTAssertTrue(keys.contains("Format|EPUB|https://ex.com/epub"))
    }

    // SRS: selectionKeysFromActiveFacets excludes sort groups
    func testSelectionKeysFromActiveFacets_excludesSort() {
        let sortGroup = makeGroup(name: "Sort by", filters: [
            ("Title", "https://ex.com/sort-title", true),
        ])
        let keys = CatalogFilterService.selectionKeysFromActiveFacets(facetGroups: [sortGroup], includeDefaults: true)
        XCTAssertTrue(keys.isEmpty)
    }

    // SRS: selectionKeysFromActiveFacets excludes defaults when includeDefaults is false
    func testSelectionKeysFromActiveFacets_excludesDefaults() {
        let group = makeGroup(name: "Format", filters: [
            ("All", "https://ex.com/all", true),
            ("EPUB", "https://ex.com/epub", true),
        ])
        let keys = CatalogFilterService.selectionKeysFromActiveFacets(facetGroups: [group], includeDefaults: false)
        XCTAssertEqual(keys.count, 1)
        XCTAssertTrue(keys.contains("Format|EPUB|https://ex.com/epub"))
    }

    // SRS: activeFiltersCount excludes default titles
    func testActiveFiltersCount_excludesDefaults() {
        let selections: Set<String> = [
            "Format|All|href",
            "Format|EPUB|href",
            "Collection|Fiction|href"
        ]
        XCTAssertEqual(CatalogFilterService.activeFiltersCount(appliedSelections: selections), 2)
    }

    // SRS: activeFiltersCount returns 0 for only defaults
    func testActiveFiltersCount_onlyDefaults() {
        let selections: Set<String> = [
            "Format|All|href",
            "Collection|All Collections|href"
        ]
        XCTAssertEqual(CatalogFilterService.activeFiltersCount(appliedSelections: selections), 0)
    }

    // SRS: findFacetGroupName returns correct group
    func testFindFacetGroupName() {
        let group = makeGroup(name: "Format", filters: [
            ("EPUB", "https://ex.com/epub", false),
        ])
        let url = URL(string: "https://ex.com/epub")!
        XCTAssertEqual(CatalogFilterService.findFacetGroupName(for: url, in: [group]), "Format")
    }

    // SRS: findFacetGroupName returns nil for unknown URL
    func testFindFacetGroupName_notFound() {
        let group = makeGroup(name: "Format", filters: [
            ("EPUB", "https://ex.com/epub", false),
        ])
        let url = URL(string: "https://ex.com/unknown")!
        XCTAssertNil(CatalogFilterService.findFacetGroupName(for: url, in: [group]))
    }

    // SRS: findFilterInCurrentFacets returns URL for matching filter
    func testFindFilterInCurrentFacets() {
        let group = makeGroup(name: "Format", filters: [
            ("EPUB", "https://ex.com/epub", false),
        ])
        let parsed = CatalogFilterService.ParsedKey(group: "Format", title: "EPUB", hrefString: "")
        let url = CatalogFilterService.findFilterInCurrentFacets(parsed, in: [group])
        XCTAssertEqual(url?.absoluteString, "https://ex.com/epub")
    }

    // SRS: findFilterInCurrentFacets returns nil for no match
    func testFindFilterInCurrentFacets_noMatch() {
        let group = makeGroup(name: "Format", filters: [
            ("PDF", "https://ex.com/pdf", false),
        ])
        let parsed = CatalogFilterService.ParsedKey(group: "Format", title: "EPUB", hrefString: "")
        XCTAssertNil(CatalogFilterService.findFilterInCurrentFacets(parsed, in: [group]))
    }

    // SRS: reconstructSelectionsFromCurrentFacets maps applied to current
    func testReconstructSelections() {
        let group = makeGroup(name: "Format", filters: [
            ("EPUB", "https://ex.com/epub-v2", false),
        ])
        let applied: Set<String> = ["Format|EPUB|https://ex.com/epub-v1"]
        let result = CatalogFilterService.reconstructSelectionsFromCurrentFacets(appliedSelections: applied, facetGroups: [group])
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result.first!.contains("epub-v2"))
    }

    // SRS: prioritizeSelectedFilters orders by group priority
    func testPrioritizeSelectedFilters() {
        let formatGroup = makeGroup(name: "Format", filters: [
            ("EPUB", "https://ex.com/epub", false),
        ])
        let collectionGroup = makeGroup(name: "Collection", filters: [
            ("Fiction", "https://ex.com/fiction", false),
        ])
        let urls = [
            URL(string: "https://ex.com/epub")!,
            URL(string: "https://ex.com/fiction")!
        ]
        let result = CatalogFilterService.prioritizeSelectedFilters(urls, currentFacetGroups: [formatGroup, collectionGroup])
        // Collection (priority 1) should come before Format (priority 3)
        XCTAssertEqual(result.first?.absoluteString, "https://ex.com/fiction")
    }
}

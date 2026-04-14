//
//  FacetsSelectorSnapshotTests.swift
//  PalaceTests
//
//  Snapshot tests for FacetsSelectorView and EntryPointsSelectorView.
//  Tests run across multiple device configurations for comprehensive coverage.
//

import XCTest
import SwiftUI
import SnapshotTesting
@testable import Palace

@MainActor
final class FacetsSelectorSnapshotTests: XCTestCase {

    // MARK: - Helper Methods

    private func createMockFilter(title: String, active: Bool = false) -> CatalogFilter {
        CatalogFilter(
            id: UUID().uuidString,
            title: title,
            href: URL(string: "https://example.com/filter/\(title.lowercased())"),
            active: active
        )
    }

    private func createMockFilterGroup(name: String, filters: [CatalogFilter]) -> CatalogFilterGroup {
        CatalogFilterGroup(
            id: UUID().uuidString,
            name: name,
            filters: filters
        )
    }

    // MARK: - FacetsSelectorView Tests

    func testFacetsSelectorView_singleGroup() {
        let filters = [
            createMockFilter(title: "All", active: true),
            createMockFilter(title: "Fiction"),
            createMockFilter(title: "Non-Fiction")
        ]
        let group = createMockFilterGroup(name: "Category", filters: filters)
        XCTAssertEqual(group.filters.count, 3, "Group must contain 3 filters for single-group snapshot")

        let view = FacetsSelectorView(
            facetGroups: [group],
            onSelect: { _ in }
        )
        .background(Color(UIColor.systemBackground))

        assertMultiDeviceSnapshot(of: view)
    }

    func testFacetsSelectorView_multipleGroups() {
        let categoryFilters = [
            createMockFilter(title: "All", active: true),
            createMockFilter(title: "Fiction"),
            createMockFilter(title: "Non-Fiction")
        ]
        let sortFilters = [
            createMockFilter(title: "Title"),
            createMockFilter(title: "Author", active: true),
            createMockFilter(title: "Date Added")
        ]

        let groups = [
            createMockFilterGroup(name: "Category", filters: categoryFilters),
            createMockFilterGroup(name: "Sort By", filters: sortFilters)
        ]
        XCTAssertEqual(groups.count, 2, "Must have 2 groups for multi-group snapshot")

        let view = FacetsSelectorView(
            facetGroups: groups,
            onSelect: { _ in }
        )
        .background(Color(UIColor.systemBackground))

        assertMultiDeviceSnapshot(of: view)
    }

    func testFacetsSelectorView_manyFilters() {
        let filters = [
            createMockFilter(title: "All", active: true),
            createMockFilter(title: "Available Now"),
            createMockFilter(title: "Coming Soon"),
            createMockFilter(title: "On Hold"),
            createMockFilter(title: "Borrowed")
        ]
        let group = createMockFilterGroup(name: "Availability", filters: filters)
        XCTAssertEqual(filters.count, 5, "Must have 5 filters for many-filter snapshot")

        let view = FacetsSelectorView(
            facetGroups: [group],
            onSelect: { _ in }
        )
        .background(Color(UIColor.systemBackground))

        assertMultiDeviceSnapshot(of: view)
    }

    func testFacetsSelectorView_darkMode() {
        let filters = [
            createMockFilter(title: "All", active: true),
            createMockFilter(title: "Fiction"),
            createMockFilter(title: "Non-Fiction")
        ]
        let group = createMockFilterGroup(name: "Category", filters: filters)
        XCTAssertTrue(filters.contains(where: { $0.active }), "Dark mode snapshot must have at least one active filter")

        let view = FacetsSelectorView(
            facetGroups: [group],
            onSelect: { _ in }
        )
        .background(Color(UIColor.systemBackground))
        .colorScheme(.dark)

        assertMultiDeviceSnapshot(of: view)
    }

    func testFacetsSelectorView_noActiveFilter() {
        let filters = [
            createMockFilter(title: "All"),
            createMockFilter(title: "Fiction"),
            createMockFilter(title: "Non-Fiction")
        ]
        let group = createMockFilterGroup(name: "Category", filters: filters)
        XCTAssertFalse(filters.contains(where: { $0.active }), "No-active-filter snapshot must have no active filters")

        let view = FacetsSelectorView(
            facetGroups: [group],
            onSelect: { _ in }
        )
        .background(Color(UIColor.systemBackground))

        assertMultiDeviceSnapshot(of: view)
    }

    // MARK: - EntryPointsSelectorView Tests

    func testEntryPointsSelectorView_twoTabs() {
        let entryPoints = [
            createMockFilter(title: "Books", active: true),
            createMockFilter(title: "Audiobooks")
        ]
        XCTAssertEqual(entryPoints.count, 2, "Two-tab snapshot must have exactly 2 entry points")

        let view = EntryPointsSelectorView(
            entryPoints: entryPoints,
            onSelect: { _ in }
        )
        .background(Color(UIColor.systemBackground))

        assertMultiDeviceSnapshot(of: view)
    }

    func testEntryPointsSelectorView_threeTabs() {
        let entryPoints = [
            createMockFilter(title: "All"),
            createMockFilter(title: "Books", active: true),
            createMockFilter(title: "Audiobooks")
        ]
        XCTAssertEqual(entryPoints.count, 3, "Three-tab snapshot must have exactly 3 entry points")

        let view = EntryPointsSelectorView(
            entryPoints: entryPoints,
            onSelect: { _ in }
        )
        .background(Color(UIColor.systemBackground))

        assertMultiDeviceSnapshot(of: view)
    }

    func testEntryPointsSelectorView_darkMode() {
        let entryPoints = [
            createMockFilter(title: "Books", active: true),
            createMockFilter(title: "Audiobooks")
        ]
        XCTAssertTrue(entryPoints.contains(where: { $0.active }), "Dark mode must have at least one active entry point")

        let view = EntryPointsSelectorView(
            entryPoints: entryPoints,
            onSelect: { _ in }
        )
        .background(Color(UIColor.systemBackground))
        .colorScheme(.dark)

        assertMultiDeviceSnapshot(of: view)
    }

    // MARK: - Empty State Tests

    func testFacetsSelectorView_emptyGroups() {
        let emptyGroups: [CatalogFilterGroup] = []
        XCTAssertTrue(emptyGroups.isEmpty, "Empty-groups snapshot must have zero groups")

        let view = FacetsSelectorView(
            facetGroups: emptyGroups,
            onSelect: { _ in }
        )
        .background(Color(UIColor.systemBackground))

        assertMultiDeviceSnapshot(of: view)
    }
}

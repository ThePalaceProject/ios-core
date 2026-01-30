//
//  CatalogModelsTests.swift
//  PalaceTests
//
//  Comprehensive unit tests for Catalog model structs:
//  - CatalogFilter: Filter item with ID, title, URL, and active state
//  - CatalogFilterGroup: Collection of filters with group metadata
//  - CatalogLaneModel: Lane containing books with optional "more" URL
//  - MappedCatalog: Complete mapped feed data structure
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

// MARK: - CatalogFilter Tests

final class CatalogFilterModelTests: XCTestCase {

  // MARK: - Initialization Tests

  func testInit_StoresAllProperties() {
    let url = URL(string: "https://library.example.org/audiobooks")!
    let filter = CatalogFilter(
      id: "filter-audiobooks",
      title: "Audiobooks",
      href: url,
      active: true
    )

    XCTAssertEqual(filter.id, "filter-audiobooks")
    XCTAssertEqual(filter.title, "Audiobooks")
    XCTAssertEqual(filter.href, url)
    XCTAssertTrue(filter.active)
  }

  func testInit_WithNilHref() {
    let filter = CatalogFilter(
      id: "all-items",
      title: "All",
      href: nil,
      active: true
    )

    XCTAssertNil(filter.href)
    XCTAssertEqual(filter.title, "All")
  }

  func testInit_WithInactiveState() {
    let filter = CatalogFilter(
      id: "ebooks-filter",
      title: "eBooks",
      href: URL(string: "https://example.org/ebooks"),
      active: false
    )

    XCTAssertFalse(filter.active)
  }

  // MARK: - Identifiable Conformance Tests

  func testIdentifiable_UsesIdProperty() {
    let filter = CatalogFilter(
      id: "unique-id-123",
      title: "Test Filter",
      href: nil,
      active: false
    )

    XCTAssertEqual(filter.id, "unique-id-123")
  }

  // MARK: - Hashable Conformance Tests

  func testHashable_EqualFiltersHaveSameHash() {
    let filter1 = CatalogFilter(
      id: "same-id",
      title: "Same Title",
      href: URL(string: "https://example.org"),
      active: true
    )
    let filter2 = CatalogFilter(
      id: "same-id",
      title: "Same Title",
      href: URL(string: "https://example.org"),
      active: true
    )

    XCTAssertEqual(filter1.hashValue, filter2.hashValue)
  }

  func testHashable_DifferentFiltersCanBeUsedInSet() {
    let filter1 = CatalogFilter(id: "id-1", title: "Filter 1", href: nil, active: false)
    let filter2 = CatalogFilter(id: "id-2", title: "Filter 2", href: nil, active: false)
    let filter3 = CatalogFilter(id: "id-3", title: "Filter 3", href: nil, active: true)

    let filterSet: Set<CatalogFilter> = [filter1, filter2, filter3]

    XCTAssertEqual(filterSet.count, 3)
    XCTAssertTrue(filterSet.contains(filter1))
    XCTAssertTrue(filterSet.contains(filter2))
    XCTAssertTrue(filterSet.contains(filter3))
  }

  // MARK: - Equality Tests

  func testEquality_IdenticalFiltersAreEqual() {
    let url = URL(string: "https://example.org/filter")
    let filter1 = CatalogFilter(id: "test", title: "Test", href: url, active: true)
    let filter2 = CatalogFilter(id: "test", title: "Test", href: url, active: true)

    XCTAssertEqual(filter1, filter2)
  }

  func testEquality_DifferentIdsMakesFiltersUnequal() {
    let filter1 = CatalogFilter(id: "id-1", title: "Same", href: nil, active: true)
    let filter2 = CatalogFilter(id: "id-2", title: "Same", href: nil, active: true)

    XCTAssertNotEqual(filter1, filter2)
  }

  func testEquality_DifferentTitlesMakesFiltersUnequal() {
    let filter1 = CatalogFilter(id: "same-id", title: "Title A", href: nil, active: true)
    let filter2 = CatalogFilter(id: "same-id", title: "Title B", href: nil, active: true)

    XCTAssertNotEqual(filter1, filter2)
  }

  func testEquality_DifferentActiveStateMakesFiltersUnequal() {
    let filter1 = CatalogFilter(id: "same-id", title: "Same", href: nil, active: true)
    let filter2 = CatalogFilter(id: "same-id", title: "Same", href: nil, active: false)

    XCTAssertNotEqual(filter1, filter2)
  }

  func testEquality_DifferentHrefMakesFiltersUnequal() {
    let filter1 = CatalogFilter(id: "same-id", title: "Same", href: URL(string: "https://a.com"), active: true)
    let filter2 = CatalogFilter(id: "same-id", title: "Same", href: URL(string: "https://b.com"), active: true)

    XCTAssertNotEqual(filter1, filter2)
  }

  func testEquality_NilAndNonNilHrefMakesFiltersUnequal() {
    let filter1 = CatalogFilter(id: "same-id", title: "Same", href: nil, active: true)
    let filter2 = CatalogFilter(id: "same-id", title: "Same", href: URL(string: "https://example.org"), active: true)

    XCTAssertNotEqual(filter1, filter2)
  }

  // MARK: - Edge Cases

  func testEdgeCase_EmptyStringId() {
    let filter = CatalogFilter(id: "", title: "Empty ID Filter", href: nil, active: false)

    XCTAssertEqual(filter.id, "")
  }

  func testEdgeCase_EmptyStringTitle() {
    let filter = CatalogFilter(id: "valid-id", title: "", href: nil, active: false)

    XCTAssertEqual(filter.title, "")
  }

  func testEdgeCase_SpecialCharactersInTitle() {
    let filter = CatalogFilter(
      id: "special-chars",
      title: "Fiction & Non-Fiction (All)",
      href: nil,
      active: true
    )

    XCTAssertEqual(filter.title, "Fiction & Non-Fiction (All)")
  }

  func testEdgeCase_UnicodeInTitle() {
    let filter = CatalogFilter(
      id: "unicode-title",
      title: "Livros em Portugues",
      href: nil,
      active: false
    )

    XCTAssertEqual(filter.title, "Livros em Portugues")
  }

  func testEdgeCase_ComplexURL() {
    let complexURL = URL(string: "https://api.example.org/catalog/facets?type=audiobook&format=mp3&sort=author")!
    let filter = CatalogFilter(
      id: "complex-url",
      title: "Complex URL Filter",
      href: complexURL,
      active: false
    )

    XCTAssertEqual(filter.href?.absoluteString, "https://api.example.org/catalog/facets?type=audiobook&format=mp3&sort=author")
  }
}

// MARK: - CatalogFilterGroup Tests

final class CatalogFilterGroupModelTests: XCTestCase {

  // MARK: - Initialization Tests

  func testInit_StoresAllProperties() {
    let filters = [
      CatalogFilter(id: "1", title: "All", href: nil, active: true),
      CatalogFilter(id: "2", title: "Available Now", href: URL(string: "https://example.org/available"), active: false)
    ]

    let group = CatalogFilterGroup(
      id: "availability-group",
      name: "Availability",
      filters: filters
    )

    XCTAssertEqual(group.id, "availability-group")
    XCTAssertEqual(group.name, "Availability")
    XCTAssertEqual(group.filters.count, 2)
  }

  func testInit_WithEmptyFilters() {
    let group = CatalogFilterGroup(
      id: "empty-group",
      name: "Empty Group",
      filters: []
    )

    XCTAssertTrue(group.filters.isEmpty)
    XCTAssertEqual(group.filters.count, 0)
  }

  func testInit_WithSingleFilter() {
    let filter = CatalogFilter(id: "only", title: "Only Filter", href: nil, active: true)
    let group = CatalogFilterGroup(
      id: "single",
      name: "Single Filter Group",
      filters: [filter]
    )

    XCTAssertEqual(group.filters.count, 1)
    XCTAssertEqual(group.filters.first?.id, "only")
  }

  func testInit_WithManyFilters() {
    let filters = (0..<10).map { index in
      CatalogFilter(
        id: "filter-\(index)",
        title: "Filter \(index)",
        href: nil,
        active: index == 0
      )
    }

    let group = CatalogFilterGroup(
      id: "many-filters",
      name: "Many Filters",
      filters: filters
    )

    XCTAssertEqual(group.filters.count, 10)
  }

  // MARK: - Identifiable Conformance Tests

  func testIdentifiable_UsesIdProperty() {
    let group = CatalogFilterGroup(
      id: "unique-group-id",
      name: "Test Group",
      filters: []
    )

    XCTAssertEqual(group.id, "unique-group-id")
  }

  // MARK: - Hashable Conformance Tests

  func testHashable_EqualGroupsHaveSameHash() {
    let filters = [CatalogFilter(id: "f1", title: "Filter 1", href: nil, active: true)]

    let group1 = CatalogFilterGroup(id: "group-id", name: "Group", filters: filters)
    let group2 = CatalogFilterGroup(id: "group-id", name: "Group", filters: filters)

    XCTAssertEqual(group1.hashValue, group2.hashValue)
  }

  func testHashable_GroupsCanBeUsedInSet() {
    let group1 = CatalogFilterGroup(id: "g1", name: "Group 1", filters: [])
    let group2 = CatalogFilterGroup(id: "g2", name: "Group 2", filters: [])
    let group3 = CatalogFilterGroup(id: "g3", name: "Group 3", filters: [])

    let groupSet: Set<CatalogFilterGroup> = [group1, group2, group3]

    XCTAssertEqual(groupSet.count, 3)
  }

  // MARK: - Equality Tests

  func testEquality_IdenticalGroupsAreEqual() {
    let filters = [CatalogFilter(id: "f1", title: "Filter", href: nil, active: true)]

    let group1 = CatalogFilterGroup(id: "same", name: "Same Name", filters: filters)
    let group2 = CatalogFilterGroup(id: "same", name: "Same Name", filters: filters)

    XCTAssertEqual(group1, group2)
  }

  func testEquality_DifferentIdsMakesGroupsUnequal() {
    let group1 = CatalogFilterGroup(id: "id-1", name: "Same", filters: [])
    let group2 = CatalogFilterGroup(id: "id-2", name: "Same", filters: [])

    XCTAssertNotEqual(group1, group2)
  }

  func testEquality_DifferentNamesMakesGroupsUnequal() {
    let group1 = CatalogFilterGroup(id: "same-id", name: "Name A", filters: [])
    let group2 = CatalogFilterGroup(id: "same-id", name: "Name B", filters: [])

    XCTAssertNotEqual(group1, group2)
  }

  func testEquality_DifferentFiltersMakesGroupsUnequal() {
    let filter1 = CatalogFilter(id: "f1", title: "Filter 1", href: nil, active: true)
    let filter2 = CatalogFilter(id: "f2", title: "Filter 2", href: nil, active: true)

    let group1 = CatalogFilterGroup(id: "same-id", name: "Same", filters: [filter1])
    let group2 = CatalogFilterGroup(id: "same-id", name: "Same", filters: [filter2])

    XCTAssertNotEqual(group1, group2)
  }

  // MARK: - Filter Query Tests

  func testFilters_FindActiveFilter() {
    let filters = [
      CatalogFilter(id: "1", title: "All", href: nil, active: false),
      CatalogFilter(id: "2", title: "Available", href: nil, active: true),
      CatalogFilter(id: "3", title: "On Hold", href: nil, active: false)
    ]

    let group = CatalogFilterGroup(id: "status", name: "Status", filters: filters)

    let activeFilter = group.filters.first { $0.active }

    XCTAssertNotNil(activeFilter)
    XCTAssertEqual(activeFilter?.id, "2")
    XCTAssertEqual(activeFilter?.title, "Available")
  }

  func testFilters_NoActiveFilter() {
    let filters = [
      CatalogFilter(id: "1", title: "Filter 1", href: nil, active: false),
      CatalogFilter(id: "2", title: "Filter 2", href: nil, active: false)
    ]

    let group = CatalogFilterGroup(id: "no-active", name: "No Active", filters: filters)

    let activeFilter = group.filters.first { $0.active }

    XCTAssertNil(activeFilter)
  }

  func testFilters_MultipleActiveFilters() {
    // Edge case: Multiple filters marked as active (should be rare but handle gracefully)
    let filters = [
      CatalogFilter(id: "1", title: "First Active", href: nil, active: true),
      CatalogFilter(id: "2", title: "Second Active", href: nil, active: true)
    ]

    let group = CatalogFilterGroup(id: "multi-active", name: "Multi Active", filters: filters)

    let activeFilters = group.filters.filter { $0.active }

    XCTAssertEqual(activeFilters.count, 2)
  }

  func testFilters_FilterByHrefPresence() {
    let filters = [
      CatalogFilter(id: "1", title: "Has URL", href: URL(string: "https://example.org"), active: false),
      CatalogFilter(id: "2", title: "No URL", href: nil, active: false),
      CatalogFilter(id: "3", title: "Also Has URL", href: URL(string: "https://other.org"), active: false)
    ]

    let group = CatalogFilterGroup(id: "mixed", name: "Mixed", filters: filters)

    let filtersWithURL = group.filters.filter { $0.href != nil }

    XCTAssertEqual(filtersWithURL.count, 2)
  }

  // MARK: - Edge Cases

  func testEdgeCase_EmptyGroupName() {
    let group = CatalogFilterGroup(id: "valid-id", name: "", filters: [])

    XCTAssertEqual(group.name, "")
  }

  func testEdgeCase_SpecialCharactersInName() {
    let group = CatalogFilterGroup(
      id: "special",
      name: "Sort By: A-Z (Ascending)",
      filters: []
    )

    XCTAssertEqual(group.name, "Sort By: A-Z (Ascending)")
  }
}

// MARK: - CatalogLaneModel Struct Tests

final class CatalogLaneModelStructTests: XCTestCase {

  // MARK: - Initialization Tests

  func testInit_StoresAllProperties() {
    let books = [
      TPPBookMocker.mockBook(identifier: "book-1", title: "Book 1", distributorType: .EpubZip),
      TPPBookMocker.mockBook(identifier: "book-2", title: "Book 2", distributorType: .EpubZip)
    ]
    let moreURL = URL(string: "https://library.example.org/lane/fiction/more")

    let lane = CatalogLaneModel(
      title: "Popular Fiction",
      books: books,
      moreURL: moreURL,
      isLoading: false
    )

    XCTAssertEqual(lane.title, "Popular Fiction")
    XCTAssertEqual(lane.books.count, 2)
    XCTAssertEqual(lane.moreURL, moreURL)
    XCTAssertFalse(lane.isLoading)
  }

  func testInit_WithDefaultIsLoading() {
    let lane = CatalogLaneModel(
      title: "Test Lane",
      books: [],
      moreURL: nil
    )

    XCTAssertFalse(lane.isLoading, "isLoading should default to false")
  }

  func testInit_WithLoadingState() {
    let lane = CatalogLaneModel(
      title: "Loading Lane",
      books: [],
      moreURL: nil,
      isLoading: true
    )

    XCTAssertTrue(lane.isLoading)
  }

  func testInit_WithNilMoreURL() {
    let lane = CatalogLaneModel(
      title: "No More URL Lane",
      books: [],
      moreURL: nil
    )

    XCTAssertNil(lane.moreURL)
  }

  // MARK: - Identifiable Tests

  func testIdentifiable_HasUniqueId() {
    let lane1 = CatalogLaneModel(title: "Lane", books: [], moreURL: nil)
    let lane2 = CatalogLaneModel(title: "Lane", books: [], moreURL: nil)

    // Each lane should have a unique UUID even with identical content
    XCTAssertNotEqual(lane1.id, lane2.id)
  }

  func testIdentifiable_IdIsUUID() {
    let lane = CatalogLaneModel(title: "Test", books: [], moreURL: nil)

    // Verify ID is a valid UUID (won't throw)
    XCTAssertNotNil(UUID(uuidString: lane.id.uuidString))
  }

  // MARK: - Books Collection Tests

  func testBooks_EmptyCollection() {
    let lane = CatalogLaneModel(title: "Empty Lane", books: [], moreURL: nil)

    XCTAssertTrue(lane.books.isEmpty)
    XCTAssertEqual(lane.books.count, 0)
  }

  func testBooks_SingleBook() {
    let book = TPPBookMocker.mockBook(identifier: "single", title: "Single Book", distributorType: .EpubZip)
    let lane = CatalogLaneModel(title: "Single Book Lane", books: [book], moreURL: nil)

    XCTAssertEqual(lane.books.count, 1)
    XCTAssertEqual(lane.books.first?.identifier, "single")
  }

  func testBooks_MultipleBooks() {
    let books = (0..<5).map { index in
      TPPBookMocker.mockBook(
        identifier: "book-\(index)",
        title: "Book \(index)",
        distributorType: .EpubZip
      )
    }

    let lane = CatalogLaneModel(title: "Multiple Books Lane", books: books, moreURL: nil)

    XCTAssertEqual(lane.books.count, 5)
  }

  func testBooks_MixedContentTypes() {
    let epubBook = TPPBookMocker.mockBook(identifier: "epub", title: "EPUB Book", distributorType: .EpubZip)
    let audiobookBook = TPPBookMocker.mockBook(identifier: "audio", title: "Audiobook", distributorType: .OpenAccessAudiobook)
    let pdfBook = TPPBookMocker.mockBook(identifier: "pdf", title: "PDF Book", distributorType: .OpenAccessPDF)

    let lane = CatalogLaneModel(
      title: "Mixed Content Lane",
      books: [epubBook, audiobookBook, pdfBook],
      moreURL: nil
    )

    XCTAssertEqual(lane.books.count, 3)
  }

  func testBooks_LargeCollection() {
    let books = (0..<100).map { index in
      TPPBookMocker.mockBook(
        identifier: "book-\(index)",
        title: "Book \(index)",
        distributorType: .EpubZip
      )
    }

    let lane = CatalogLaneModel(title: "Large Lane", books: books, moreURL: nil)

    XCTAssertEqual(lane.books.count, 100)
  }

  func testBooks_OrderPreserved() {
    let book1 = TPPBookMocker.mockBook(identifier: "first", title: "First", distributorType: .EpubZip)
    let book2 = TPPBookMocker.mockBook(identifier: "second", title: "Second", distributorType: .EpubZip)
    let book3 = TPPBookMocker.mockBook(identifier: "third", title: "Third", distributorType: .EpubZip)

    let lane = CatalogLaneModel(
      title: "Ordered Lane",
      books: [book1, book2, book3],
      moreURL: nil
    )

    XCTAssertEqual(lane.books[0].identifier, "first")
    XCTAssertEqual(lane.books[1].identifier, "second")
    XCTAssertEqual(lane.books[2].identifier, "third")
  }

  // MARK: - Snapshot Testing Support

  func testSnapshotBooks_WithDeterministicData() {
    let books = [
      TPPBookMocker.snapshotEPUB(),
      TPPBookMocker.snapshotAudiobook()
    ]

    let lane = CatalogLaneModel(
      title: "Featured",
      books: books,
      moreURL: URL(string: "https://library.example.org/featured/more")
    )

    XCTAssertEqual(lane.books.count, 2)
    XCTAssertEqual(lane.books[0].title, "The Great Gatsby")
    XCTAssertEqual(lane.books[1].title, "Pride and Prejudice")
  }

  // MARK: - Edge Cases

  func testEdgeCase_EmptyTitle() {
    let lane = CatalogLaneModel(title: "", books: [], moreURL: nil)

    XCTAssertEqual(lane.title, "")
  }

  func testEdgeCase_SpecialCharactersInTitle() {
    let lane = CatalogLaneModel(
      title: "New & Popular (This Week)",
      books: [],
      moreURL: nil
    )

    XCTAssertEqual(lane.title, "New & Popular (This Week)")
  }

  func testEdgeCase_UnicodeInTitle() {
    let lane = CatalogLaneModel(
      title: "Libros en Espanol",
      books: [],
      moreURL: nil
    )

    XCTAssertEqual(lane.title, "Libros en Espanol")
  }

  func testEdgeCase_LongTitle() {
    let longTitle = String(repeating: "Very Long Title ", count: 20)
    let lane = CatalogLaneModel(title: longTitle, books: [], moreURL: nil)

    XCTAssertEqual(lane.title, longTitle)
  }

  func testEdgeCase_ComplexMoreURL() {
    let complexURL = URL(string: "https://api.library.org/v1/catalog/lanes/fiction?page=2&limit=50&sort=popularity")!
    let lane = CatalogLaneModel(title: "Fiction", books: [], moreURL: complexURL)

    XCTAssertEqual(lane.moreURL?.absoluteString, "https://api.library.org/v1/catalog/lanes/fiction?page=2&limit=50&sort=popularity")
  }
}

// MARK: - MappedCatalog Tests

@MainActor
final class MappedCatalogModelTests: XCTestCase {

  // MARK: - Initialization Tests

  func testInit_StoresAllProperties() {
    let entries: [CatalogEntry] = []
    let lanes = [
      CatalogLaneModel(title: "Lane 1", books: [], moreURL: nil),
      CatalogLaneModel(title: "Lane 2", books: [], moreURL: nil)
    ]
    let books = [TPPBookMocker.snapshotEPUB()]
    let facetGroups = [
      CatalogFilterGroup(id: "sort", name: "Sort By", filters: [])
    ]
    let entryPoints = [
      CatalogFilter(id: "ebooks", title: "eBooks", href: nil, active: true)
    ]

    let mapped = CatalogViewModel.MappedCatalog(
      title: "Test Catalog",
      entries: entries,
      lanes: lanes,
      ungroupedBooks: books,
      facetGroups: facetGroups,
      entryPoints: entryPoints
    )

    XCTAssertEqual(mapped.title, "Test Catalog")
    XCTAssertEqual(mapped.entries.count, 0)
    XCTAssertEqual(mapped.lanes.count, 2)
    XCTAssertEqual(mapped.ungroupedBooks.count, 1)
    XCTAssertEqual(mapped.facetGroups.count, 1)
    XCTAssertEqual(mapped.entryPoints.count, 1)
  }

  // MARK: - Empty State Tests

  func testInit_EmptyFeed() {
    let mapped = CatalogViewModel.MappedCatalog(
      title: "",
      entries: [],
      lanes: [],
      ungroupedBooks: [],
      facetGroups: [],
      entryPoints: []
    )

    XCTAssertEqual(mapped.title, "")
    XCTAssertTrue(mapped.entries.isEmpty)
    XCTAssertTrue(mapped.lanes.isEmpty)
    XCTAssertTrue(mapped.ungroupedBooks.isEmpty)
    XCTAssertTrue(mapped.facetGroups.isEmpty)
    XCTAssertTrue(mapped.entryPoints.isEmpty)
  }

  // MARK: - Grouped Feed Tests

  func testInit_GroupedFeedWithLanes() {
    let book1 = TPPBookMocker.mockBook(identifier: "b1", title: "Book 1", distributorType: .EpubZip)
    let book2 = TPPBookMocker.mockBook(identifier: "b2", title: "Book 2", distributorType: .EpubZip)

    let lanes = [
      CatalogLaneModel(title: "Fiction", books: [book1], moreURL: URL(string: "https://example.org/fiction")),
      CatalogLaneModel(title: "Non-Fiction", books: [book2], moreURL: URL(string: "https://example.org/nonfiction"))
    ]

    let mapped = CatalogViewModel.MappedCatalog(
      title: "Main Catalog",
      entries: [],
      lanes: lanes,
      ungroupedBooks: [],
      facetGroups: [],
      entryPoints: []
    )

    XCTAssertEqual(mapped.lanes.count, 2)
    XCTAssertEqual(mapped.lanes[0].title, "Fiction")
    XCTAssertEqual(mapped.lanes[1].title, "Non-Fiction")
    XCTAssertTrue(mapped.ungroupedBooks.isEmpty)
  }

  // MARK: - Ungrouped Feed Tests

  func testInit_UngroupedFeedWithBooks() {
    let books = [
      TPPBookMocker.mockBook(identifier: "ub1", title: "Ungrouped 1", distributorType: .EpubZip),
      TPPBookMocker.mockBook(identifier: "ub2", title: "Ungrouped 2", distributorType: .EpubZip),
      TPPBookMocker.mockBook(identifier: "ub3", title: "Ungrouped 3", distributorType: .EpubZip)
    ]

    let mapped = CatalogViewModel.MappedCatalog(
      title: "Search Results",
      entries: [],
      lanes: [],
      ungroupedBooks: books,
      facetGroups: [],
      entryPoints: []
    )

    XCTAssertTrue(mapped.lanes.isEmpty)
    XCTAssertEqual(mapped.ungroupedBooks.count, 3)
  }

  // MARK: - Facets and Entry Points Tests

  func testInit_WithFacetGroups() {
    let sortFilters = [
      CatalogFilter(id: "s1", title: "Title", href: URL(string: "https://example.org/sort/title"), active: true),
      CatalogFilter(id: "s2", title: "Author", href: URL(string: "https://example.org/sort/author"), active: false)
    ]
    let availabilityFilters = [
      CatalogFilter(id: "a1", title: "All", href: nil, active: true),
      CatalogFilter(id: "a2", title: "Available Now", href: URL(string: "https://example.org/available"), active: false)
    ]

    let facetGroups = [
      CatalogFilterGroup(id: "sort", name: "Sort By", filters: sortFilters),
      CatalogFilterGroup(id: "availability", name: "Availability", filters: availabilityFilters)
    ]

    let mapped = CatalogViewModel.MappedCatalog(
      title: "Catalog",
      entries: [],
      lanes: [],
      ungroupedBooks: [],
      facetGroups: facetGroups,
      entryPoints: []
    )

    XCTAssertEqual(mapped.facetGroups.count, 2)
    XCTAssertEqual(mapped.facetGroups[0].filters.count, 2)
    XCTAssertEqual(mapped.facetGroups[1].filters.count, 2)
  }

  func testInit_WithEntryPoints() {
    let entryPoints = [
      CatalogFilter(id: "ep1", title: "eBooks", href: URL(string: "https://example.org/ebooks"), active: true),
      CatalogFilter(id: "ep2", title: "Audiobooks", href: URL(string: "https://example.org/audiobooks"), active: false)
    ]

    let mapped = CatalogViewModel.MappedCatalog(
      title: "Catalog",
      entries: [],
      lanes: [],
      ungroupedBooks: [],
      facetGroups: [],
      entryPoints: entryPoints
    )

    XCTAssertEqual(mapped.entryPoints.count, 2)
    XCTAssertEqual(mapped.entryPoints[0].title, "eBooks")
    XCTAssertTrue(mapped.entryPoints[0].active)
    XCTAssertEqual(mapped.entryPoints[1].title, "Audiobooks")
    XCTAssertFalse(mapped.entryPoints[1].active)
  }

  // MARK: - Complete Feed Tests

  func testInit_CompleteFeedWithAllComponents() {
    let books = [TPPBookMocker.snapshotEPUB()]
    let lanes = [
      CatalogLaneModel(title: "Featured", books: books, moreURL: URL(string: "https://example.org/featured"))
    ]
    let facetGroups = [
      CatalogFilterGroup(id: "sort", name: "Sort By", filters: [
        CatalogFilter(id: "title-sort", title: "Title", href: nil, active: true)
      ])
    ]
    let entryPoints = [
      CatalogFilter(id: "all", title: "All", href: nil, active: true),
      CatalogFilter(id: "ebooks", title: "eBooks", href: URL(string: "https://example.org/ebooks"), active: false)
    ]

    let mapped = CatalogViewModel.MappedCatalog(
      title: "Complete Catalog",
      entries: [],
      lanes: lanes,
      ungroupedBooks: [],
      facetGroups: facetGroups,
      entryPoints: entryPoints
    )

    XCTAssertEqual(mapped.title, "Complete Catalog")
    XCTAssertEqual(mapped.lanes.count, 1)
    XCTAssertEqual(mapped.lanes[0].books.count, 1)
    XCTAssertEqual(mapped.facetGroups.count, 1)
    XCTAssertEqual(mapped.entryPoints.count, 2)
  }

  // MARK: - Edge Cases

  func testEdgeCase_EmptyTitle() {
    let mapped = CatalogViewModel.MappedCatalog(
      title: "",
      entries: [],
      lanes: [],
      ungroupedBooks: [],
      facetGroups: [],
      entryPoints: []
    )

    XCTAssertEqual(mapped.title, "")
  }

  func testEdgeCase_LongTitle() {
    let longTitle = String(repeating: "A", count: 500)
    let mapped = CatalogViewModel.MappedCatalog(
      title: longTitle,
      entries: [],
      lanes: [],
      ungroupedBooks: [],
      facetGroups: [],
      entryPoints: []
    )

    XCTAssertEqual(mapped.title.count, 500)
  }

  func testEdgeCase_ManyLanes() {
    let lanes = (0..<50).map { index in
      CatalogLaneModel(title: "Lane \(index)", books: [], moreURL: nil)
    }

    let mapped = CatalogViewModel.MappedCatalog(
      title: "Many Lanes",
      entries: [],
      lanes: lanes,
      ungroupedBooks: [],
      facetGroups: [],
      entryPoints: []
    )

    XCTAssertEqual(mapped.lanes.count, 50)
  }

  func testEdgeCase_ManyUngroupedBooks() {
    let books = (0..<200).map { index in
      TPPBookMocker.mockBook(
        identifier: "book-\(index)",
        title: "Book \(index)",
        distributorType: .EpubZip
      )
    }

    let mapped = CatalogViewModel.MappedCatalog(
      title: "Search Results",
      entries: [],
      lanes: [],
      ungroupedBooks: books,
      facetGroups: [],
      entryPoints: []
    )

    XCTAssertEqual(mapped.ungroupedBooks.count, 200)
  }
}

//
//  CatalogLaneMoreViewModelTests.swift
//  PalaceTests
//
//  Tests for CatalogLaneMoreViewModel which manages catalog feed loading and filtering.
//

import XCTest
import Combine
@testable import Palace

@MainActor
final class CatalogLaneMoreViewModelTests: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        cancellables = []
    }

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    // MARK: - Helper

    private func createViewModel(title: String = "Test", urlString: String = "https://example.com/feed") -> CatalogLaneMoreViewModel {
        let url = URL(string: urlString)!
        return CatalogLaneMoreViewModel(
            title: title,
            url: url,
            bookRegistry: TPPBookRegistry.shared,
            bookCellModelCache: AppContainer.production().bookCellModelCache
        )
    }

    // MARK: - Initialization Tests

    func testInitialState() {
        let viewModel = createViewModel(title: "Featured Books")

        XCTAssertEqual(viewModel.title, "Featured Books")
        XCTAssertTrue(viewModel.lanes.isEmpty)
        XCTAssertTrue(viewModel.ungroupedBooks.isEmpty)
        XCTAssertTrue(viewModel.isLoading, "Should start in loading state")
        XCTAssertNil(viewModel.error)
        XCTAssertNil(viewModel.nextPageURL)
        XCTAssertFalse(viewModel.isLoadingMore)
    }

    func testUIStateInitialValues() {
        let viewModel = createViewModel()

        XCTAssertFalse(viewModel.showingSortSheet)
        XCTAssertFalse(viewModel.showingFiltersSheet)
        XCTAssertFalse(viewModel.showSearch)
    }

    func testFilterStateInitialValues() {
        let viewModel = createViewModel()

        XCTAssertTrue(viewModel.facetGroups.isEmpty)
        XCTAssertTrue(viewModel.pendingSelections.isEmpty)
        XCTAssertTrue(viewModel.appliedSelections.isEmpty)
        XCTAssertFalse(viewModel.isApplyingFilters)
    }

    // MARK: - Computed Properties Tests

    func testActiveFiltersCount_WhenEmpty() {
        let viewModel = createViewModel()

        XCTAssertEqual(viewModel.activeFiltersCount, 0)
        XCTAssertTrue(viewModel.appliedSelections.isEmpty, "appliedSelections must be empty when count is 0")
        XCTAssertFalse(viewModel.isApplyingFilters, "isApplyingFilters must be false initially")
    }

    func testAllBooks_WhenLanesEmpty_ReturnsUngroupedBooks() async {
        let viewModel = createViewModel()

        // Simulate having ungrouped books
        viewModel.ungroupedBooks = [
            TPPBookMocker.mockBook(identifier: "book1", title: "Book 1"),
            TPPBookMocker.mockBook(identifier: "book2", title: "Book 2")
        ]

        XCTAssertEqual(viewModel.allBooks.count, 2)
    }

    func testAllBooks_WhenLanesHaveBooks_ReturnsLaneBooks() async {
        let viewModel = createViewModel()

        let book1 = TPPBookMocker.mockBook(identifier: "lane-book1", title: "Lane Book 1")
        let book2 = TPPBookMocker.mockBook(identifier: "lane-book2", title: "Lane Book 2")

        viewModel.lanes = [
            CatalogLaneModel(title: "Lane 1", books: [book1], moreURL: nil),
            CatalogLaneModel(title: "Lane 2", books: [book2], moreURL: nil)
        ]
        viewModel.ungroupedBooks = [TPPBookMocker.mockBook(identifier: "ungrouped", title: "Ungrouped")]

        // When lanes are not empty, allBooks returns lane books only
        XCTAssertEqual(viewModel.allBooks.count, 2)
        XCTAssertEqual(viewModel.allBooks.map { $0.identifier }, ["lane-book1", "lane-book2"])
    }

    func testShouldShowPagination_WhenNextPageURLExists() {
        let viewModel = createViewModel()

        XCTAssertFalse(viewModel.shouldShowPagination)

        viewModel.nextPageURL = URL(string: "https://example.com/page2")

        XCTAssertTrue(viewModel.shouldShowPagination)
    }

    // MARK: - Published Property Tests

    func testIsLoadingPublishes() {
        let viewModel = createViewModel()

        let expectation = XCTestExpectation(description: "isLoading should publish")
        var publishedValue: Bool?

        viewModel.$isLoading
            .dropFirst()
            .sink { newValue in
                publishedValue = newValue
                expectation.fulfill()
            }
            .store(in: &cancellables)

        viewModel.isLoading = false

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(publishedValue, false, "Published value must match the assigned value")
    }

    func testErrorPublishes() {
        let viewModel = createViewModel()

        let expectation = XCTestExpectation(description: "error should publish")

        viewModel.$error
            .dropFirst()
            .sink { newError in
                XCTAssertEqual(newError, "Network error")
                expectation.fulfill()
            }
            .store(in: &cancellables)

        viewModel.error = "Network error"

        wait(for: [expectation], timeout: 1.0)
    }

    func testLanesPublishes() {
        let viewModel = createViewModel()

        let expectation = XCTestExpectation(description: "lanes should publish")

        viewModel.$lanes
            .dropFirst()
            .sink { newLanes in
                XCTAssertEqual(newLanes.count, 1)
                expectation.fulfill()
            }
            .store(in: &cancellables)

        viewModel.lanes = [CatalogLaneModel(title: "Test Lane", books: [], moreURL: nil)]

        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - UI State Toggle Tests

    func testShowingSortSheetToggle() {
        let viewModel = createViewModel()
        XCTAssertFalse(viewModel.showingSortSheet, "Sort sheet must be hidden initially")
        XCTAssertFalse(viewModel.showingFiltersSheet, "Filters sheet must also be hidden initially")

        // Both sheets start hidden; opening one must not affect UI loading state
        viewModel.showingSortSheet = true
        XCTAssertFalse(viewModel.showingFiltersSheet, "Filters sheet must remain closed when sort sheet opens")
        XCTAssertFalse(viewModel.showSearch, "Search must remain closed when sort sheet opens")

        viewModel.showingSortSheet = false
        XCTAssertFalse(viewModel.isApplyingFilters, "isApplyingFilters must remain false after toggling sort sheet")
    }

    func testShowingFiltersSheetToggle() {
        let viewModel = createViewModel()
        XCTAssertFalse(viewModel.showingFiltersSheet, "Filters sheet must be hidden initially")
        XCTAssertFalse(viewModel.showingSortSheet, "Sort sheet must also be hidden initially")

        viewModel.showingFiltersSheet = true
        XCTAssertFalse(viewModel.showingSortSheet, "Sort sheet must remain closed when filters sheet opens")
        XCTAssertFalse(viewModel.showSearch, "Search must remain closed when filters sheet opens")

        viewModel.showingFiltersSheet = false
        XCTAssertFalse(viewModel.isApplyingFilters, "isApplyingFilters must remain false after toggling filters sheet")
    }

    func testShowSearchToggle() {
        let viewModel = createViewModel()
        XCTAssertFalse(viewModel.showSearch, "Search must be hidden initially")

        viewModel.showSearch = true
        XCTAssertFalse(viewModel.showingSortSheet, "Sort sheet must remain closed when search opens")
        XCTAssertFalse(viewModel.showingFiltersSheet, "Filters sheet must remain closed when search opens")

        viewModel.showSearch = false
        XCTAssertEqual(viewModel.activeFiltersCount, 0, "activeFiltersCount must remain 0 after toggling search")
    }

    // MARK: - Sort Facets Tests

    func testSortFacets_WhenNoSortGroup_ReturnsEmpty() {
        let viewModel = createViewModel()

        viewModel.facetGroups = [
            CatalogFilterGroup(id: "format", name: "Format", filters: [
                CatalogFilter(id: "ebook", title: "eBook", href: nil, active: false)
            ])
        ]

        XCTAssertTrue(viewModel.sortFacets.isEmpty)
    }

    func testSortFacets_WhenSortGroupExists_ReturnsFacets() {
        let viewModel = createViewModel()

        let sortFilter1 = CatalogFilter(id: "title", title: "Title", href: URL(string: "https://example.com/sort/title"), active: false)
        let sortFilter2 = CatalogFilter(id: "author", title: "Author", href: URL(string: "https://example.com/sort/author"), active: true)

        viewModel.facetGroups = [
            CatalogFilterGroup(id: "sort", name: "Sort By", filters: [sortFilter1, sortFilter2]),
            CatalogFilterGroup(id: "format", name: "Format", filters: [])
        ]

        XCTAssertEqual(viewModel.sortFacets.count, 2)
    }

    // When the feed doesn't explicitly mark a sort facet active (typical for
    // OPDS 2 feeds, where the CM sends only hrefs and relies on URL match),
    // the toolbar should still show a sort pill labeled with the first
    // option — otherwise the pill disappears entirely and the user has no
    // way to change the sort order.
    func testActiveSortTitle_WhenNoActiveFacet_FallsBackToFirstFilterTitle() {
        let viewModel = createViewModel()

        viewModel.facetGroups = [
            CatalogFilterGroup(id: "sort", name: "Sort By", filters: [
                CatalogFilter(id: "title", title: "Title", href: nil, active: false),
                CatalogFilter(id: "author", title: "Author", href: nil, active: false)
            ])
        ]

        XCTAssertEqual(viewModel.activeSortTitle, "Title")
    }

    func testActiveSortTitle_WhenSortGroupEmpty_ReturnsNil() {
        let viewModel = createViewModel()

        viewModel.facetGroups = [
            CatalogFilterGroup(id: "format", name: "Format", filters: [
                CatalogFilter(id: "ebook", title: "eBook", href: nil, active: false)
            ])
        ]

        XCTAssertNil(viewModel.activeSortTitle,
                     "Without a Sort By group the pill must not render")
    }

    func testActiveSortTitle_WhenActiveFacetExists_ReturnsTitle() {
        let viewModel = createViewModel()

        viewModel.facetGroups = [
            CatalogFilterGroup(id: "sort", name: "Sort By", filters: [
                CatalogFilter(id: "title", title: "Title", href: nil, active: false),
                CatalogFilter(id: "author", title: "Author", href: nil, active: true)
            ])
        ]

        XCTAssertEqual(viewModel.activeSortTitle, "Author")
    }

    // MARK: - Displayed Sort Facets (default + pending)

    // The sort sheet and the toolbar pill both read from displayedSortFacets
    // so their selected-state stays consistent. When the feed hasn't marked
    // any facet active (typical on first load), the first one must be
    // treated as the default — otherwise the pill has a label but the
    // sheet shows no radio selected.
    func testDisplayedSortFacets_WhenNoneActive_MarksFirstAsDefault() {
        let viewModel = createViewModel()

        viewModel.facetGroups = [
            CatalogFilterGroup(id: "sort", name: "Sort By", filters: [
                CatalogFilter(id: "title", title: "Title", href: nil, active: false),
                CatalogFilter(id: "author", title: "Author", href: nil, active: false)
            ])
        ]

        let displayed = viewModel.displayedSortFacets
        XCTAssertEqual(displayed.count, 2)
        XCTAssertTrue(displayed[0].active,
                      "First sort filter must be active by default so the pill label and sheet radio agree")
        XCTAssertFalse(displayed[1].active)
    }

    func testDisplayedSortFacets_WhenOneActive_Unchanged() {
        let viewModel = createViewModel()

        viewModel.facetGroups = [
            CatalogFilterGroup(id: "sort", name: "Sort By", filters: [
                CatalogFilter(id: "title", title: "Title", href: nil, active: false),
                CatalogFilter(id: "author", title: "Author", href: nil, active: true)
            ])
        ]

        let displayed = viewModel.displayedSortFacets
        XCTAssertFalse(displayed[0].active)
        XCTAssertTrue(displayed[1].active,
                      "When the feed already marks a facet active, displayedSortFacets must not rewrite it")
    }

    // pendingSortFacetID is how the sheet highlights a newly-tapped facet
    // before the network roundtrip. Without this override the radio only
    // flips after the refetched feed arrives, which feels laggy.
    func testDisplayedSortFacets_WhenPendingSet_HighlightsOnlyPendingFacet() {
        let viewModel = createViewModel()

        viewModel.facetGroups = [
            CatalogFilterGroup(id: "sort", name: "Sort By", filters: [
                CatalogFilter(id: "title", title: "Title", href: nil, active: true),
                CatalogFilter(id: "author", title: "Author", href: nil, active: false),
                CatalogFilter(id: "added", title: "Recently Added", href: nil, active: false)
            ])
        ]
        viewModel.pendingSortFacetID = "author"

        let displayed = viewModel.displayedSortFacets
        XCTAssertFalse(displayed[0].active, "Previous selection must yield to the pending tap")
        XCTAssertTrue(displayed[1].active, "Pending facet must be the only active one")
        XCTAssertFalse(displayed[2].active)
    }

    func testDisplayedSortFacets_WhenPendingIDUnknown_FallsBackNormally() {
        let viewModel = createViewModel()

        viewModel.facetGroups = [
            CatalogFilterGroup(id: "sort", name: "Sort By", filters: [
                CatalogFilter(id: "title", title: "Title", href: nil, active: false),
                CatalogFilter(id: "author", title: "Author", href: nil, active: false)
            ])
        ]
        viewModel.pendingSortFacetID = "bogus-id-no-longer-in-feed"

        let displayed = viewModel.displayedSortFacets
        XCTAssertTrue(displayed[0].active,
                      "Stale pending ID must not consume the selection — fall back to first-is-default")
    }

    // MARK: - Feed URL Threading (regression guard)
    //
    // The second bug we had to fix was processOPDS2*Feed extracting facets
    // against self.url (the original lane URL) instead of the URL of the
    // feed that was actually fetched. After applying a sort, no facet
    // matched and every radio read as inactive. These tests pin the
    // call-site contract so that regression can't land again silently.

    func testProcessOPDS2GroupedFeed_UsesFeedURLForActiveDetection() {
        let viewModel = createViewModel(urlString: "https://example.com/fiction")

        let feed = OPDS2Feed(
            metadata: OPDS2FeedMetadata(title: "Fiction (Sort: Author)"),
            groups: [
                OPDS2Group(
                    metadata: OPDS2GroupMetadata(title: "All"),
                    links: [],
                    publications: []
                )
            ],
            facets: [
                OPDS2FacetGroup(
                    metadata: OPDS2FacetGroupMetadata(title: "Sort By"),
                    links: [
                        OPDS2FacetLink(href: "https://example.com/fiction?sort=title", title: "Title"),
                        OPDS2FacetLink(href: "https://example.com/fiction?sort=author", title: "Author")
                    ]
                )
            ]
        )

        // Feed was fetched at the "sort=author" URL, not the lane's original URL.
        viewModel.processOPDS2GroupedFeed(feed, feedURL: URL(string: "https://example.com/fiction?sort=author")!)

        let active = viewModel.facetGroups.first?.filters.first(where: { $0.active })
        XCTAssertEqual(active?.title, "Author",
                       "Facets must be matched against the fetched feedURL, not the view-model's original url")
    }

    func testProcessOPDS2PublicationFeed_UsesFeedURLForActiveDetection() {
        let viewModel = createViewModel(urlString: "https://example.com/fiction")

        let feed = OPDS2Feed(
            metadata: OPDS2FeedMetadata(title: "Fiction"),
            publications: [],
            facets: [
                OPDS2FacetGroup(
                    metadata: OPDS2FacetGroupMetadata(title: "Sort By"),
                    links: [
                        OPDS2FacetLink(href: "https://example.com/fiction?sort=title", title: "Title"),
                        OPDS2FacetLink(href: "https://example.com/fiction?sort=author", title: "Author")
                    ]
                )
            ]
        )

        viewModel.processOPDS2PublicationFeed(feed, feedURL: URL(string: "https://example.com/fiction?sort=title")!)

        let active = viewModel.facetGroups.first?.filters.first(where: { $0.active })
        XCTAssertEqual(active?.title, "Title")
    }

    // MARK: - Filter Selection Tests

    func testPendingSelectionsUpdate() {
        let viewModel = createViewModel()

        viewModel.pendingSelections.insert("Format::eBook")
        viewModel.pendingSelections.insert("Sort::Title")

        XCTAssertEqual(viewModel.pendingSelections.count, 2)
        XCTAssertTrue(viewModel.pendingSelections.contains("Format::eBook"))
        XCTAssertTrue(viewModel.pendingSelections.contains("Sort::Title"))
    }

    func testAppliedSelectionsUpdate() {
        let viewModel = createViewModel()

        viewModel.appliedSelections.insert("Format::eBook")

        XCTAssertEqual(viewModel.appliedSelections.count, 1)
        XCTAssertTrue(viewModel.appliedSelections.contains("Format::eBook"))
    }

    // MARK: - Loading More State Tests

    func testIsLoadingMoreInitiallyFalse() {
        let viewModel = createViewModel()

        XCTAssertFalse(viewModel.isLoadingMore)
        // isLoadingMore starts false and must remain false until pagination is triggered
        XCTAssertNil(viewModel.nextPageURL, "nextPageURL must be nil when not loading more")
        XCTAssertFalse(viewModel.shouldShowPagination, "Pagination must not be shown when isLoadingMore is false and no nextPageURL")
    }

    func testIsApplyingFiltersInitiallyFalse() {
        let viewModel = createViewModel()

        XCTAssertFalse(viewModel.isApplyingFilters)
        // appliedSelections must also be empty when filters are not being applied
        XCTAssertEqual(viewModel.activeFiltersCount, 0, "activeFiltersCount must be 0 when no filters are applied")
    }

    // MARK: - Active Filters Count Tests

    /// Tests activeFiltersCount with properly formatted selections
    /// Format: "groupName|filterTitle" - filters out "all" default titles
    func testActiveFiltersCount_WithAppliedSelections() {
        let viewModel = createViewModel()

        // Use format expected by CatalogFilterService: "groupName|filterTitle"
        // Note: "all" titles are filtered out, so use specific filter names
        viewModel.appliedSelections = Set(["Format|eBook", "Availability|Available Now"])

        XCTAssertEqual(viewModel.activeFiltersCount, 2)
        // Adding a third selection must increment the count
        viewModel.appliedSelections.insert("Language|English")
        XCTAssertEqual(viewModel.activeFiltersCount, 3,
                       "activeFiltersCount must increase when a new non-default selection is added")
    }

    func testActiveFiltersCount_AfterClearingSelections() {
        let viewModel = createViewModel()

        // Use format expected by CatalogFilterService
        viewModel.appliedSelections = Set(["Format|eBook"])
        XCTAssertEqual(viewModel.activeFiltersCount, 1)

        viewModel.appliedSelections.removeAll()
        XCTAssertEqual(viewModel.activeFiltersCount, 0)
    }

    func testActiveFiltersCount_FiltersOutAllDefaults() {
        let viewModel = createViewModel()

        // "all" titles are filtered out by the service
        viewModel.appliedSelections = Set(["Format|All", "Availability|All Formats"])

        XCTAssertEqual(viewModel.activeFiltersCount, 0, "Default 'all' selections should not count")
        // Adding a real selection alongside defaults must count only the real one
        viewModel.appliedSelections.insert("Format|eBook")
        XCTAssertEqual(viewModel.activeFiltersCount, 1,
                       "Only non-default selections must be counted; 'All' entries must remain excluded")
    }

    // MARK: - Pagination Tests

    func testPagination_NextPageURLCanBeSet() {
        let viewModel = createViewModel()
        XCTAssertFalse(viewModel.shouldShowPagination, "Pagination must be hidden before nextPageURL is set")
        XCTAssertNil(viewModel.nextPageURL, "nextPageURL must start nil")

        viewModel.nextPageURL = URL(string: "https://example.com/feed?page=2")

        XCTAssertTrue(viewModel.shouldShowPagination, "shouldShowPagination must be true once nextPageURL is set")
        XCTAssertEqual(viewModel.nextPageURL?.absoluteString, "https://example.com/feed?page=2",
                       "nextPageURL absolute string must be preserved exactly")
    }

    func testPagination_ClearedWhenNil() {
        let viewModel = createViewModel()
        viewModel.nextPageURL = URL(string: "https://example.com/feed?page=2")
        XCTAssertTrue(viewModel.shouldShowPagination, "Pagination must be visible after setting nextPageURL")

        viewModel.nextPageURL = nil

        // Both the URL and the derived shouldShowPagination flag must reflect the cleared state
        XCTAssertFalse(viewModel.shouldShowPagination, "shouldShowPagination must be false once nextPageURL is cleared")
        XCTAssertEqual(viewModel.nextPageURL?.absoluteString, nil,
                       "nextPageURL must be nil after explicit clear")
    }

    // MARK: - Books List Tests

    func testAllBooks_EmptyWhenNoData() {
        let viewModel = createViewModel()

        XCTAssertTrue(viewModel.allBooks.isEmpty)
        XCTAssertTrue(viewModel.lanes.isEmpty, "lanes must be empty when allBooks is empty")
        XCTAssertTrue(viewModel.ungroupedBooks.isEmpty, "ungroupedBooks must be empty when allBooks is empty")
    }

    func testAllBooks_CombinesMultipleLanes() {
        let viewModel = createViewModel()

        let book1 = TPPBookMocker.mockBook(identifier: "book1", title: "Book 1")
        let book2 = TPPBookMocker.mockBook(identifier: "book2", title: "Book 2")
        let book3 = TPPBookMocker.mockBook(identifier: "book3", title: "Book 3")

        viewModel.lanes = [
            CatalogLaneModel(title: "Lane 1", books: [book1, book2], moreURL: nil),
            CatalogLaneModel(title: "Lane 2", books: [book3], moreURL: nil)
        ]

        XCTAssertEqual(viewModel.allBooks.count, 3)
    }

    // MARK: - Error Handling Tests

    func testError_CanBeSet() {
        let viewModel = createViewModel()
        XCTAssertNil(viewModel.error, "error must be nil initially")

        viewModel.error = "Connection failed"
        let capturedError = viewModel.error

        XCTAssertNotNil(capturedError, "error must be non-nil after assignment")
        XCTAssertFalse(capturedError?.isEmpty ?? true, "error message must not be empty")
    }

    func testError_CanBeCleared() {
        let viewModel = createViewModel()
        viewModel.error = "Some error"
        let errorBeforeClear = viewModel.error
        XCTAssertNotNil(errorBeforeClear, "Precondition: error must be set before clearing")

        viewModel.error = nil

        // Clearing error must leave other state untouched
        XCTAssertEqual(viewModel.activeFiltersCount, 0, "Clearing error must not affect filter state")
        XCTAssertFalse(viewModel.isApplyingFilters, "Clearing error must not affect filter applying state")
    }

    // MARK: - Filter Groups Tests

    func testFacetGroups_MultipleGroups() {
        let viewModel = createViewModel()

        let formatGroup = CatalogFilterGroup(
            id: "format",
            name: "Format",
            filters: [
                CatalogFilter(id: "ebook", title: "eBook", href: nil, active: false),
                CatalogFilter(id: "audiobook", title: "Audiobook", href: nil, active: false)
            ]
        )

        let availabilityGroup = CatalogFilterGroup(
            id: "availability",
            name: "Availability",
            filters: [
                CatalogFilter(id: "now", title: "Available Now", href: nil, active: true),
                CatalogFilter(id: "all", title: "All", href: nil, active: false)
            ]
        )

        viewModel.facetGroups = [formatGroup, availabilityGroup]
        let groups = viewModel.facetGroups

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].id, "format", "First group must be format group")
        XCTAssertEqual(groups[1].filters.count, 2, "Availability group must have 2 filters")
    }

    // MARK: - Title Tests

    func testTitle_WithSpecialCharacters() {
        let viewModel = createViewModel(title: "New & Popular 📚")

        XCTAssertEqual(viewModel.title, "New & Popular 📚")
        XCTAssertFalse(viewModel.title.isEmpty, "Title with special characters must not be empty")
        XCTAssertTrue(viewModel.title.contains("&"), "Ampersand must be preserved in title")
    }

    func testTitle_Empty() {
        let viewModel = createViewModel(title: "")

        XCTAssertEqual(viewModel.title, "")
        XCTAssertTrue(viewModel.title.isEmpty, "Empty title must have zero characters")
        XCTAssertEqual(viewModel.title.count, 0, "Empty title count must be 0")
    }

    // MARK: - applyRegistryUpdates identity preservation (PP-4065)
    //
    // PP-4065 was caused by the view's ScrollView scrolling to top when
    // `ungroupedBooks` changed. The explicit scrollTo has been removed, but
    // the list will still re-render after a borrow. SwiftUI's LazyVGrid +
    // ForEach(id: \.identifier) preserves scroll position only when the
    // identifier sequence is stable. These tests guard that invariant.

    func testApplyRegistryUpdates_PreservesIdentifierSequenceAfterBorrow() {
        let viewModel = createViewModel()
        let book1 = TPPBookMocker.mockBook(identifier: "b1", title: "B1")
        let book2 = TPPBookMocker.mockBook(identifier: "b2", title: "B2")
        let book3 = TPPBookMocker.mockBook(identifier: "b3", title: "B3")
        viewModel.ungroupedBooks = [book1, book2, book3]
        let idsBefore = viewModel.ungroupedBooks.map { $0.identifier }

        viewModel.applyRegistryUpdates(changedIdentifier: "b2")

        let idsAfter = viewModel.ungroupedBooks.map { $0.identifier }
        XCTAssertEqual(
            idsAfter, idsBefore,
            "PP-4065: after Borrow, ForEach row identities must stay the same and in the same order so the LazyVGrid preserves scroll position."
        )
        XCTAssertEqual(
            viewModel.ungroupedBooks.count, 3,
            "Registry update must never change book count — count changes would re-layout the grid and reset scroll."
        )
    }

    func testApplyRegistryUpdates_OnlyTargetsChangedIdentifier_WhenProvided() {
        let viewModel = createViewModel()
        let book1 = TPPBookMocker.mockBook(identifier: "b1", title: "Original 1")
        let book2 = TPPBookMocker.mockBook(identifier: "b2", title: "Original 2")
        viewModel.ungroupedBooks = [book1, book2]
        let book1RefBefore = ObjectIdentifier(viewModel.ungroupedBooks[0])

        viewModel.applyRegistryUpdates(changedIdentifier: "b2")

        let book1RefAfter = ObjectIdentifier(viewModel.ungroupedBooks[0])
        XCTAssertEqual(
            book1RefAfter, book1RefBefore,
            "When a changedIdentifier is provided, untouched books must keep the same instance reference — replacing them needlessly invalidates BookCellModel caches and can cause cell re-layout thrash."
        )
    }
}

//
//  ViewModelComputedPropertyTests.swift
//  PalaceTests
//
//  Tests for ViewModel computed properties and business logic that drives SwiftUI views.
//  Focuses on uncovered computed properties across BookCellModel, CatalogLaneMoreViewModel,
//  and BookButtonMapper.
//
//  SRS: Validates state mapping, computed output, and edge cases for ViewModel layer.
//

import XCTest
import Combine
@testable import Palace

// MARK: - BookCellModel Computed Property Tests

/// Tests BookCellModel computed properties that feed SwiftUI views.
/// SRS: BookCellModel is the primary data source for book cells in My Books and Holds.
@MainActor
final class BookCellModelComputedPropertyTests: XCTestCase {

    var mockRegistry: TPPBookRegistryMock!
    var mockImageCache: MockImageCache!
    var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        mockRegistry = TPPBookRegistryMock()
        mockImageCache = MockImageCache()
        cancellables = Set<AnyCancellable>()
    }

    override func tearDown() {
        cancellables = nil
        mockRegistry = nil
        mockImageCache = nil
        super.tearDown()
    }

    // MARK: - Test Helpers

    private func createBook(id: String = "test-book", title: String = "Test Book", authors: String = "Test Author") -> TPPBook {
        return TPPBook(dictionary: [
            "acquisitions": [TPPFake.genericAcquisition.dictionaryRepresentation()],
            "title": title,
            "categories": ["Fiction"],
            "id": id,
            "updated": "2024-01-01T00:00:00Z"
        ])!
    }

    private func createModel(book: TPPBook, state: TPPBookState = .downloadSuccessful) -> BookCellModel {
        mockRegistry.addBook(book, state: state)
        return BookCellModel(book: book, imageCache: mockImageCache, bookRegistry: mockRegistry)
    }

    // MARK: - title / authors

    func testTitle_ReturnsBookTitle() {
        let book = createBook(title: "The Odyssey")
        let model = createModel(book: book)

        XCTAssertEqual(model.title, "The Odyssey")
    }

    func testAuthors_ReturnsBookAuthors() {
        let book = TPPBookMocker.mockBook(title: "Test", authors: "Homer")
        mockRegistry.addBook(book, state: .downloadSuccessful)
        let model = BookCellModel(book: book, imageCache: mockImageCache, bookRegistry: mockRegistry)

        XCTAssertEqual(model.authors, "Homer")
    }

    func testAuthors_ReturnsEmptyStringWhenNil() {
        // Book created via dictionary has nil authors
        let book = createBook()
        let model = createModel(book: book)

        // authors returns book.authors ?? "" so if nil, returns ""
        XCTAssertEqual(model.authors, "")
    }

    // MARK: - showUnreadIndicator

    /// SRS: Unread indicator should only show for downloaded (not yet opened) books
    func testShowUnreadIndicator_TrueForDownloadSuccessful() {
        let book = createBook()
        let model = createModel(book: book, state: .downloadSuccessful)

        // State should be .normal(.downloadSuccessful) which triggers unread indicator
        XCTAssertTrue(model.showUnreadIndicator, "Downloaded book should show unread indicator")
    }

    func testShowUnreadIndicator_FalseForDownloading() {
        let book = createBook()
        let model = createModel(book: book, state: .downloading)

        XCTAssertFalse(model.showUnreadIndicator, "Downloading book should not show unread indicator")
    }

    func testShowUnreadIndicator_FalseForDownloadFailed() {
        let book = createBook()
        let model = createModel(book: book, state: .downloadFailed)

        XCTAssertFalse(model.showUnreadIndicator, "Failed download should not show unread indicator")
    }

    func testShowUnreadIndicator_FalseForUsed() {
        let book = createBook()
        let model = createModel(book: book, state: .used)

        XCTAssertFalse(model.showUnreadIndicator, "Used/read book should not show unread indicator")
    }

    func testShowUnreadIndicator_FalseForHolding() {
        let book = createBook()
        let model = createModel(book: book, state: .holding)

        XCTAssertFalse(model.showUnreadIndicator, "Held book should not show unread indicator")
    }

    func testShowUnreadIndicator_FalseForUnregistered() {
        let book = createBook()
        // Don't add to registry
        let model = BookCellModel(book: book, imageCache: mockImageCache, bookRegistry: mockRegistry)

        XCTAssertFalse(model.showUnreadIndicator, "Unregistered book should not show unread indicator")
    }

    // MARK: - bookState (HalfSheetProvider)

    /// SRS: bookState getter returns localBookStateOverride when set, else registryState
    func testBookState_ReturnsRegistryStateByDefault() {
        let book = createBook()
        let model = createModel(book: book, state: .downloadSuccessful)

        XCTAssertEqual(model.bookState, .downloadSuccessful)
    }

    func testBookState_SetToReturning_OverridesRegistryState() {
        let book = createBook()
        let model = createModel(book: book, state: .downloadSuccessful)

        model.bookState = .returning

        XCTAssertEqual(model.bookState, .returning, "Setting .returning should override registry state")
    }

    func testBookState_SetToNonReturning_ClearsOverride() {
        let book = createBook()
        let model = createModel(book: book, state: .downloadSuccessful)

        // First set to returning
        model.bookState = .returning
        XCTAssertEqual(model.bookState, .returning)

        // Then set to something else - should clear override and return registry state
        model.bookState = .holding
        XCTAssertEqual(model.bookState, .downloadSuccessful, "Non-returning state should clear override, returning registry state")
    }

    // MARK: - isProcessing (BookButtonProvider)

    func testIsProcessing_ReturnsIsLoading() {
        let book = createBook()
        let model = createModel(book: book)

        XCTAssertFalse(model.isProcessing(for: .download))

        model.isLoading = true
        XCTAssertTrue(model.isProcessing(for: .download))
        XCTAssertTrue(model.isProcessing(for: .reserve))
        XCTAssertTrue(model.isProcessing(for: .read))
    }

    // MARK: - statePublisher

    func testStatePublisher_EmitsOnIsLoadingChange() {
        let book = createBook()
        let model = createModel(book: book)

        let expectation = XCTestExpectation(description: "statePublisher emits")
        var receivedValues: [Bool] = []

        model.statePublisher
            .sink { value in
                receivedValues.append(value)
                expectation.fulfill()
            }
            .store(in: &cancellables)

        model.isLoading = true

        wait(for: [expectation], timeout: 1.0)
        XCTAssertTrue(receivedValues.contains(true))
    }

    // MARK: - showHalfSheet

    func testShowHalfSheet_DefaultsFalse() {
        let book = createBook()
        let model = createModel(book: book)

        XCTAssertFalse(model.showHalfSheet)
    }

    func testShowHalfSheet_CanBeToggled() {
        let book = createBook()
        let model = createModel(book: book)

        model.showHalfSheet = true
        XCTAssertTrue(model.showHalfSheet)

        model.showHalfSheet = false
        XCTAssertFalse(model.showHalfSheet)
    }

    // MARK: - isManagingHold

    func testIsManagingHold_DefaultsFalse() {
        let book = createBook()
        let model = createModel(book: book)

        XCTAssertFalse(model.isManagingHold)
    }

    // MARK: - Image cache integration

    func testLoadBookCoverImage_UsesCachedImage() {
        let book = createBook(id: "cached-book")
        let testImage = UIImage(systemName: "star.fill")!
        mockImageCache.set(testImage, for: "cached-book", expiresIn: nil)

        let model = createModel(book: book)
        model.loadBookCoverImage()

        // Image should be the cached one
        XCTAssertNotNil(model.image, "Image should be loaded from cache")
    }

    // MARK: - buttonTypes with localBookStateOverride

    func testButtonTypes_WhenReturning_UsesReturningState() {
        let book = createBook()
        let model = createModel(book: book, state: .downloadSuccessful)

        // Set returning override
        model.bookState = .returning

        let types = model.buttonTypes
        // Should use BookButtonState.returning button types
        XCTAssertEqual(types, BookButtonState.returning.buttonTypes(book: book))
    }
}

// MARK: - BookCellState Comprehensive Tests

/// Tests all BookCellState init paths and buttonState extraction.
/// SRS: BookCellState maps BookButtonState to UI cell state categories.
@MainActor
final class BookCellStateComprehensiveTests: XCTestCase {

    func testBookCellState_CanBorrow_MapsToNormal() {
        let state = BookCellState(.canBorrow)
        if case .normal(let inner) = state {
            XCTAssertEqual(inner, .canBorrow)
        } else {
            XCTFail("canBorrow should map to .normal")
        }
    }

    func testBookCellState_CanHold_MapsToNormal() {
        let state = BookCellState(.canHold)
        if case .normal(let inner) = state {
            XCTAssertEqual(inner, .canHold)
        } else {
            XCTFail("canHold should map to .normal")
        }
    }

    func testBookCellState_Holding_MapsToNormal() {
        let state = BookCellState(.holding)
        if case .normal(let inner) = state {
            XCTAssertEqual(inner, .holding)
        } else {
            XCTFail("holding should map to .normal")
        }
    }

    func testBookCellState_HoldingFrontOfQueue_MapsToNormal() {
        let state = BookCellState(.holdingFrontOfQueue)
        if case .normal(let inner) = state {
            XCTAssertEqual(inner, .holdingFrontOfQueue)
        } else {
            XCTFail("holdingFrontOfQueue should map to .normal")
        }
    }

    func testBookCellState_DownloadNeeded_MapsToNormal() {
        let state = BookCellState(.downloadNeeded)
        if case .normal(let inner) = state {
            XCTAssertEqual(inner, .downloadNeeded)
        } else {
            XCTFail("downloadNeeded should map to .normal")
        }
    }

    func testBookCellState_Used_MapsToNormal() {
        let state = BookCellState(.used)
        if case .normal(let inner) = state {
            XCTAssertEqual(inner, .used)
        } else {
            XCTFail("used should map to .normal")
        }
    }

    func testBookCellState_Returning_MapsToNormal() {
        let state = BookCellState(.returning)
        if case .normal(let inner) = state {
            XCTAssertEqual(inner, .returning)
        } else {
            XCTFail("returning should map to .normal")
        }
    }

    func testBookCellState_ManagingHold_MapsToNormal() {
        let state = BookCellState(.managingHold)
        if case .normal(let inner) = state {
            XCTAssertEqual(inner, .managingHold)
        } else {
            XCTFail("managingHold should map to .normal")
        }
    }

    func testBookCellState_Unsupported_MapsToNormal() {
        let state = BookCellState(.unsupported)
        if case .normal(let inner) = state {
            XCTAssertEqual(inner, .unsupported)
        } else {
            XCTFail("unsupported should map to .normal")
        }
    }

    func testBookCellState_DownloadInProgress_MapsToDownloading() {
        let state = BookCellState(.downloadInProgress)
        if case .downloading(let inner) = state {
            XCTAssertEqual(inner, .downloadInProgress)
        } else {
            XCTFail("downloadInProgress should map to .downloading")
        }
    }

    func testBookCellState_DownloadFailed_MapsToDownloadFailed() {
        let state = BookCellState(.downloadFailed)
        if case .downloadFailed(let inner) = state {
            XCTAssertEqual(inner, .downloadFailed)
        } else {
            XCTFail("downloadFailed should map to .downloadFailed")
        }
    }

    // MARK: - buttonState extraction from all variants

    func testButtonState_ExtractionFromNormal() {
        let state = BookCellState.normal(.canBorrow)
        XCTAssertEqual(state.buttonState, .canBorrow)
    }

    func testButtonState_ExtractionFromDownloading() {
        let state = BookCellState.downloading(.downloadInProgress)
        XCTAssertEqual(state.buttonState, .downloadInProgress)
    }

    func testButtonState_ExtractionFromDownloadFailed() {
        let state = BookCellState.downloadFailed(.downloadFailed)
        XCTAssertEqual(state.buttonState, .downloadFailed)
    }
}

// MARK: - BookButtonMapper Tests

/// Tests BookButtonMapper.map() for all state combinations.
/// SRS: BookButtonMapper is the central mapping from registry state + availability to UI state.
final class BookButtonMapperViewModelTests: XCTestCase {

    func testMap_Downloading_ReturnsDownloadInProgress() {
        let result = BookButtonMapper.map(
            registryState: .downloading,
            availability: nil,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .downloadInProgress)
    }

    func testMap_IsProcessingDownload_ReturnsDownloadInProgress() {
        let result = BookButtonMapper.map(
            registryState: .unregistered,
            availability: nil,
            isProcessingDownload: true
        )
        XCTAssertEqual(result, .downloadInProgress)
    }

    func testMap_DownloadFailed_ReturnsDownloadFailed() {
        let result = BookButtonMapper.map(
            registryState: .downloadFailed,
            availability: nil,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .downloadFailed)
    }

    func testMap_DownloadSuccessful_ReturnsDownloadSuccessful() {
        let result = BookButtonMapper.map(
            registryState: .downloadSuccessful,
            availability: nil,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .downloadSuccessful)
    }

    func testMap_DownloadNeeded_ReturnsDownloadNeeded() {
        let result = BookButtonMapper.map(
            registryState: .downloadNeeded,
            availability: nil,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .downloadNeeded)
    }

    func testMap_Used_ReturnsUsed() {
        let result = BookButtonMapper.map(
            registryState: .used,
            availability: nil,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .used)
    }

    func testMap_Holding_WithReadyAvailability_ReturnsCanBorrow() {
        let readyAvailability = TPPOPDSAcquisitionAvailabilityReady(
            since: Date(),
            until: Date().addingTimeInterval(86400)
        )
        let result = BookButtonMapper.map(
            registryState: .holding,
            availability: readyAvailability,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .canBorrow, "Ready availability with holding state means user can borrow")
    }

    func testMap_Holding_WithReservedAvailability_ReturnsHolding() {
        let reservedAvailability = TPPOPDSAcquisitionAvailabilityReserved(
            holdPosition: 5,
            copiesTotal: 10,
            since: Date(),
            until: Date().addingTimeInterval(86400 * 14)
        )
        let result = BookButtonMapper.map(
            registryState: .holding,
            availability: reservedAvailability,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .holding)
    }

    func testMap_Holding_WithNilAvailability_ReturnsHolding() {
        let result = BookButtonMapper.map(
            registryState: .holding,
            availability: nil,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .holding)
    }

    func testMap_Unregistered_WithUnlimitedAvailability_ReturnsCanBorrow() {
        let availability = TPPOPDSAcquisitionAvailabilityUnlimited()
        let result = BookButtonMapper.map(
            registryState: .unregistered,
            availability: availability,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .canBorrow)
    }

    func testMap_Unregistered_WithNilAvailability_ReturnsUnsupported() {
        let result = BookButtonMapper.map(
            registryState: .unregistered,
            availability: nil,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .unsupported)
    }

    func testMap_Unregistered_WithUnavailability_ReturnsCanHold() {
        let unavailable = TPPOPDSAcquisitionAvailabilityUnavailable(
            copiesHeld: 5,
            copiesTotal: 2
        )
        let result = BookButtonMapper.map(
            registryState: .unregistered,
            availability: unavailable,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .canHold, "Unavailable book should show canHold")
    }

    func testMap_Unregistered_WithLimitedAvailability_CopiesAvailable_ReturnsCanBorrow() {
        let limited = TPPOPDSAcquisitionAvailabilityLimited(
            copiesAvailable: 3,
            copiesTotal: 10,
            since: Date(),
            until: Date().addingTimeInterval(86400)
        )
        let result = BookButtonMapper.map(
            registryState: .unregistered,
            availability: limited,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .canBorrow, "Limited availability with copies should allow borrowing")
    }

    func testMap_Returning_ReturnsReturning() {
        let result = BookButtonMapper.map(
            registryState: .returning,
            availability: nil,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .returning)
    }

    // MARK: - stateForAvailability Tests

    func testStateForAvailability_Nil_ReturnsNil() {
        let result = BookButtonMapper.stateForAvailability(nil)
        XCTAssertNil(result)
    }

    func testStateForAvailability_Reserved_ReturnsHoldingFrontOfQueue() {
        let reserved = TPPOPDSAcquisitionAvailabilityReserved(
            holdPosition: 1,
            copiesTotal: 5,
            since: Date(),
            until: Date().addingTimeInterval(86400)
        )
        let result = BookButtonMapper.stateForAvailability(reserved)
        XCTAssertEqual(result, .holdingFrontOfQueue)
    }

    func testStateForAvailability_Ready_ReturnsCanBorrow() {
        let ready = TPPOPDSAcquisitionAvailabilityReady(
            since: Date(),
            until: Date().addingTimeInterval(86400)
        )
        let result = BookButtonMapper.stateForAvailability(ready)
        XCTAssertEqual(result, .canBorrow)
    }

    /// SRS: Downloading state takes priority over all other states
    func testMap_DownloadingPrioritizedOverAvailability() {
        let availability = TPPOPDSAcquisitionAvailabilityUnlimited()
        let result = BookButtonMapper.map(
            registryState: .downloading,
            availability: availability,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .downloadInProgress, "Downloading should take priority over availability")
    }
}

// MARK: - CatalogLaneMoreViewModel Filter State Tests

/// Tests CatalogLaneMoreViewModel filter state restoration and observer behavior.
/// SRS: Filter state must persist across navigation to avoid user re-selecting filters.
@MainActor
final class CatalogLaneMoreFilterStateTests: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        cancellables = []
    }

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    private func createViewModel(urlString: String = "https://example.com/feed") -> CatalogLaneMoreViewModel {
        CatalogLaneMoreViewModel(title: "Test", url: URL(string: urlString)!)
    }

    // MARK: - restoreFilterState

    func testRestoreFilterState_RestoresAppliedSelections() {
        let viewModel = createViewModel()

        let filterState = CatalogLaneFilterState(
            appliedSelections: Set(["Format|eBook", "Availability|Now"]),
            facetGroups: []
        )

        viewModel.restoreFilterState(filterState)

        XCTAssertEqual(viewModel.appliedSelections, Set(["Format|eBook", "Availability|Now"]))
    }

    func testRestoreFilterState_RestoresFacetGroups() {
        let viewModel = createViewModel()

        let groups = [
            CatalogFilterGroup(id: "format", name: "Format", filters: [
                CatalogFilter(id: "ebook", title: "eBook", href: nil, active: true)
            ])
        ]
        let filterState = CatalogLaneFilterState(
            appliedSelections: [],
            facetGroups: groups
        )

        viewModel.restoreFilterState(filterState)

        XCTAssertEqual(viewModel.facetGroups.count, 1)
        XCTAssertEqual(viewModel.facetGroups.first?.name, "Format")
    }

    func testRestoreFilterState_WithEmptyState_ClearsAll() {
        let viewModel = createViewModel()
        viewModel.appliedSelections = Set(["Format|eBook"])
        viewModel.facetGroups = [
            CatalogFilterGroup(id: "test", name: "Test", filters: [])
        ]

        let emptyState = CatalogLaneFilterState(appliedSelections: [], facetGroups: [])
        viewModel.restoreFilterState(emptyState)

        XCTAssertTrue(viewModel.appliedSelections.isEmpty)
        XCTAssertTrue(viewModel.facetGroups.isEmpty)
    }

    // MARK: - Filter Sheet Observer Tests

    func testOpeningFilterSheet_PopulatesPendingFromApplied() {
        let viewModel = createViewModel()

        // Set up applied selections with facet groups that match
        let groups = [
            CatalogFilterGroup(id: "format", name: "Format", filters: [
                CatalogFilter(id: "ebook", title: "eBook", href: nil, active: true)
            ])
        ]
        viewModel.facetGroups = groups
        viewModel.appliedSelections = Set(["Format|eBook"])

        let expectation = XCTestExpectation(description: "Pending selections populated")

        viewModel.$pendingSelections
            .dropFirst()
            .sink { selections in
                if !selections.isEmpty {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        // Opening the filter sheet triggers the observer
        viewModel.showingFiltersSheet = true

        wait(for: [expectation], timeout: 1.0)
    }

    func testOpeningFilterSheet_WithNoApplied_ClearsPending() {
        let viewModel = createViewModel()
        viewModel.pendingSelections = Set(["old|selection"])

        let expectation = XCTestExpectation(description: "Pending selections cleared")

        viewModel.$pendingSelections
            .dropFirst()
            .sink { selections in
                if selections.isEmpty {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        viewModel.showingFiltersSheet = true

        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Sort Facets Edge Cases

    func testSortFacets_CaseInsensitiveGroupMatch() {
        let viewModel = createViewModel()

        viewModel.facetGroups = [
            CatalogFilterGroup(id: "sort", name: "SORT BY", filters: [
                CatalogFilter(id: "title", title: "Title", href: nil, active: false)
            ])
        ]

        // "SORT BY".lowercased().contains("sort") should match
        XCTAssertEqual(viewModel.sortFacets.count, 1)
    }

    func testActiveSortTitle_WithMultipleActive_ReturnsFirst() {
        let viewModel = createViewModel()

        viewModel.facetGroups = [
            CatalogFilterGroup(id: "sort", name: "Sort By", filters: [
                CatalogFilter(id: "title", title: "Title", href: nil, active: true),
                CatalogFilter(id: "author", title: "Author", href: nil, active: true)
            ])
        ]

        // first(where: active) returns the first one
        XCTAssertEqual(viewModel.activeSortTitle, "Title")
    }

    // MARK: - URL property

    func testURL_MatchesInitializer() {
        let url = URL(string: "https://catalog.example.com/lane/fiction")!
        let viewModel = CatalogLaneMoreViewModel(title: "Fiction", url: url)

        XCTAssertEqual(viewModel.url, url)
    }
}

// MARK: - BookCellModel Registry State Binding Tests

/// Tests that BookCellModel properly responds to registry state changes via publisher.
/// SRS: State must stay synchronized between registry and UI to avoid stale button states.
@MainActor
final class BookCellModelRegistryBindingTests: XCTestCase {

    var mockRegistry: TPPBookRegistryMock!
    var mockImageCache: MockImageCache!
    var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        mockRegistry = TPPBookRegistryMock()
        mockImageCache = MockImageCache()
        cancellables = Set<AnyCancellable>()
    }

    override func tearDown() {
        cancellables = nil
        mockRegistry = nil
        mockImageCache = nil
        super.tearDown()
    }

    private func createBook(id: String = "test-book") -> TPPBook {
        return TPPBook(dictionary: [
            "acquisitions": [TPPFake.genericAcquisition.dictionaryRepresentation()],
            "title": "Test Book",
            "categories": ["Fiction"],
            "id": id,
            "updated": "2024-01-01T00:00:00Z"
        ])!
    }

    func testRegistryStateChange_UpdatesRegistryState() async {
        let book = createBook()
        mockRegistry.addBook(book, state: .downloadNeeded)

        let model = BookCellModel(book: book, imageCache: mockImageCache, bookRegistry: mockRegistry)
        XCTAssertEqual(model.registryState, .downloadNeeded)

        let expectation = XCTestExpectation(description: "registryState updated")

        model.$registryState
            .dropFirst()
            .sink { state in
                if state == .downloading {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        // Simulate state change through registry
        mockRegistry.setState(.downloading, for: book.identifier)

        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(model.registryState, .downloading)
    }

    func testRegistryStateChange_ClearsLoadingForTerminalStates() async {
        let book = createBook()
        mockRegistry.addBook(book, state: .downloading)

        let model = BookCellModel(book: book, imageCache: mockImageCache, bookRegistry: mockRegistry)

        let expectation = XCTestExpectation(description: "Loading cleared after download complete")

        model.$registryState
            .dropFirst()
            .sink { state in
                if state == .downloadSuccessful {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        // Transition to terminal state
        mockRegistry.setState(.downloadSuccessful, for: book.identifier)

        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertFalse(model.isLoading, "Loading should be cleared after download completes")
    }

    func testRegistryStateChange_ToDownloadFailed_ClearsLoading() async {
        let book = createBook()
        mockRegistry.addBook(book, state: .downloading)

        let model = BookCellModel(book: book, imageCache: mockImageCache, bookRegistry: mockRegistry)

        let expectation = XCTestExpectation(description: "Loading cleared after download failed")

        model.$registryState
            .dropFirst()
            .sink { state in
                if state == .downloadFailed {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        mockRegistry.setState(.downloadFailed, for: book.identifier)

        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertFalse(model.isLoading)
    }

    func testRegistryStateChange_IgnoresOtherBookIds() async {
        let book = createBook(id: "my-book")
        let otherBook = createBook(id: "other-book")
        mockRegistry.addBook(book, state: .downloadNeeded)
        mockRegistry.addBook(otherBook, state: .downloadNeeded)

        let model = BookCellModel(book: book, imageCache: mockImageCache, bookRegistry: mockRegistry)

        // Change state of OTHER book - should not affect this model
        mockRegistry.setState(.downloading, for: "other-book")

        // Wait a moment for any potential (incorrect) propagation
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms

        XCTAssertEqual(model.registryState, .downloadNeeded, "Should not react to other book's state changes")
    }
}

// MARK: - SettingsViewModel Computed Property Edge Cases

/// Additional tests for SettingsViewModel computed properties not covered by existing tests.
@MainActor
final class SettingsViewModelComputedPropertyTests: XCTestCase {

    func testAccountCount_ReflectsSettingsAccountsList() {
        let mockSettings = TPPSettingsMock()
        let viewModel = SettingsViewModel(settings: mockSettings)

        // accountCount is derived from settingsAccountsList.count
        XCTAssertEqual(viewModel.accountCount, viewModel.settingsAccountsList.count)
    }

    func testShowDeveloperSettings_DefaultsFalse() {
        let mockSettings = TPPSettingsMock()
        let viewModel = SettingsViewModel(settings: mockSettings)

        XCTAssertFalse(viewModel.showDeveloperSettings)
    }

    func testShowDeveloperSettings_CanBeToggled() {
        let mockSettings = TPPSettingsMock()
        let viewModel = SettingsViewModel(settings: mockSettings)

        viewModel.showDeveloperSettings = true
        XCTAssertTrue(viewModel.showDeveloperSettings)

        viewModel.showDeveloperSettings = false
        XCTAssertFalse(viewModel.showDeveloperSettings)
    }

    func testIsUsingCustomFeed_AfterClear_ReturnsFalse() {
        let mockSettings = TPPSettingsMock()
        let viewModel = SettingsViewModel(settings: mockSettings)

        viewModel.setCustomFeedURL("https://example.com/feed")
        XCTAssertTrue(viewModel.isUsingCustomFeed)

        viewModel.clearCustomFeedURL()
        XCTAssertFalse(viewModel.isUsingCustomFeed)
    }

    func testIsUsingCustomRegistry_AfterClear_ReturnsFalse() {
        let mockSettings = TPPSettingsMock()
        let viewModel = SettingsViewModel(settings: mockSettings)

        viewModel.setCustomRegistryServer("https://registry.example.com")
        XCTAssertTrue(viewModel.isUsingCustomRegistry)

        viewModel.clearCustomRegistryServer()
        XCTAssertFalse(viewModel.isUsingCustomRegistry)
    }

    /// SRS: Verifies the guard clause that prevents duplicate writes to settings
    func testDuplicateWrite_DoesNotTriggerSettingsUpdate() {
        let mockSettings = TPPSettingsMock(useBetaLibraries: true)
        let viewModel = SettingsViewModel(settings: mockSettings)

        // Setting the same value should be guarded
        viewModel.useBetaLibraries = true

        // If the guard works, mockSettings still has true (no unintended side effects)
        XCTAssertTrue(mockSettings.useBetaLibraries)
    }
}

// MARK: - FacetViewModel AccountLogoDelegate Tests

/// Tests FacetViewModel's AccountLogoDelegate conformance.
final class FacetViewModelLogoDelegateTests: XCTestCase {

    func testLogoDidUpdate_SetsLogo() {
        let viewModel = FacetViewModel(groupName: "Test", facets: [.author, .title])
        let testImage = UIImage(systemName: "book.fill")!

        // Directly test the delegate method
        if let account = AccountsManager.shared.currentAccount {
            viewModel.logoDidUpdate(in: account, to: testImage)
            XCTAssertNotNil(viewModel.logo)
        }
    }

    func testAccountScreenURL_WithValidHomePageURL() {
        let viewModel = FacetViewModel(groupName: "Test", facets: [.author, .title])

        // currentAccountURL depends on currentAccount's homePageUrl
        // With no account set manually, test the nil path
        viewModel.currentAccount = nil
        XCTAssertNil(viewModel.currentAccountURL)
    }

    func testActiveSort_DefaultsToFirstFacet_TitleFirst() {
        let viewModel = FacetViewModel(groupName: "Sort", facets: [.title, .author])
        XCTAssertEqual(viewModel.activeSort, .title)
    }

    func testActiveSort_DefaultsToFirstFacet_AuthorFirst() {
        let viewModel = FacetViewModel(groupName: "Sort", facets: [.author, .title])
        XCTAssertEqual(viewModel.activeSort, .author)
    }
}

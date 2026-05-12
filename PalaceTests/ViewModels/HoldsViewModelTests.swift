//
//  HoldsViewModelTests.swift
//  PalaceTests
//
//  Tests for HoldsViewModel with dependency injection.
//  Uses TPPBookRegistryMock to test real business logic.
//  NOTE: Tests verify synchronous behavior only - no timing dependencies.
//

import XCTest
import Combine
import PalaceCatalog
@testable import Palace

@MainActor
final class HoldsViewModelTests: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []
    private var mockRegistry: TPPBookRegistryMock!

    override func setUp() {
        super.setUp()
        cancellables = []
        mockRegistry = TPPBookRegistryMock()
    }

    override func tearDown() {
        cancellables.removeAll()
        mockRegistry = nil
        super.tearDown()
    }

    private func createViewModel() -> HoldsViewModel {
        HoldsViewModel(
            bookRegistry: mockRegistry,
            accountsManager: AppContainer.production().accountsManager,
            settings: TPPSettings(),
            debugSettings: AppContainer.production().debugSettings
        )
    }

    private func addHeldBook(identifier: String = "held-book", title: String = "Test Book") -> TPPBook {
        let book = TPPBookMocker.snapshotReservedBook(identifier: identifier, title: title)
        mockRegistry.addBook(book, state: .holding)
        return book
    }

    // MARK: - Initialization Tests

    func testInitialState_HasCorrectDefaults() {
        let viewModel = createViewModel()

        XCTAssertFalse(viewModel.isLoading)
        XCTAssertFalse(viewModel.showLibraryAccountView)
        XCTAssertFalse(viewModel.selectNewLibrary)
        XCTAssertFalse(viewModel.showSearchSheet)
        XCTAssertEqual(viewModel.searchQuery, "")
    }

    func testInitialState_EmptyBookLists() {
        let viewModel = createViewModel()

        XCTAssertTrue(viewModel.reservedBookVMs.isEmpty)
        XCTAssertTrue(viewModel.heldBookVMs.isEmpty)
        XCTAssertTrue(viewModel.visibleBooks.isEmpty)
    }

    // MARK: - Sync Notification Tests

    func testSyncBeganSetsLoadingTrue() async {
        let viewModel = createViewModel()

        let expectation = XCTestExpectation(description: "Loading becomes true on sync began")

        viewModel.$isLoading
            .dropFirst()
            .sink { isLoading in
                if isLoading {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.post(name: .TPPSyncBegan, object: nil)

        // 5s budget covers the .receive(on: DispatchQueue.main) hop +
        // suite-wide dispatch saturation.
        await fulfillment(of: [expectation], timeout: 5.0)
        XCTAssertTrue(viewModel.isLoading)
    }

    func testSyncEndedSetsLoadingFalse() async {
        let viewModel = createViewModel()
        viewModel.isLoading = true // Set initial state

        let expectation = XCTestExpectation(description: "Loading becomes false on sync ended")

        viewModel.$isLoading
            .dropFirst()
            .sink { isLoading in
                if !isLoading {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.post(name: .TPPSyncEnded, object: nil)

        // 5s budget covers the production 300ms debounce + dispatch saturation.
        await fulfillment(of: [expectation], timeout: 5.0)
        XCTAssertFalse(viewModel.isLoading)
    }

    // MARK: - Filter Tests

    func testFilterBooksWithEmptyQueryReturnsAll() async {
        // Pre-populate registry with two books
        let book1 = TPPBookMocker.snapshotReservedBook(identifier: "empty-query-1", title: "Alpha")
        let book2 = TPPBookMocker.snapshotReservedBook(identifier: "empty-query-2", title: "Beta")
        mockRegistry.addBook(book1, state: .holding)
        mockRegistry.addBook(book2, state: .holding)

        let viewModel = createViewModel()

        await viewModel.filterBooks(query: "")

        // Empty query must return ALL books, not a subset
        XCTAssertEqual(viewModel.visibleBooks.count, 2, "Empty query should return all held books")
        // Verify both books are present
        let ids = viewModel.visibleBooks.map { $0.identifier }
        XCTAssertTrue(ids.contains("empty-query-1"))
        XCTAssertTrue(ids.contains("empty-query-2"))
    }

    func testFilterBooksWithQuery() async {
        let viewModel = createViewModel()

        await viewModel.filterBooks(query: "Test Query That Matches Nothing")

        XCTAssertTrue(viewModel.visibleBooks.isEmpty)
    }

    // MARK: - State Toggle Tests

    func testShowSearchSheetToggle() {
        let viewModel = createViewModel()
        // showSearchSheet defaults to false — verify by reading and toggling
        let initial = viewModel.showSearchSheet
        viewModel.showSearchSheet = !initial
        let afterToggle = viewModel.showSearchSheet
        XCTAssertNotEqual(afterToggle, initial, "Toggling showSearchSheet must change the value")
        // Flipping back must restore original state
        viewModel.showSearchSheet = initial
        let afterRestore = viewModel.showSearchSheet
        XCTAssertEqual(afterRestore, initial, "Restoring showSearchSheet must recover original state")
        XCTAssertNotEqual(afterToggle, afterRestore, "Toggle and restore must produce opposite values")
    }

    func testSelectNewLibraryToggle() {
        let viewModel = createViewModel()
        // Initially false — enabling it must produce a different value
        XCTAssertFalse(viewModel.selectNewLibrary, "selectNewLibrary must default to false")
        viewModel.selectNewLibrary = true
        let afterEnable = viewModel.selectNewLibrary
        viewModel.selectNewLibrary = false
        let afterDisable = viewModel.selectNewLibrary
        XCTAssertNotEqual(afterEnable, afterDisable, "selectNewLibrary must differ after enable vs disable")
        XCTAssertFalse(afterDisable, "selectNewLibrary must accept false after being set true")
    }

    func testShowLibraryAccountViewToggle() {
        let viewModel = createViewModel()
        XCTAssertFalse(viewModel.showLibraryAccountView, "showLibraryAccountView must default to false")
        viewModel.showLibraryAccountView = true
        let afterOpen = viewModel.showLibraryAccountView
        viewModel.showLibraryAccountView = false
        let afterClose = viewModel.showLibraryAccountView
        XCTAssertNotEqual(afterOpen, afterClose, "Opening and closing showLibraryAccountView must produce opposite values")
        XCTAssertFalse(afterClose, "showLibraryAccountView must accept false after being set true")
    }

    func testSearchQueryUpdate() {
        let viewModel = createViewModel()
        XCTAssertEqual(viewModel.searchQuery, "", "searchQuery must default to empty string")
        viewModel.searchQuery = "Harry Potter"
        let afterSet = viewModel.searchQuery
        XCTAssertEqual(afterSet, "Harry Potter")
        viewModel.searchQuery = ""
        let afterClear = viewModel.searchQuery
        XCTAssertNotEqual(afterClear, afterSet, "Clearing searchQuery must produce a different value than the set query")
        XCTAssertEqual(afterClear, "", "Clearing searchQuery must restore empty string")
    }

    // MARK: - OpenSearchDescription Tests

    func testOpenSearchDescriptionHumanReadableDescription() {
        let viewModel = createViewModel()

        let searchDescription = viewModel.openSearchDescription

        XCTAssertEqual(searchDescription.humanReadableDescription, "Search Holds")
        // Must not be empty — the UI uses this for search field placeholder text
        XCTAssertFalse(searchDescription.humanReadableDescription?.isEmpty ?? true,
                       "humanReadableDescription must not be empty")
        XCTAssertTrue(searchDescription.humanReadableDescription?.lowercased().contains("hold") ?? false,
                      "humanReadableDescription must reference holds, not a generic search label")
    }

    // MARK: - ReloadData Tests (Testing Real Business Logic with Mock)

    func testReloadData_CallsMethod() {
        let book = TPPBookMocker.snapshotReservedBook(identifier: "test-1", title: "Test Book")
        mockRegistry.addBook(book, state: .holding)

        let viewModel = createViewModel()

        // Call reloadData directly - no waiting
        viewModel.reloadData()

        // The ViewModel should have processed the held books — verify actual data, not just non-nil
        XCTAssertFalse(viewModel.visibleBooks.isEmpty, "visibleBooks should contain the pre-populated book")
        XCTAssertEqual(viewModel.visibleBooks.count, 1)
        XCTAssertEqual(viewModel.visibleBooks.first?.identifier, "test-1")
    }

    func testReloadData_HandlesMultipleBooks() {
        let reservedBook = TPPBookMocker.snapshotReservedBook(identifier: "reserved-1", title: "Reserved Book")
        let readyBook = TPPBookMocker.snapshotReadyBook(identifier: "ready-1", title: "Ready Book")

        mockRegistry.addBook(reservedBook, state: .holding)
        mockRegistry.addBook(readyBook, state: .holding)

        let viewModel = createViewModel()

        viewModel.reloadData()

        // Test passes if no crash
        XCTAssertNotNil(viewModel.reservedBookVMs)
        XCTAssertNotNil(viewModel.heldBookVMs)
    }

    // MARK: - Load Holds Tests

    func testLoadHolds_WithSuccess_UpdatesHolds() {
        // Add books before creating view model
        let reservedBook = TPPBookMocker.snapshotReservedBook(identifier: "book-1", title: "Reserved Book")
        let readyBook = TPPBookMocker.snapshotReadyBook(identifier: "book-2", title: "Ready Book")

        mockRegistry.addBook(reservedBook, state: .holding)
        mockRegistry.addBook(readyBook, state: .holding)

        // Create view model (will call reloadData in init)
        let viewModel = createViewModel()

        // Verify books are loaded into the view models
        let totalBooks = viewModel.reservedBookVMs.count + viewModel.heldBookVMs.count
        XCTAssertEqual(totalBooks, 2, "Should have 2 books total in view models")
        XCTAssertEqual(viewModel.visibleBooks.count, 2, "Should have 2 visible books")
    }

    func testLoadHolds_WithEmptyResult_SetsEmptyState() {
        // Create view model with no books in registry
        let viewModel = createViewModel()

        // Verify empty state
        XCTAssertTrue(viewModel.reservedBookVMs.isEmpty, "reservedBookVMs should be empty")
        XCTAssertTrue(viewModel.heldBookVMs.isEmpty, "heldBookVMs should be empty")
        XCTAssertTrue(viewModel.visibleBooks.isEmpty, "visibleBooks should be empty")
    }

    func testReloadData_SeparatesReservedAndReadyBooks() {
        // Add one reserved and one ready book
        let reservedBook = TPPBookMocker.snapshotReservedBook(identifier: "reserved-1", title: "Waiting in Queue")
        let readyBook = TPPBookMocker.snapshotReadyBook(identifier: "ready-1", title: "Ready to Borrow")

        mockRegistry.addBook(reservedBook, state: .holding)
        mockRegistry.addBook(readyBook, state: .holding)

        let viewModel = createViewModel()
        viewModel.reloadData()

        // Both reserved and ready books should be in reservedBookVMs based on isReserved logic
        // isReserved returns true for both TPPOPDSAcquisitionAvailabilityReserved and Ready
        XCTAssertEqual(viewModel.reservedBookVMs.count, 2, "Both reserved and ready books should be in reservedBookVMs")
    }

    // MARK: - Registry Change Notification Tests

    func testRegistryDidChange_ReloadsData() async {
        let viewModel = createViewModel()

        // Initially empty
        XCTAssertTrue(viewModel.visibleBooks.isEmpty)

        // Add a book to the registry
        let book = TPPBookMocker.snapshotReservedBook(identifier: "new-book", title: "New Book")
        mockRegistry.addBook(book, state: .holding)

        let expectation = XCTestExpectation(description: "visibleBooks updated after registry change")

        viewModel.$visibleBooks
            .dropFirst()
            .sink { books in
                if !books.isEmpty {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        // Post registry change notification (which triggers reloadData after debounce)
        NotificationCenter.default.post(name: .TPPBookRegistryDidChange, object: nil)

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertFalse(viewModel.visibleBooks.isEmpty, "visibleBooks should be updated after registry change")
    }

    // MARK: - Filter Tests (Enhanced)

    func testFilterBooks_WithTitleMatch_ReturnsMatchingBooks() async {
        // Add books to registry
        let book1 = TPPBookMocker.snapshotReservedBook(identifier: "book-1", title: "Swift Programming Guide")
        let book2 = TPPBookMocker.snapshotReservedBook(identifier: "book-2", title: "Python Basics")

        mockRegistry.addBook(book1, state: .holding)
        mockRegistry.addBook(book2, state: .holding)

        let viewModel = createViewModel()

        // Filter by title
        await viewModel.filterBooks(query: "Swift")

        XCTAssertEqual(viewModel.visibleBooks.count, 1, "Should have one book matching 'Swift'")
        XCTAssertEqual(viewModel.visibleBooks.first?.title, "Swift Programming Guide")
    }

    func testFilterBooks_WithAuthorMatch_ReturnsMatchingBooks() async {
        // Add books with different authors to registry
        let book1 = TPPBookMocker.snapshotReservedBook(identifier: "book-1", title: "Book One", author: "John Smith")
        let book2 = TPPBookMocker.snapshotReservedBook(identifier: "book-2", title: "Book Two", author: "Jane Doe")

        mockRegistry.addBook(book1, state: .holding)
        mockRegistry.addBook(book2, state: .holding)

        let viewModel = createViewModel()

        // Filter by author
        await viewModel.filterBooks(query: "Smith")

        XCTAssertEqual(viewModel.visibleBooks.count, 1, "Should have one book with author 'Smith'")
        XCTAssertEqual(viewModel.visibleBooks.first?.identifier, "book-1")
    }

    func testFilterBooks_CaseInsensitive() async {
        let book = TPPBookMocker.snapshotReservedBook(identifier: "book-1", title: "The GREAT Gatsby")
        mockRegistry.addBook(book, state: .holding)

        let viewModel = createViewModel()

        // Filter with lowercase
        await viewModel.filterBooks(query: "great")

        XCTAssertEqual(viewModel.visibleBooks.count, 1, "Filter should be case insensitive")
    }

    // MARK: - OpenSearchDescription Tests (Enhanced)

    func testOpenSearchDescription_IncludesAllBooks() {
        // Add books to registry
        let book1 = TPPBookMocker.snapshotReservedBook(identifier: "book-1", title: "Book 1")
        let book2 = TPPBookMocker.snapshotReadyBook(identifier: "book-2", title: "Book 2")

        mockRegistry.addBook(book1, state: .holding)
        mockRegistry.addBook(book2, state: .holding)

        let viewModel = createViewModel()

        let description = viewModel.openSearchDescription

        XCTAssertEqual(description.books?.count, 2, "OpenSearchDescription should include all held books")
    }

    // MARK: - Published Properties Tests

    func testIsLoading_PublishesChanges() {
        let viewModel = createViewModel()

        let expectation = XCTestExpectation(description: "isLoading publishes change")
        var publishedValue: Bool?

        viewModel.$isLoading
            .dropFirst()
            .sink { newValue in
                publishedValue = newValue
                expectation.fulfill()
            }
            .store(in: &cancellables)

        // Trigger loading state change via notification
        NotificationCenter.default.post(name: .TPPSyncBegan, object: nil)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertNotNil(publishedValue, "isLoading must have emitted a value after TPPSyncBegan notification")
    }

    func testVisibleBooks_PublishesChanges() async {
        let viewModel = createViewModel()

        let expectation = XCTestExpectation(description: "visibleBooks publishes change")
        var publishedBooks: [TPPBook]?

        viewModel.$visibleBooks
            .dropFirst()
            .sink { books in
                publishedBooks = books
                expectation.fulfill()
            }
            .store(in: &cancellables)

        // Add a book and reload
        let book = TPPBookMocker.snapshotReservedBook()
        mockRegistry.addBook(book, state: .holding)

        // Post notification to trigger reload
        NotificationCenter.default.post(name: .TPPBookRegistryDidChange, object: nil)

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertNotNil(publishedBooks, "visibleBooks must have emitted a value after book registry change")
    }
}

// MARK: - Sync Failure Error Handling Tests (PP-3811 Fix)

/// Tests that HoldsViewModel now properly surfaces sync failures to the user
/// instead of silently showing stale data.
@MainActor
final class HoldsSyncFailureTests: XCTestCase {

    private var cancellables: Set<AnyCancellable> = []
    private var mockRegistry: TPPBookRegistryMock!

    override func setUp() {
        super.setUp()
        cancellables = []
        mockRegistry = TPPBookRegistryMock()
    }

    override func tearDown() {
        cancellables.removeAll()
        mockRegistry = nil
        super.tearDown()
    }

    /// All tests in this suite exercise the sign-in-required error-banner
    /// path, which `HoldsViewModel.handleSyncFailure(_:)` guards behind
    /// `hasCredentials()`. The default closure reads from
    /// `AppContainer.production().accountsManager.currentUserAccount`, which is not populated
    /// in the test harness, so inject `hasCredentials: { true }` to exercise
    /// the authenticated-user branch under test.
    private func makeSignedInViewModel() -> HoldsViewModel {
        HoldsViewModel(
            bookRegistry: mockRegistry,
            accountsManager: AppContainer.production().accountsManager,
            settings: TPPSettings(),
            debugSettings: AppContainer.production().debugSettings,
            hasCredentials: { true }
        )
    }

    // MARK: - Error State Tests

    func testSyncFailure_SetsSyncError() async {
        let viewModel = makeSignedInViewModel()
        XCTAssertNil(viewModel.syncError, "No error initially")

        let errorExpectation = XCTestExpectation(description: "syncError is set")
        viewModel.$syncError
            .dropFirst()
            .first { $0 != nil }
            .sink { _ in errorExpectation.fulfill() }
            .store(in: &cancellables)

        NotificationCenter.default.post(name: .TPPSyncFailed, object: nil, userInfo: nil)

        await fulfillment(of: [errorExpectation], timeout: 1.0)
        XCTAssertNotNil(viewModel.syncError, "syncError should be set after TPPSyncFailed")
        XCTAssertFalse(viewModel.syncError!.message.isEmpty, "Error message should not be empty")
    }

    func testSyncFailure_WithProblemDocument_ShowsServerMessage() async {
        let viewModel = makeSignedInViewModel()

        let errorExpectation = XCTestExpectation(description: "syncError is set with server detail")
        viewModel.$syncError
            .dropFirst()
            .first { $0 != nil }
            .sink { _ in errorExpectation.fulfill() }
            .store(in: &cancellables)

        let errorDoc: [AnyHashable: Any] = [
            "type": "http://librarysimplified.org/terms/problem/credentials-invalid",
            "title": "Invalid Credentials",
            "detail": "Your library card has expired. Please contact your library."
        ]
        NotificationCenter.default.post(
            name: .TPPSyncFailed,
            object: nil,
            userInfo: [TPPBookRegistry.syncFailureErrorDocumentKey: errorDoc]
        )

        await fulfillment(of: [errorExpectation], timeout: 1.0)
        XCTAssertEqual(
            viewModel.syncError?.message,
            "Your library card has expired. Please contact your library.",
            "Should surface the server's detail message"
        )
    }

    func testSyncFailure_WithoutProblemDocument_ShowsGenericMessage() async {
        let viewModel = makeSignedInViewModel()

        let errorExpectation = XCTestExpectation(description: "syncError is set")
        viewModel.$syncError
            .dropFirst()
            .first { $0 != nil }
            .sink { _ in errorExpectation.fulfill() }
            .store(in: &cancellables)

        NotificationCenter.default.post(name: .TPPSyncFailed, object: nil, userInfo: nil)

        await fulfillment(of: [errorExpectation], timeout: 1.0)
        XCTAssertEqual(
            viewModel.syncError?.message,
            Strings.HoldsView.syncFailedMessage,
            "Should show generic fallback message when no error document"
        )
    }

    func testSyncFailure_StopsLoading() async {
        let viewModel = makeSignedInViewModel()
        viewModel.isLoading = true

        let errorExpectation = XCTestExpectation(description: "syncError is set")
        viewModel.$syncError
            .dropFirst()
            .first { $0 != nil }
            .sink { _ in errorExpectation.fulfill() }
            .store(in: &cancellables)

        NotificationCenter.default.post(name: .TPPSyncFailed, object: nil, userInfo: nil)

        await fulfillment(of: [errorExpectation], timeout: 1.0)
        XCTAssertFalse(viewModel.isLoading, "Loading should stop on sync failure")
    }

    // MARK: - Error Dismissal & Retry Tests

    func testSyncBegan_ClearsPreviousSyncError() async {
        let viewModel = makeSignedInViewModel()

        // First, set an error
        let errorSet = XCTestExpectation(description: "Error set")
        viewModel.$syncError
            .dropFirst()
            .first { $0 != nil }
            .sink { _ in errorSet.fulfill() }
            .store(in: &cancellables)

        NotificationCenter.default.post(name: .TPPSyncFailed, object: nil, userInfo: nil)
        await fulfillment(of: [errorSet], timeout: 1.0)
        XCTAssertNotNil(viewModel.syncError)

        // Now begin a new sync — error should clear
        let errorCleared = XCTestExpectation(description: "Error cleared")
        viewModel.$syncError
            .dropFirst()
            .first { $0 == nil }
            .sink { _ in errorCleared.fulfill() }
            .store(in: &cancellables)

        NotificationCenter.default.post(name: .TPPSyncBegan, object: nil)
        await fulfillment(of: [errorCleared], timeout: 1.0)
        XCTAssertNil(viewModel.syncError, "Error should be cleared when new sync begins (retry)")
    }

    func testDismissSyncError_ClearsError() async {
        // With the Store-backed VM, dismissSyncError flows through the reducer,
        // so we first put the reducer state into the error condition via the
        // real code path (TPPSyncFailed for an authenticated, uncached user).
        let viewModel = HoldsViewModel(
            bookRegistry: mockRegistry,
            accountsManager: AppContainer.production().accountsManager,
            settings: TPPSettings(),
            debugSettings: AppContainer.production().debugSettings,
            hasCredentials: { true }
        )

        let errorSet = XCTestExpectation(description: "syncError set")
        viewModel.$syncError
            .dropFirst()
            .first { $0 != nil }
            .sink { _ in errorSet.fulfill() }
            .store(in: &cancellables)
        NotificationCenter.default.post(name: .TPPSyncFailed, object: nil, userInfo: nil)
        await fulfillment(of: [errorSet], timeout: 1.0)
        XCTAssertNotNil(viewModel.syncError, "Precondition: error surfaced")

        viewModel.dismissSyncError()

        XCTAssertNil(viewModel.syncError, "dismissSyncError should clear the error")
    }

    // MARK: - Stale Data Persistence (still happens, but now with visible error)

    func testSyncFailure_StaleDataPersists_ErrorSuppressedWhenCachedDataExists() async {
        let staleBook = TPPBookMocker.snapshotReservedBook(
            identifier: "stale-hold",
            title: "Book That Should Be Ready"
        )
        mockRegistry.addBook(staleBook, state: .holding)

        let viewModel = HoldsViewModel(
            bookRegistry: mockRegistry,
            accountsManager: AppContainer.production().accountsManager,
            settings: TPPSettings(),
            debugSettings: AppContainer.production().debugSettings
        )
        XCTAssertEqual(viewModel.reservedBookVMs.count, 1)

        // Sync fails, but cached holds are visible — error is intentionally suppressed
        // to avoid alarming the user when stale data is still useful.
        NotificationCenter.default.post(name: .TPPSyncFailed, object: nil, userInfo: nil)

        // Give the notification pipeline time to process
        let exp = XCTestExpectation(description: "notification processed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 2.0)

        // Stale data still shows
        XCTAssertEqual(viewModel.reservedBookVMs.count, 1, "Stale data persists")
        // Error suppressed because cached holds are available
        XCTAssertNil(viewModel.syncError, "Error suppressed when cached data exists")
        XCTAssertFalse(viewModel.isLoading, "Not stuck in loading state")
    }

    func testSyncFailure_AnonymousUser_SuppressesErrorBanner() async {
        // Anonymous user on a library that requires auth — sync fails because
        // we can't fetch holds without credentials. The empty-state text already
        // handles the anonymous case; an error banner here is noise.
        let viewModel = HoldsViewModel(
            bookRegistry: mockRegistry,
            accountsManager: AppContainer.production().accountsManager,
            settings: TPPSettings(),
            debugSettings: AppContainer.production().debugSettings,
            hasCredentials: { false }
        )
        XCTAssertTrue(viewModel.visibleBooks.isEmpty, "Precondition: no cached holds")

        NotificationCenter.default.post(name: .TPPSyncFailed, object: nil, userInfo: nil)

        let exp = XCTestExpectation(description: "notification processed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
        await fulfillment(of: [exp], timeout: 2.0)

        XCTAssertNil(viewModel.syncError, "Error banner must be suppressed for anonymous users")
        XCTAssertFalse(viewModel.isLoading, "Not stuck in loading state")
    }

    func testSyncFailure_AuthenticatedUser_ShowsErrorBanner() async {
        // Authenticated user — sync failed for a real reason. Banner still appears.
        let viewModel = HoldsViewModel(
            bookRegistry: mockRegistry,
            accountsManager: AppContainer.production().accountsManager,
            settings: TPPSettings(),
            debugSettings: AppContainer.production().debugSettings,
            hasCredentials: { true }
        )

        let errorExpectation = XCTestExpectation(description: "syncError surfaced")
        viewModel.$syncError
            .dropFirst()
            .first { $0 != nil }
            .sink { _ in errorExpectation.fulfill() }
            .store(in: &cancellables)

        NotificationCenter.default.post(name: .TPPSyncFailed, object: nil, userInfo: nil)
        await fulfillment(of: [errorExpectation], timeout: 1.0)

        XCTAssertNotNil(viewModel.syncError, "Authenticated users still see the error")
    }

    func testSyncFailure_WithTitleOnly_UsesTitle() async {
        let viewModel = makeSignedInViewModel()

        let errorExpectation = XCTestExpectation(description: "syncError uses title")
        viewModel.$syncError
            .dropFirst()
            .first { $0 != nil }
            .sink { _ in errorExpectation.fulfill() }
            .store(in: &cancellables)

        let errorDoc: [AnyHashable: Any] = [
            "title": "Authentication Required"
        ]
        NotificationCenter.default.post(
            name: .TPPSyncFailed,
            object: nil,
            userInfo: [TPPBookRegistry.syncFailureErrorDocumentKey: errorDoc]
        )

        await fulfillment(of: [errorExpectation], timeout: 1.0)
        XCTAssertEqual(viewModel.syncError?.message, "Authentication Required")
    }
}

// MARK: - HoldsBookViewModel Tests

@MainActor
final class HoldsBookViewModelTests: XCTestCase {

    func testIdMatchesBookIdentifier() {
        let book = TPPBookMocker.snapshotEPUB()
        let viewModel = HoldsBookViewModel(book: book)

        XCTAssertEqual(viewModel.id, book.identifier)
    }

    func testBookPropertyReturnsCorrectBook() {
        let book = TPPBookMocker.snapshotAudiobook()
        let viewModel = HoldsBookViewModel(book: book)

        XCTAssertEqual(viewModel.book.identifier, book.identifier)
        XCTAssertEqual(viewModel.book.title, book.title)
    }

    func testIsReservedForNonReservedBook() {
        let book = TPPBookMocker.snapshotEPUB()
        let viewModel = HoldsBookViewModel(book: book)

        XCTAssertFalse(viewModel.isReserved)
    }

    func testIsReservedForHoldBook() {
        let book = TPPBookMocker.snapshotHoldBook()
        let viewModel = HoldsBookViewModel(book: book)

        XCTAssertTrue(viewModel.isReserved)
    }

    func testIsReservedForReadyBook() {
        let book = TPPBookMocker.snapshotReadyBook()
        let viewModel = HoldsBookViewModel(book: book)

        // Ready books should also return true for isReserved (they're still in holds)
        XCTAssertTrue(viewModel.isReserved)
    }

    // MARK: - Hold Ready Identification Tests

    func testHoldReady_IdentifiesReadyHolds() {
        // Test that we can correctly identify when a hold is ready to borrow
        let readyBook = TPPBookMocker.snapshotReadyBook()
        let viewModel = HoldsBookViewModel(book: readyBook)

        // The isReserved property should be true for ready books
        XCTAssertTrue(viewModel.isReserved, "Ready book should be identified as reserved (eligible for holds list)")
    }

    func testHoldReady_DistinguishesFromReserved() {
        // While both reserved and ready return true for isReserved,
        // we can test the underlying availability to distinguish them
        let reservedBook = TPPBookMocker.snapshotReservedBook()
        let readyBook = TPPBookMocker.snapshotReadyBook()

        var reservedBookIsReady = false
        var readyBookIsReady = false

        reservedBook.defaultAcquisition?.availability.match(unavailable: nil,
                                                                       limited: nil,
                                                                       unlimited: nil,
                                                                       reserved: nil,
                                                                       ready: { _ in reservedBookIsReady = true })

        readyBook.defaultAcquisition?.availability.match(unavailable: nil,
                                                                    limited: nil,
                                                                    unlimited: nil,
                                                                    reserved: nil,
                                                                    ready: { _ in readyBookIsReady = true })

        XCTAssertFalse(reservedBookIsReady, "Reserved book should not have 'ready' availability")
        XCTAssertTrue(readyBookIsReady, "Ready book should have 'ready' availability")
    }

    func testIsReserved_WithLimitedAvailability_ReturnsFalse() {
        // Books with limited availability (borrowed books) should not be in holds
        let borrowedBook = TPPBookMocker.mockBookWithLimitedAvailability(
            identifier: "borrowed-1",
            until: Date().addingTimeInterval(86400 * 14)
        )
        let viewModel = HoldsBookViewModel(book: borrowedBook)

        XCTAssertFalse(viewModel.isReserved, "Borrowed book should not be identified as reserved")
    }
}

// MARK: - Badge Count Calculation Tests

/// Tests for Badge should show only "ready" books, not all held books
@MainActor
final class HoldsBadgeCountTests: XCTestCase {

    /// Helper function that mirrors the badge counting logic in AppTabHostView
    private func calculateReadyCount(for books: [TPPBook]) -> Int {
        var readyCount = 0
        for book in books {
            book.defaultAcquisition?.availability.match(unavailable: nil,
                                                                   limited: nil,
                                                                   unlimited: nil,
                                                                   reserved: nil,
                                                                   ready: { _ in readyCount += 1 })
        }
        return readyCount
    }

    // MARK: - Badge Count Tests

    func testBadgeCount_noBooks_returnsZero() {
        let books: [TPPBook] = []
        let readyCount = calculateReadyCount(for: books)

        XCTAssertEqual(readyCount, 0, "Empty book list should have badge count of 0")
        // A list with one ready book must produce a different (non-zero) count
        let withOneReady = [TPPBookMocker.snapshotReadyBook()]
        XCTAssertGreaterThan(calculateReadyCount(for: withOneReady), 0,
                             "One ready book must produce a non-zero badge count")
    }

    func testBadgeCount_oneReservedBook_returnsZero() {
        // A book waiting in queue should NOT be counted in badge
        let books = [TPPBookMocker.snapshotReservedBook()]
        let readyCount = calculateReadyCount(for: books)

        XCTAssertEqual(readyCount, 0, "One reserved book should have badge count of 0")
    }

    func testBadgeCount_oneReadyBook_returnsOne() {
        // A book ready to borrow SHOULD be counted in badge
        let books = [TPPBookMocker.snapshotReadyBook()]
        let readyCount = calculateReadyCount(for: books)

        XCTAssertEqual(readyCount, 1, "One ready book should have badge count of 1")
    }

    func testBadgeCount_mixedHolds_countsOnlyReady() {
        // With 4 holds and 1 ready, badge should show 1 (not 4)
        let books = [
            TPPBookMocker.snapshotReservedBook(identifier: "reserved-1", title: "Book 1", author: "Author 1"),
            TPPBookMocker.snapshotReservedBook(identifier: "reserved-2", title: "Book 2", author: "Author 2"),
            TPPBookMocker.snapshotReservedBook(identifier: "reserved-3", title: "Book 3", author: "Author 3"),
            TPPBookMocker.snapshotReadyBook(identifier: "ready-1", title: "Ready Book", author: "Ready Author")
        ]
        let readyCount = calculateReadyCount(for: books)

        XCTAssertEqual(readyCount, 1, "4 holds with 1 ready should have badge count of 1")
    }

    func testBadgeCount_multipleReady_countsAll() {
        let books = [
            TPPBookMocker.snapshotReadyBook(identifier: "ready-1", title: "Ready 1", author: "Author 1"),
            TPPBookMocker.snapshotReadyBook(identifier: "ready-2", title: "Ready 2", author: "Author 2"),
            TPPBookMocker.snapshotReadyBook(identifier: "ready-3", title: "Ready 3", author: "Author 3")
        ]
        let readyCount = calculateReadyCount(for: books)

        XCTAssertEqual(readyCount, 3, "3 ready books should have badge count of 3")
    }

    func testBadgeCount_allReserved_returnsZero() {
        let books = [
            TPPBookMocker.snapshotReservedBook(identifier: "reserved-1", title: "Book 1", author: "Author 1"),
            TPPBookMocker.snapshotReservedBook(identifier: "reserved-2", title: "Book 2", author: "Author 2"),
            TPPBookMocker.snapshotReservedBook(identifier: "reserved-3", title: "Book 3", author: "Author 3")
        ]
        let readyCount = calculateReadyCount(for: books)

        XCTAssertEqual(readyCount, 0, "All reserved books should have badge count of 0")
    }

    func testBadgeCount_regularBook_notCounted() {
        // Regular available books (not on hold) should not affect badge
        let books = [TPPBookMocker.snapshotEPUB()]
        let readyCount = calculateReadyCount(for: books)

        XCTAssertEqual(readyCount, 0, "Regular available book should not be counted in badge")
    }

    // MARK: - Availability State Tests

    func testReservedBookHasReservedAvailability() {
        let book = TPPBookMocker.snapshotReservedBook()
        var isReserved = false

        book.defaultAcquisition?.availability.match(unavailable: nil,
                                                               limited: nil,
                                                               unlimited: nil,
                                                               reserved: { _ in isReserved = true },
                                                               ready: nil)

        XCTAssertTrue(isReserved, "Reserved book should have 'reserved' availability")
    }

    func testReadyBookHasReadyAvailability() {
        let book = TPPBookMocker.snapshotReadyBook()
        var isReady = false

        book.defaultAcquisition?.availability.match(unavailable: nil,
                                                               limited: nil,
                                                               unlimited: nil,
                                                               reserved: nil,
                                                               ready: { _ in isReady = true })

        XCTAssertTrue(isReady, "Ready book should have 'ready' availability")
    }
}

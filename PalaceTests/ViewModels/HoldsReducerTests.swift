import XCTest
@testable import Palace

/// Behavior tests for `HoldsReducer` — the pure-function core of
/// HoldsViewModel's state machine. These tests exercise the reducer
/// directly, without a Store, Notifications, or a real `TPPBookRegistry`.
/// That's the whole point of the Store pattern: the business logic lives
/// in a testable pure function.
@MainActor
final class HoldsReducerTests: XCTestCase {

    // MARK: - Fixtures

    private func makeEnv(
        filter: @escaping (String, [TPPBook]) async -> [TPPBook] = { _, books in books }
    ) -> HoldsEnvironment {
        HoldsEnvironment(filterBooks: filter)
    }

    // MARK: - Sync lifecycle

    func testSyncBegan_setsLoadingTrueAndClearsPreviousError() {
        var state = HoldsState(
            reservedBooks: [], heldBooks: [], visibleBooks: [],
            isLoading: false, syncErrorMessage: "Stale error", searchQuery: ""
        )
        _ = HoldsReducer.reduce(&state, .syncBegan)
        XCTAssertTrue(state.isLoading, "syncBegan must raise isLoading")
        XCTAssertNil(state.syncErrorMessage,
                     "syncBegan must clear a prior error — the retry is in flight, banner is stale")
    }

    func testSyncEnded_setsLoadingFalse() {
        var state = HoldsState(
            reservedBooks: [], heldBooks: [], visibleBooks: [],
            isLoading: true, syncErrorMessage: nil, searchQuery: ""
        )
        _ = HoldsReducer.reduce(&state, .syncEnded)
        XCTAssertFalse(state.isLoading)
    }

    // MARK: - Sync failure error-banner suppression rules
    //
    // The legacy HoldsViewModel.handleSyncFailure encoded three rules that
    // all have to survive the Store migration:
    //   1. Cached holds visible → suppress error banner (cache is useful).
    //   2. Anonymous user → suppress (can't fetch holds by design).
    //   3. Authenticated user with no cache → surface the error.

    func testSyncFailed_whenCachedDataVisible_suppressesErrorBanner() {
        var state = HoldsState(
            reservedBooks: [], heldBooks: [],
            visibleBooks: [TPPBookMocker.snapshotReservedBook()], // cached
            isLoading: true, syncErrorMessage: nil, searchQuery: ""
        )
        _ = HoldsReducer.reduce(&state, .syncFailed(errorMessage: "oops", cached: true, anonymous: false))
        XCTAssertNil(state.syncErrorMessage,
                     "Cached holds must suppress the error banner — stale data is still useful")
        XCTAssertFalse(state.isLoading,
                       "syncFailed must always clear isLoading, regardless of banner visibility")
    }

    func testSyncFailed_whenAnonymous_suppressesErrorBanner() {
        var state = HoldsState(
            reservedBooks: [], heldBooks: [], visibleBooks: [],
            isLoading: true, syncErrorMessage: nil, searchQuery: ""
        )
        _ = HoldsReducer.reduce(&state, .syncFailed(errorMessage: "oops", cached: false, anonymous: true))
        XCTAssertNil(state.syncErrorMessage,
                     "Anonymous users can't fetch holds by design — banner would be noise")
    }

    func testSyncFailed_whenAuthenticatedWithNoCache_surfacesServerDetailMessage() {
        var state = HoldsState(
            reservedBooks: [], heldBooks: [], visibleBooks: [],
            isLoading: true, syncErrorMessage: nil, searchQuery: ""
        )
        _ = HoldsReducer.reduce(&state, .syncFailed(
            errorMessage: "Your library card has expired.",
            cached: false,
            anonymous: false
        ))
        XCTAssertEqual(state.syncErrorMessage, "Your library card has expired.",
                       "Authenticated user with no cached data must see the server's detail")
    }

    func testSyncFailed_whenAuthenticatedWithNoCacheAndNoMessage_fallsBackToGenericText() {
        var state = HoldsState(
            reservedBooks: [], heldBooks: [], visibleBooks: [],
            isLoading: false, syncErrorMessage: nil, searchQuery: ""
        )
        _ = HoldsReducer.reduce(&state, .syncFailed(
            errorMessage: nil,
            cached: false,
            anonymous: false
        ))
        XCTAssertNotNil(state.syncErrorMessage,
                        "A missing server message must still surface *some* error — nil silences the banner")
        XCTAssertFalse(state.syncErrorMessage!.isEmpty)
    }

    // MARK: - Registry partitioning

    func testRegistryChanged_partitionsBooksByReservedStatus() {
        let reservedBook = TPPBookMocker.snapshotReservedBook(identifier: "reserved-1", title: "Waiting")
        let readyBook = TPPBookMocker.snapshotReadyBook(identifier: "ready-1", title: "Ready")
        let everyday = TPPBookMocker.snapshotEPUB() // neither reserved nor ready

        var state = HoldsState(
            reservedBooks: [], heldBooks: [], visibleBooks: [],
            isLoading: false, syncErrorMessage: nil, searchQuery: ""
        )
        _ = HoldsReducer.reduce(&state, .registryChanged(held: [reservedBook, readyBook, everyday]))

        // Reserved + ready go to reservedBooks (matches legacy isReserved predicate).
        XCTAssertEqual(state.reservedBooks.count, 2)
        XCTAssertEqual(state.heldBooks.count, 1)
        XCTAssertEqual(state.visibleBooks.count, 3,
                       "With an empty search query, visibleBooks must reflect the full held list")
    }

    func testRegistryChanged_withActiveSearch_leavesVisibleBooksAlone() {
        let already = TPPBookMocker.snapshotReadyBook(identifier: "already", title: "Already Showing")
        var state = HoldsState(
            reservedBooks: [], heldBooks: [],
            visibleBooks: [already],
            isLoading: false, syncErrorMessage: nil,
            searchQuery: "Already"
        )
        let incoming = TPPBookMocker.snapshotReservedBook(identifier: "incoming", title: "New Arrival")
        _ = HoldsReducer.reduce(&state, .registryChanged(held: [incoming]))

        // A registry update during an active search must NOT overwrite the
        // filtered visibleBooks — the user's search context is still live.
        XCTAssertEqual(state.visibleBooks, [already],
                       "Registry update during a search must not stomp the filtered visible list")
    }

    // MARK: - Search

    func testSearchQueryChanged_toEmpty_restoresAllHeldBooks() {
        let a = TPPBookMocker.snapshotReservedBook(identifier: "a", title: "Alpha")
        let b = TPPBookMocker.snapshotReadyBook(identifier: "b", title: "Beta")
        var state = HoldsState(
            reservedBooks: [a], heldBooks: [b],
            visibleBooks: [],           // cleared by a previous filter
            isLoading: false, syncErrorMessage: nil, searchQuery: "xyz"
        )
        _ = HoldsReducer.reduce(&state, .searchQueryChanged(""))
        XCTAssertEqual(state.searchQuery, "")
        XCTAssertEqual(state.visibleBooks.count, 2,
                       "Clearing the query must restore the full reserved + held set synchronously")
    }

    // MARK: - Error dismissal

    func testDismissSyncError_clearsTheErrorMessage() {
        var state = HoldsState(
            reservedBooks: [], heldBooks: [], visibleBooks: [],
            isLoading: false, syncErrorMessage: "Something went wrong",
            searchQuery: ""
        )
        _ = HoldsReducer.reduce(&state, .dismissSyncError)
        XCTAssertNil(state.syncErrorMessage)
    }

    // MARK: - Filter-effect pipeline

    func testSearchQueryChanged_nonEmpty_returnsFilterEffectThatYieldsFilterCompleted() async {
        let books = [
            TPPBookMocker.snapshotReservedBook(identifier: "swift", title: "Swift Programming"),
            TPPBookMocker.snapshotReservedBook(identifier: "python", title: "Python Basics")
        ]
        var state = HoldsState(
            reservedBooks: books, heldBooks: [], visibleBooks: books,
            isLoading: false, syncErrorMessage: nil, searchQuery: ""
        )
        let env = makeEnv(filter: { query, _ in
            books.filter { $0.title.localizedCaseInsensitiveContains(query) }
        })
        let effect = HoldsReducer.reduce(&state, .searchQueryChanged("Swift"))
        XCTAssertEqual(state.searchQuery, "Swift")
        let resultAction = await effect.run(env)
        guard case .filterCompleted(let filtered) = resultAction else {
            return XCTFail("Expected .filterCompleted action from filter effect, got \(String(describing: resultAction))")
        }
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.identifier, "swift")
    }
}

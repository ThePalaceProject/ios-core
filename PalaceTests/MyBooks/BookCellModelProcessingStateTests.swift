//
//  `bindProcessingState`: the list cell raises its own spinner on tap, and a
//  borrow failure that clears the registry's processing flag (e.g. an Adobe
//  activation failure, seen while validating PP-3649) left it spinning because the
//  cell did not observe the registry's processing changes. Every assertion fails if the
//  subscription is deleted; the last two fail if it is widened to fight the cell's
//  own tap handling. `BookCellModelOfflineTests` covers the reachability case.
//

import Combine
import XCTest
@testable import Palace
import PalaceBookModel

@MainActor
final class BookCellModelProcessingStateTests: XCTestCase {

    private var mockRegistry: TPPBookRegistryMock!
    private var mockImageCache: MockImageCache!
    private var mockReachability: MockReachability!
    /// ONE container for the suite, not one per model: each
    /// `makeTestAppContainer()` builds an `AccountsManager` that outlives it.
    private var container: AppContainer!

    override func setUp() {
        super.setUp()
        mockRegistry = TPPBookRegistryMock()
        mockImageCache = MockImageCache()
        mockReachability = MockReachability(initiallyConnected: true)
        container = makeTestAppContainer()
    }

    override func tearDown() {
        container = nil
        mockReachability = nil
        mockImageCache = nil
        mockRegistry = nil
        super.tearDown()
    }

    private func makeBook(id: String) -> TPPBook {
        TPPBook(dictionary: [
            "acquisitions": [TPPFake.genericAcquisition.dictionaryRepresentation()],
            "title": "Processing State Regression",
            "categories": ["Fiction"],
            "id": id,
            "updated": "2024-01-01T00:00:00Z"
        ])!
    }

    private func makeModel(book: TPPBook) -> BookCellModel {
        // A test-scoped container, not `AppContainer.production()`: none of the
        // collaborators below participate in what these tests assert (the cell's
        // reaction to a registry processing change), and reaching for the live
        // graph would give this suite a background `loadCatalogs` to race with.
        BookCellModel(
            book: book,
            imageCache: mockImageCache,
            bookRegistry: mockRegistry,
            downloadCenter: container.downloadCenter,
            accountsManager: container.accountsManager,
            samplePreviewManager: container.samplePreviewManager,
            readerService: container.readerService,
            reachability: mockReachability,
            bookOpenDependencies: .testDouble()
        )
    }

    /// Changes the book's processing flag through the registry, as a borrow,
    /// a return or an open does.
    private func postProcessingChange(bookID: String, processing: Bool) {
        mockRegistry.setProcessing(processing, for: bookID)
    }

    // MARK: - Already-presented errors

    /// `BorrowOperation` presents its own alert and publishes with
    /// `presentsAlert: false`. The cell must not raise a second one on top of
    /// it — the shape a patron reads as dismissing an alert and finding
    /// another behind it (PP-5407).
    func test_whenTheProducerAlreadyAlerted_theCellDoesNotRaiseASecondOne() async {
        let book = makeBook(id: "already-alerted")
        mockRegistry.setState(.unregistered, for: book.identifier)
        let model = makeModel(book: book)

        container.downloadCenter.progressReporter.downloadErrorPublisher.send(
            DownloadErrorInfo(
                bookId: book.identifier,
                title: "Borrow Failed",
                message: "Borrowing could not be completed.",
                kind: .borrow,
                retryAction: nil,
                presentsAlert: false
            )
        )
        await drainMainQueueAsync()
        await Task.yield()
        await drainMainQueueAsync()

        XCTAssertNil(model.showAlert,
                     "the producer already put this failure in front of the patron")
        XCTAssertNil(model.downloadErrorAlert,
                     "a half-sheet alert would stack on the one already showing")
    }

    /// The other arm, so the guard above can still be false: an error nobody
    /// has shown yet must reach the patron.
    func test_whenNoOneHasAlertedYet_theCellRaisesTheAlert() async {
        let book = makeBook(id: "not-yet-alerted")
        mockRegistry.setState(.unregistered, for: book.identifier)
        let model = makeModel(book: book)

        container.downloadCenter.progressReporter.downloadErrorPublisher.send(
            DownloadErrorInfo(
                bookId: book.identifier,
                title: "Borrow Failed",
                message: "Borrowing could not be completed.",
                kind: .borrow
            )
        )
        await awaitConditionAsync { (model.showAlert ?? model.downloadErrorAlert) != nil }

        XCTAssertNotNil(model.showAlert ?? model.downloadErrorAlert,
                        "a borrow failure nobody has reported must still reach the patron")
    }

    // MARK: - The defect

    /// THE regression. A borrow that fails clears the registry's processing
    /// flag; the cell must follow it down.
    func test_whenRegistryStopsProcessingThisBook_theSpinnerClears() {
        let book = makeBook(id: "processing-clears")
        mockRegistry.addBook(book, state: .downloadNeeded)
        let model = makeModel(book: book)
        drainMainQueue()

        model.isLoading = true
        postProcessingChange(bookID: book.identifier, processing: false)
        drainMainQueue()

        XCTAssertFalse(model.isLoading,
                       "the registry said this book is no longer being processed and the cell kept spinning — "
                       + "this is the stuck-spinner an Adobe activation failure leaves behind")
    }

    // MARK: - It must not fire for other books

    /// The registry publishes changes for every book, so a cell that does not
    /// filter would clear its spinner whenever ANY other borrow finished — which
    /// looks like it works, because in a list something is usually finishing.
    func test_whenAnotherBookStopsProcessing_thisSpinnerIsUntouched() {
        let book = makeBook(id: "processing-mine")
        mockRegistry.addBook(book, state: .downloadNeeded)
        let model = makeModel(book: book)
        drainMainQueue()

        model.isLoading = true
        postProcessingChange(bookID: "some-entirely-different-book", processing: false)
        drainMainQueue()

        XCTAssertTrue(model.isLoading,
                      "another book's completion cleared this cell's spinner — the bookID filter is missing")
    }

    // MARK: - It only ever LOWERS

    /// Raising on the registry's say-so would fight the cell's own tap
    /// handling, which sets `isLoading` before any registry write happens. A
    /// `processing: true` broadcast must therefore be inert here.
    func test_whenRegistryStartsProcessing_theSpinnerIsNotRaisedFromHere() {
        let book = makeBook(id: "processing-no-raise")
        mockRegistry.addBook(book, state: .downloadNeeded)
        let model = makeModel(book: book)
        drainMainQueue()

        XCTAssertFalse(model.isLoading, "precondition: not loading")

        postProcessingChange(bookID: book.identifier, processing: true)
        drainMainQueue()

        XCTAssertFalse(model.isLoading,
                       "the registry must not RAISE this cell's spinner — the tap handler owns that edge, "
                       + "and a second owner produces a spinner nothing can clear")
    }

    // MARK: - Idempotence

    /// The registry can broadcast `processing: false` repeatedly. Doing so must
    /// not republish `isLoading` on every one — `@Published` fires on assignment,
    /// not on change, and a cell that reassigns per broadcast redraws the whole
    /// list for nothing.
    func test_repeatedNotProcessingBroadcasts_doNotRepublishIsLoading() {
        let book = makeBook(id: "processing-idempotent")
        mockRegistry.addBook(book, state: .downloadNeeded)
        let model = makeModel(book: book)
        drainMainQueue()

        model.isLoading = true
        drainMainQueue()

        var publishedValues: [Bool] = []
        let cancellable = model.$isLoading.dropFirst().sink { publishedValues.append($0) }
        defer { cancellable.cancel() }

        postProcessingChange(bookID: book.identifier, processing: false)
        drainMainQueue()
        postProcessingChange(bookID: book.identifier, processing: false)
        drainMainQueue()
        postProcessingChange(bookID: book.identifier, processing: false)
        drainMainQueue()

        XCTAssertEqual(publishedValues, [false],
                       "three identical broadcasts republished isLoading \(publishedValues.count) times; "
                       + "the `self.isLoading` guard is what keeps this at one")
    }
}

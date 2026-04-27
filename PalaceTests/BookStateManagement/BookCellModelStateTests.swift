//
//  BookCellModelStateTests.swift
//  PalaceTests
//
//  Tests for BookCellModel state synchronization with registry.
//

import XCTest
import Combine
@testable import Palace

@MainActor
final class BookCellModelStateTests: XCTestCase {

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

    // MARK: - Helper to create test book

    private func createTestBook(id: String = "test-book-123") -> TPPBook {
        return TPPBook(dictionary: [
            "acquisitions": [TPPFake.genericAcquisition.dictionaryRepresentation()],
            "title": "Test Book",
            "categories": ["Fiction"],
            "id": id,
            "updated": "2024-01-01T00:00:00Z"
        ])!
    }

    // MARK: - Initial State Tests

    func testInitialStateMatchesRegistry() {
        let book = createTestBook()
        mockRegistry.addBook(book, state: .downloadSuccessful)

        let model = BookCellModel(book: book, imageCache: mockImageCache, bookRegistry: mockRegistry, downloadCenter: AppContainer.production().downloadCenter, accountsManager: .shared, samplePreviewManager: AppContainer.production().samplePreviewManager, readerService: AppContainer.production().readerService)

        XCTAssertEqual(model.registryState, .downloadSuccessful)
        XCTAssertEqual(model.stableButtonState, .downloadSuccessful)
    }

    func testInitialStateForDownloadFailed() {
        let book = createTestBook()
        mockRegistry.addBook(book, state: .downloadFailed)

        let model = BookCellModel(book: book, imageCache: mockImageCache, bookRegistry: mockRegistry, downloadCenter: AppContainer.production().downloadCenter, accountsManager: .shared, samplePreviewManager: AppContainer.production().samplePreviewManager, readerService: AppContainer.production().readerService)

        XCTAssertEqual(model.registryState, .downloadFailed)
        XCTAssertEqual(model.stableButtonState, .downloadFailed)
    }

    func testInitialStateForDownloading() {
        let book = createTestBook()
        mockRegistry.addBook(book, state: .downloading)

        let model = BookCellModel(book: book, imageCache: mockImageCache, bookRegistry: mockRegistry, downloadCenter: AppContainer.production().downloadCenter, accountsManager: .shared, samplePreviewManager: AppContainer.production().samplePreviewManager, readerService: AppContainer.production().readerService)

        XCTAssertEqual(model.registryState, .downloading)
        XCTAssertEqual(model.stableButtonState, .downloadInProgress)
    }

    func testInitialStateForUnregisteredBook() {
        let book = createTestBook()
        // Don't add to registry - should be unregistered

        let model = BookCellModel(book: book, imageCache: mockImageCache, bookRegistry: mockRegistry, downloadCenter: AppContainer.production().downloadCenter, accountsManager: .shared, samplePreviewManager: AppContainer.production().samplePreviewManager, readerService: AppContainer.production().readerService)

        XCTAssertEqual(model.registryState, .unregistered)
    }

    func testInitialStateForHolding() {
        let book = createTestBook()
        mockRegistry.addBook(book, state: .holding)

        let model = BookCellModel(book: book, imageCache: mockImageCache, bookRegistry: mockRegistry, downloadCenter: AppContainer.production().downloadCenter, accountsManager: .shared, samplePreviewManager: AppContainer.production().samplePreviewManager, readerService: AppContainer.production().readerService)

        XCTAssertEqual(model.registryState, .holding)
        XCTAssertEqual(model.stableButtonState, .holding)
    }

    func testInitialStateForDownloadNeeded() {
        let book = createTestBook()
        mockRegistry.addBook(book, state: .downloadNeeded)

        let model = BookCellModel(book: book, imageCache: mockImageCache, bookRegistry: mockRegistry, downloadCenter: AppContainer.production().downloadCenter, accountsManager: .shared, samplePreviewManager: AppContainer.production().samplePreviewManager, readerService: AppContainer.production().readerService)

        XCTAssertEqual(model.registryState, .downloadNeeded)
        XCTAssertEqual(model.stableButtonState, .downloadNeeded)
    }

    // MARK: - State Consistency Validation

    func testValidateStateConsistencyPasses() {
        let book = createTestBook()
        mockRegistry.addBook(book, state: .downloadSuccessful)

        let model = BookCellModel(book: book, imageCache: mockImageCache, bookRegistry: mockRegistry, downloadCenter: AppContainer.production().downloadCenter, accountsManager: .shared, samplePreviewManager: AppContainer.production().samplePreviewManager, readerService: AppContainer.production().readerService)

        XCTAssertTrue(model.validateStateConsistency())
    }

    func testValidateStateConsistencyDetectsMismatch() {
        let book = createTestBook()
        mockRegistry.addBook(book, state: .downloadSuccessful)

        let model = BookCellModel(book: book, imageCache: mockImageCache, bookRegistry: mockRegistry, downloadCenter: AppContainer.production().downloadCenter, accountsManager: .shared, samplePreviewManager: AppContainer.production().samplePreviewManager, readerService: AppContainer.production().readerService)

        // Directly mutate registry without going through setState (simulates a bug)
        mockRegistry.registry[book.identifier]?.state = .downloadFailed

        // State should now be inconsistent
        let isConsistent = model.validateStateConsistency()
        XCTAssertFalse(isConsistent, "Should detect state mismatch")
    }

    // MARK: - BookCellState Tests

    // Verifies that a registry transition to .downloading causes the BookCellModel
    // to expose a .downloading cell state and a .downloadInProgress button state.
    func testBookCellStateForDownloadInProgress() {
        let book = createTestBook()
        mockRegistry.addBook(book, state: .downloading)

        let model = BookCellModel(book: book, imageCache: mockImageCache, bookRegistry: mockRegistry, downloadCenter: AppContainer.production().downloadCenter, accountsManager: .shared, samplePreviewManager: AppContainer.production().samplePreviewManager, readerService: AppContainer.production().readerService)

        // Allow the throttle (50 ms) to settle
        let exp = XCTestExpectation(description: "stableButtonState settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(model.stableButtonState, .downloadInProgress,
            "Registry state .downloading must expose .downloadInProgress button state")
        if case .downloading = model.state {
            // Correct mapping
        } else {
            XCTFail("BookCellState for .downloadInProgress must be .downloading, got \(model.state)")
        }
    }

    // Verifies that a registry .downloadFailed state surfaces as .downloadFailed cell state.
    func testBookCellStateForDownloadFailed() {
        let book = createTestBook()
        mockRegistry.addBook(book, state: .downloadFailed)

        let model = BookCellModel(book: book, imageCache: mockImageCache, bookRegistry: mockRegistry, downloadCenter: AppContainer.production().downloadCenter, accountsManager: .shared, samplePreviewManager: AppContainer.production().samplePreviewManager, readerService: AppContainer.production().readerService)

        let exp = XCTestExpectation(description: "stableButtonState settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(model.stableButtonState, .downloadFailed,
            "Registry state .downloadFailed must expose .downloadFailed button state")
        if case .downloadFailed = model.state {
            // Correct mapping
        } else {
            XCTFail("BookCellState for .downloadFailed must be .downloadFailed, got \(model.state)")
        }
    }

    // Verifies that .downloadSuccessful maps to the .normal cell state.
    func testBookCellStateForDownloadSuccessful() {
        let book = createTestBook()
        mockRegistry.addBook(book, state: .downloadSuccessful)

        let model = BookCellModel(book: book, imageCache: mockImageCache, bookRegistry: mockRegistry, downloadCenter: AppContainer.production().downloadCenter, accountsManager: .shared, samplePreviewManager: AppContainer.production().samplePreviewManager, readerService: AppContainer.production().readerService)

        let exp = XCTestExpectation(description: "stableButtonState settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(model.stableButtonState, .downloadSuccessful,
            "Registry state .downloadSuccessful must expose .downloadSuccessful button state")
        if case .normal = model.state {
            // Correct mapping
        } else {
            XCTFail("BookCellState for .downloadSuccessful must be .normal, got \(model.state)")
        }
    }

    // Verifies that each BookCellState's buttonState matches the underlying BookButtonState,
    // and that the three distinct cell states each carry a distinct button state.
    func testBookCellStateButtonState_MapsThroughCorrectly() {
        let downloadingState = BookCellState(.downloadInProgress)
        let failedState = BookCellState(.downloadFailed)
        let normalState = BookCellState(.downloadSuccessful)

        XCTAssertEqual(downloadingState.buttonState, .downloadInProgress,
            ".downloading cell state must carry .downloadInProgress button state")
        XCTAssertEqual(failedState.buttonState, .downloadFailed,
            ".downloadFailed cell state must carry .downloadFailed button state")
        XCTAssertEqual(normalState.buttonState, .downloadSuccessful,
            ".normal cell state must carry .downloadSuccessful button state")

        // All three button states must be distinct
        XCTAssertNotEqual(downloadingState.buttonState, failedState.buttonState)
        XCTAssertNotEqual(failedState.buttonState, normalState.buttonState)
    }

    // MARK: - Loading State Tests

    // isLoading is driven by image-fetching and download-center events.
    // After init with a pre-cached image (mockRegistry returns image synchronously),
    // isLoading should settle to false once the image fetch callback completes.
    func testIsLoading_SettlesFalseAfterImageFetchCompletes() {
        let book = createTestBook()
        mockRegistry.addBook(book, state: .downloadSuccessful)

        let model = BookCellModel(book: book, imageCache: mockImageCache, bookRegistry: mockRegistry, downloadCenter: AppContainer.production().downloadCenter, accountsManager: .shared, samplePreviewManager: AppContainer.production().samplePreviewManager, readerService: AppContainer.production().readerService)

        // Give the image-fetch callback time to complete
        let exp = XCTestExpectation(description: "isLoading clears after image fetch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertFalse(model.isLoading,
            "isLoading must settle to false once the image-fetch callback completes")
    }

    // statePublisher emits when isLoading changes, letting the UI react.
    func testIsLoading_EmitsViaStatePublisher_WhenChanged() {
        let book = createTestBook()
        mockRegistry.addBook(book, state: .downloadSuccessful)
        let model = BookCellModel(book: book, imageCache: mockImageCache, bookRegistry: mockRegistry, downloadCenter: AppContainer.production().downloadCenter, accountsManager: .shared, samplePreviewManager: AppContainer.production().samplePreviewManager, readerService: AppContainer.production().readerService)

        var emissions: [Bool] = []
        let cancel = model.statePublisher.sink { emissions.append($0) }

        // Act: toggle isLoading (simulates a UI-triggered action like .download)
        model.isLoading = true
        model.isLoading = false

        // Assert: both emissions arrived
        XCTAssertTrue(emissions.contains(true),
            "statePublisher must emit true when isLoading is set to true")
        XCTAssertTrue(emissions.contains(false),
            "statePublisher must emit false when isLoading is cleared")
        cancel.cancel()
    }

    // MARK: - Download Error Routing

    func testDownloadErrorRoutesToCellAlertWhenHalfSheetHidden() {
        let book = createTestBook(id: "download-error-hidden")
        mockRegistry.addBook(book, state: .downloadNeeded)

        let downloadCenter = AppContainer.production().downloadCenter
        let model = BookCellModel(book: book, imageCache: mockImageCache, bookRegistry: mockRegistry, downloadCenter: downloadCenter, accountsManager: .shared, samplePreviewManager: AppContainer.production().samplePreviewManager, readerService: AppContainer.production().readerService)
        let expectation = XCTestExpectation(description: "Cell alert should be populated")

        model.$showAlert
            .dropFirst()
            .sink { alert in
                if alert != nil {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        downloadCenter.downloadErrorPublisher.send(
            DownloadErrorInfo(
                bookId: book.identifier,
                title: "Download Failed",
                message: "Network timeout"
            )
        )

        wait(for: [expectation], timeout: 1.0)
        XCTAssertNotNil(model.showAlert)
        XCTAssertNil(model.downloadErrorAlert)
    }

    func testDownloadErrorRoutesToHalfSheetAlertWhenHalfSheetVisible() {
        let book = createTestBook(id: "download-error-halfsheet")
        mockRegistry.addBook(book, state: .downloadNeeded)

        let downloadCenter = AppContainer.production().downloadCenter
        let model = BookCellModel(book: book, imageCache: mockImageCache, bookRegistry: mockRegistry, downloadCenter: downloadCenter, accountsManager: .shared, samplePreviewManager: AppContainer.production().samplePreviewManager, readerService: AppContainer.production().readerService)
        model.showHalfSheet = true

        let expectation = XCTestExpectation(description: "Half sheet alert should be populated")

        model.$downloadErrorAlert
            .dropFirst()
            .sink { alert in
                if alert != nil {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        downloadCenter.downloadErrorPublisher.send(
            DownloadErrorInfo(
                bookId: book.identifier,
                title: "Download Failed",
                message: "Service unavailable",
                retryAction: {}
            )
        )

        wait(for: [expectation], timeout: 1.0)
        XCTAssertNotNil(model.downloadErrorAlert)
        XCTAssertNil(model.showAlert)
    }
}

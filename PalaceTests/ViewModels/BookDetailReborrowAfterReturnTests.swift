//
//  BookDetailReborrowAfterReturnTests.swift
//  PalaceTests
//
//  A return arms the `.returning` override; the registry's `.unregistered` and
//  the return completion then arrive in either order. Whichever order they
//  take, a later re-borrow must reach the sheet as a loan (PP-5493).
//

import XCTest
import PalaceBookModel
import PalacePreferences
@testable import Palace

@MainActor
final class BookDetailReborrowAfterReturnTests: XCTestCase {

    private var appContainer: AppContainer!
    private var registry: TPPBookRegistryMock!
    private var book: TPPBook!

    override func setUp() {
        super.setUp()
        appContainer = makeTestAppContainer()
        registry = TPPBookRegistryMock()
        book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        registry.addBook(book, state: .downloadSuccessful)
    }

    override func tearDown() {
        book = nil
        registry = nil
        appContainer = nil
        super.tearDown()
    }

    private func makeViewModel() -> BookDetailViewModel {
        BookDetailViewModel(
            book: book,
            registry: registry,
            downloadCenter: appContainer.downloadCenter,
            accountsManager: appContainer.accountsManager,
            settings: TPPSettings(),
            opdsFeedService: appContainer.opdsFeedService,
            samplePreviewManager: appContainer.samplePreviewManager,
            readerService: appContainer.readerService,
            metadataHydrator: { _ in nil },
            dependencies: .testDouble()
        )
    }

    /// The state `handleAction(.return)` leaves before the network call runs.
    private func startReturn(_ viewModel: BookDetailViewModel) {
        viewModel.processingButtons.insert(.return)
        viewModel.bookState = .returning
        viewModel.processingButtons.insert(.returning)
    }

    /// What the production registry does when the return succeeds: the record
    /// goes and `.unregistered` is published for the book.
    private func registryCompletesReturn() {
        registry.setState(.unregistered, for: book.identifier)
        registry.removeBook(forIdentifier: book.identifier)
        drainMainQueue()
    }

    /// What `BorrowOperation` does on success: a fresh record in `.downloadNeeded`.
    private func registryCompletesBorrow() {
        registry.addBook(book, state: .downloadNeeded)
        drainMainQueue()
    }

    // MARK: - Registry update before the completion

    /// The post-return sync can wait up to 30 s for account details before the
    /// completion runs. A re-borrow inside that window must not be dropped.
    func testReborrow_WhenReturnCompletionIsStillPending_ShowsDownload() {
        let viewModel = makeViewModel()
        startReturn(viewModel)
        registryCompletesReturn()

        registryCompletesBorrow()

        XCTAssertEqual(viewModel.bookState, .downloadNeeded,
                       "the re-borrowed loan must replace the finished return")
        awaitCondition { viewModel.buttonState == .downloadNeeded }
    }

    /// A completion that lands after the re-borrow must not put the loan back to Borrow.
    func testReturnCompletion_ArrivingAfterReborrow_KeepsTheLoan() {
        let viewModel = makeViewModel()
        startReturn(viewModel)
        registryCompletesReturn()
        registryCompletesBorrow()

        viewModel.returnDidFinish()

        XCTAssertEqual(viewModel.bookState, .downloadNeeded,
                       "a late return completion must not overwrite a newer loan")
        XCTAssertFalse(viewModel.processingButtons.contains(.returning))
    }

    func testReborrow_WhenRegistryUpdateArrivesBeforeCompletion_ShowsDownload() {
        let viewModel = makeViewModel()
        startReturn(viewModel)
        registryCompletesReturn()
        viewModel.returnDidFinish()

        registryCompletesBorrow()

        XCTAssertEqual(viewModel.bookState, .downloadNeeded)
        awaitCondition { viewModel.buttonState == .downloadNeeded }
    }

    // MARK: - Completion before the registry update

    func testReborrow_WhenCompletionArrivesBeforeRegistryUpdate_ShowsDownload() {
        let viewModel = makeViewModel()
        startReturn(viewModel)
        viewModel.returnDidFinish()
        registryCompletesReturn()

        registryCompletesBorrow()

        XCTAssertEqual(viewModel.bookState, .downloadNeeded)
        awaitCondition { viewModel.buttonState == .downloadNeeded }
    }

    // MARK: - Return that did not complete

    /// A failed or queued return calls the completion without a registry
    /// update. The sheet ends on `.unregistered` as before, and the next
    /// registry state for the kept loan is accepted.
    func testReturnCompletion_WithoutRegistryUpdate_EndsReturnAndAcceptsNextRegistryState() {
        let viewModel = makeViewModel()
        startReturn(viewModel)

        viewModel.returnDidFinish()

        XCTAssertEqual(viewModel.bookState, .unregistered)
        XCTAssertFalse(viewModel.processingButtons.contains(.returning))

        registry.setState(.downloadSuccessful, for: book.identifier)
        drainMainQueue()
        XCTAssertEqual(viewModel.bookState, .downloadSuccessful,
                       "the ended return must not keep suppressing the registry")
    }

    /// While the return is in flight, the sheet keeps showing Returning.
    func testRegistryUpdate_WhileReturnInFlight_KeepsReturning() {
        let viewModel = makeViewModel()
        startReturn(viewModel)

        registry.setState(.downloadSuccessful, for: book.identifier)
        drainMainQueue()

        XCTAssertEqual(viewModel.bookState, .returning)
    }
}

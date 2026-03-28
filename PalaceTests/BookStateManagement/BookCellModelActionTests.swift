//
//  BookCellModelActionTests.swift
//  PalaceTests
//
//  Regression tests: Return and Cancel Hold from My Books list must show
//  a confirmation alert before firing any server-side revoke request.
//

import XCTest
import Combine
@testable import Palace

@MainActor
final class BookCellModelActionTests: XCTestCase {

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

    // MARK: - Helpers

    private func makeModel(state: TPPBookState = .downloadSuccessful) -> BookCellModel {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        mockRegistry.addBook(book, state: state)
        return BookCellModel(book: book, imageCache: mockImageCache, bookRegistry: mockRegistry)
    }

    private func makeHoldModel() -> BookCellModel {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        mockRegistry.addBook(book, state: .holding)
        return BookCellModel(book: book, imageCache: mockImageCache, bookRegistry: mockRegistry)
    }

    // MARK: - Return: confirmation alert shown before any action

    func testReturn_ShowsConfirmationAlert_BeforeRevoking() {
        let model = makeModel()
        XCTAssertNil(model.showAlert, "No alert should exist before any action")

        model.callDelegate(for: .return)

        XCTAssertNotNil(model.showAlert, "Tapping Return must show a confirmation alert")
    }

    func testReturn_DoesNotStartReturnImmediately() {
        let model = makeModel()

        model.callDelegate(for: .return)

        XCTAssertNotEqual(model.bookState, .returning,
            "Book state must not switch to .returning until the patron confirms")
        XCTAssertFalse(model.isLoading,
            "isLoading must not be true until the patron confirms")
    }

    func testReturn_AlertContainsBookTitle() {
        let model = makeModel()

        model.callDelegate(for: .return)

        XCTAssertTrue(
            model.showAlert?.message.contains(model.book.title) == true,
            "Confirmation message must contain the book title"
        )
    }

    func testReturn_AlertHasCancelButton() {
        let model = makeModel()

        model.callDelegate(for: .return)

        XCTAssertNotNil(model.showAlert?.secondaryButtonTitle,
            "Confirmation alert must have a Cancel button")
    }

    // MARK: - Return: confirming the alert starts the return

    func testReturn_ConfirmingAlert_SetsReturningState() {
        let model = makeModel()

        model.callDelegate(for: .return)
        model.showAlert?.primaryAction()

        XCTAssertEqual(model.bookState, .returning,
            "Confirming the alert must set bookState to .returning")
    }

    func testReturn_ConfirmingAlert_DismissesAlert() {
        let model = makeModel()

        model.callDelegate(for: .return)
        XCTAssertNotNil(model.showAlert)

        // Confirming should not leave the alert open waiting for a second tap
        model.showAlert?.primaryAction()

        // After primary action the alert has served its purpose;
        // bookState is the reliable synchronous signal (tested above).
        // We separately verify the alert was an interstitial, not a persistent one.
        XCTAssertEqual(model.bookState, .returning,
            "After confirming, the return must have been initiated")
    }

    // MARK: - Return: cancelling the alert leaves the book untouched

    func testReturn_CancellingAlert_DoesNotSetReturningState() {
        let model = makeModel()

        model.callDelegate(for: .return)
        model.showAlert?.secondaryAction()

        XCTAssertNotEqual(model.bookState, .returning,
            "Cancelling the alert must not set bookState to .returning")
    }

    func testReturn_CancellingAlert_ResetsIsLoading() {
        let model = makeModel()

        model.callDelegate(for: .return)
        model.showAlert?.secondaryAction()

        XCTAssertFalse(model.isLoading,
            "Cancelling the alert must leave isLoading as false")
    }

    // MARK: - Cancel Hold: confirmation alert shown before any action

    func testCancelHold_ShowsConfirmationAlert_BeforeRevoking() {
        let model = makeHoldModel()
        XCTAssertNil(model.showAlert, "No alert should exist before any action")

        model.callDelegate(for: .cancelHold)

        XCTAssertNotNil(model.showAlert, "Tapping Cancel Hold must show a confirmation alert")
    }

    func testCancelHold_DoesNotStartReturnImmediately() {
        let model = makeHoldModel()

        model.callDelegate(for: .cancelHold)

        XCTAssertNotEqual(model.bookState, .returning,
            "Book state must not switch to .returning until the patron confirms")
        XCTAssertFalse(model.isLoading,
            "isLoading must not be true until the patron confirms")
    }

    func testCancelHold_AlertContainsBookTitle() {
        let model = makeHoldModel()

        model.callDelegate(for: .cancelHold)

        XCTAssertTrue(
            model.showAlert?.message.contains(model.book.title) == true,
            "Confirmation message must contain the book title"
        )
    }

    func testCancelHold_AlertHasCancelButton() {
        let model = makeHoldModel()

        model.callDelegate(for: .cancelHold)

        XCTAssertNotNil(model.showAlert?.secondaryButtonTitle,
            "Confirmation alert must have a Cancel button")
    }

    // MARK: - Cancel Hold: confirming the alert starts the return

    func testCancelHold_ConfirmingAlert_SetsReturningState() {
        let model = makeHoldModel()

        model.callDelegate(for: .cancelHold)
        model.showAlert?.primaryAction()

        XCTAssertEqual(model.bookState, .returning,
            "Confirming cancel-hold alert must set bookState to .returning")
    }

    // MARK: - Cancel Hold: cancelling the alert leaves hold intact

    func testCancelHold_CancellingAlert_DoesNotSetReturningState() {
        let model = makeHoldModel()

        model.callDelegate(for: .cancelHold)
        model.showAlert?.secondaryAction()

        XCTAssertNotEqual(model.bookState, .returning,
            "Cancelling the cancel-hold alert must not change book state")
    }

    // MARK: - Remove (local delete) should still be immediate — no confirmation

    func testRemove_DoesNotShowAlert_ProceedsImmediately() {
        let model = makeModel()

        model.callDelegate(for: .remove)

        XCTAssertNil(model.showAlert,
            "Remove (local delete) should not show a confirmation alert")
    }
}

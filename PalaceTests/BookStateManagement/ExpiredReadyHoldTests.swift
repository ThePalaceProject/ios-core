//
//  ExpiredReadyHoldTests.swift
//  PalaceTests
//
//  A ready hold can be borrowed only until its `until`. After that the server
//  places a new hold at the back of the queue instead of a loan, so the app must
//  not offer Borrow, and the alert must show the new queue position (PP-5453).
//

import XCTest
import PalaceCatalog
@testable import Palace
import PalaceBookModel

@MainActor
final class ExpiredReadyHoldTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func ready(untilOffset offset: TimeInterval?) -> TPPOPDSAcquisitionAvailabilityReady {
        TPPOPDSAcquisitionAvailabilityReady(
            since: now.addingTimeInterval(-86_400 * 3),
            until: offset.map { now.addingTimeInterval($0) }
        )
    }

    private func book(with availability: TPPOPDSAcquisitionAvailability) -> TPPBook {
        let url = URL(string: "https://example.com/pp-5453")!
        let acquisition = TPPOPDSAcquisition(
            relation: .borrow,
            type: "application/epub+zip",
            hrefURL: url,
            indirectAcquisitions: [],
            availability: availability
        )
        return TPPBook(
            acquisitions: [acquisition],
            authors: nil, categoryStrings: nil, distributor: nil,
            identifier: "pp-5453-\(UUID().uuidString)",
            imageURL: nil, imageThumbnailURL: nil, published: nil, publisher: nil,
            subtitle: nil, summary: nil, title: "Expired Ready", updated: now,
            annotationsURL: nil, analyticsURL: nil, alternateURL: nil,
            relatedWorksURL: nil, previewLink: nil, seriesURL: nil,
            revokeURL: nil, reportURL: nil, timeTrackingURL: nil,
            contributors: nil, bookDuration: nil, imageCache: MockImageCache()
        )
    }

    private func mapHolding(_ availability: TPPOPDSAcquisitionAvailability) -> BookButtonState {
        BookButtonMapper.map(registryState: .holding, availability: availability, isProcessingDownload: false, now: now)
    }

    // MARK: - BookButtonMapper.map (.holding)

    func testMap_HoldingReady_UntilInPast_ShowsHoldingNotBorrow() {
        XCTAssertEqual(mapHolding(ready(untilOffset: -3600)), .holding)
    }

    /// The reservation window is closed at `until` itself.
    func testMap_HoldingReady_UntilEqualsNow_ShowsHolding() {
        XCTAssertEqual(mapHolding(ready(untilOffset: 0)), .holding)
    }

    func testMap_HoldingReady_UntilInFuture_OffersBorrow() {
        XCTAssertEqual(mapHolding(ready(untilOffset: 1)), .canBorrow)
    }

    /// A ready hold with no `until` is treated as still open.
    func testMap_HoldingReady_NoUntil_OffersBorrow() {
        XCTAssertEqual(mapHolding(ready(untilOffset: nil)), .canBorrow)
    }

    // MARK: - BookButtonMapper.stateForAvailability (.unregistered path)

    func testStateForAvailability_ReadyUntilInPast_ShowsHolding() {
        XCTAssertEqual(BookButtonMapper.stateForAvailability(ready(untilOffset: -1), now: now), .holding)
        XCTAssertEqual(
            BookButtonMapper.map(registryState: .unregistered, availability: ready(untilOffset: -1),
                                 isProcessingDownload: false, now: now),
            .holding
        )
    }

    func testStateForAvailability_ReadyUntilInFutureOrMissing_OffersBorrow() {
        XCTAssertEqual(BookButtonMapper.stateForAvailability(ready(untilOffset: 60), now: now), .canBorrow)
        XCTAssertEqual(BookButtonMapper.stateForAvailability(ready(untilOffset: nil), now: now), .canBorrow)
    }

    // MARK: - BookButtonState.buttonTypes

    /// Expired: Manage Hold, which leads to Cancel Hold; no Get button.
    func testButtonTypes_HoldingExpiredReady_ShowsManageHoldWithoutGet() {
        let expired = book(with: ready(untilOffset: -60))

        XCTAssertEqual(BookButtonState.holding.buttonTypes(book: expired, previewEnabled: false, now: now), [.manageHold])
        XCTAssertEqual(BookButtonState.managingHold.buttonTypes(book: expired, previewEnabled: false, now: now), [.cancelHold])
    }

    func testButtonTypes_HoldingOpenReady_ShowsGetAndCancelHold() {
        let open = book(with: ready(untilOffset: 60))

        XCTAssertEqual(BookButtonState.holding.buttonTypes(book: open, previewEnabled: false, now: now), [.get, .cancelHold])
        XCTAssertEqual(BookButtonState.managingHold.buttonTypes(book: open, previewEnabled: false, now: now), [.get, .cancelHold])
    }

    // MARK: - BookCellModel (production caller, real clock)

    private func cellModel(holdUntil until: Date) -> BookCellModel {
        let book = book(with: TPPOPDSAcquisitionAvailabilityReady(since: nil, until: until))
        let registry = TPPBookRegistryMock()
        registry.addBook(book, state: .holding)
        let container = makeTestAppContainer()
        return BookCellModel(book: book, imageCache: MockImageCache(), bookRegistry: registry,
                             downloadCenter: container.downloadCenter, accountsManager: container.accountsManager,
                             samplePreviewManager: container.samplePreviewManager, readerService: container.readerService)
    }

    /// A My Books cell for a ready hold whose window has closed offers no Get button.
    func testBookCellModel_HoldingReadyUntilDistantPast_OffersNoGet() {
        let model = cellModel(holdUntil: .distantPast)

        XCTAssertEqual(model.stableButtonState, .holding)
        XCTAssertFalse(model.buttonTypes.contains(.get), "\(model.buttonTypes)")
        XCTAssertTrue(model.buttonTypes.contains(.manageHold), "\(model.buttonTypes)")
    }

    func testBookCellModel_HoldingReadyUntilDistantFuture_OffersGet() {
        let model = cellModel(holdUntil: .distantFuture)

        XCTAssertEqual(model.stableButtonState, .canBorrow)
        XCTAssertTrue(model.buttonTypes.contains(.get), "\(model.buttonTypes)")
    }

    // MARK: - BorrowReducerCore.responseState (Borrow returned a hold)

    private func borrowResponse(holdPosition: UInt) -> (state: TPPBookState, error: PalaceError?) {
        let preBorrow = book(with: ready(untilOffset: -60))
        let postBorrow = book(with: TPPOPDSAcquisitionAvailabilityReserved(
            holdPosition: holdPosition, copiesTotal: 2, since: now, until: nil))
        return BorrowReducerCore.responseState(for: postBorrow, preBorrowBook: preBorrow)
    }

    func testBorrowResponse_ReservedWithPosition_ReportsQueuePosition() {
        let result = borrowResponse(holdPosition: 7)

        XCTAssertEqual(result.state, .holding)
        guard case .holdRequeued(let position)? = result.error else {
            return XCTFail("expected .holdRequeued, got \(String(describing: result.error))")
        }
        XCTAssertEqual(position, 7)
    }

    /// Position 0 means the feed gave none, so the alert keeps the general text.
    func testBorrowResponse_ReservedWithoutPosition_KeepsGeneralHoldError() {
        let result = borrowResponse(holdPosition: 0)

        XCTAssertEqual(result.state, .holding)
        guard case .bookRegistry(.holdCopyUnavailable)? = result.error else {
            return XCTFail("expected .holdCopyUnavailable, got \(String(describing: result.error))")
        }
    }

    // MARK: - Alert text

    func testBorrowErrorMessage_HoldRequeued_ShowsPositionInsteadOfStillInLine() {
        let message = BorrowOperation.buildBorrowErrorMessage(
            for: "Title", error: .holdRequeued(position: 7), problemDocument: nil)

        XCTAssertTrue(message.contains(7.ordinal()), message)
        XCTAssertFalse(message.contains("You're still in line"), message)
        XCTAssertEqual(PalaceError.holdRequeued(position: 7).recoverySuggestion, Strings.Error.holdRequeued(position: 7))
    }

    func testBorrowErrorMessage_HoldCopyUnavailable_KeepsStillInLineText() {
        let message = BorrowOperation.buildBorrowErrorMessage(
            for: "Title", error: .bookRegistry(.holdCopyUnavailable), problemDocument: nil)

        XCTAssertTrue(message.contains("You're still in line"), message)
    }
}

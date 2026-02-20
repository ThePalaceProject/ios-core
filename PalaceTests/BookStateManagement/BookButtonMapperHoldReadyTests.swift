//
//  BookButtonMapperHoldReadyTests.swift
//  PalaceTests
//
//  Regression tests for PP-3702: When a hold becomes available (availability="ready")
//  but registry state is still .holding, the mapper must return .canBorrow so the
//  patron sees a "Get" button rather than "Manage Hold".
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class BookButtonMapperHoldReadyTests: XCTestCase {

    // MARK: - Ready Availability + Holding Registry State

    /// PP-3702: Hold is ready to borrow but registry hasn't transitioned yet.
    /// Before fix: returned .holding (showed "Manage Hold")
    /// After fix:  returns .canBorrow (shows "Get")
    func testMap_HoldingState_ReadyAvailability_ReturnsCanBorrow() {
        let readyAvailability: TPPOPDSAcquisitionAvailability =
            TPPOPDSAcquisitionAvailabilityReady(since: Date(), until: Date().addingTimeInterval(86400 * 3))

        let result = BookButtonMapper.map(
            registryState: .holding,
            availability: readyAvailability,
            isProcessingDownload: false
        )

        XCTAssertEqual(result, .canBorrow, "Ready hold should show canBorrow, not holding")
    }

    /// Holding state with reserved (not-yet-ready) availability stays .holding.
    func testMap_HoldingState_ReservedAvailability_ReturnsHolding() {
        let reservedAvailability: TPPOPDSAcquisitionAvailability =
            TPPOPDSAcquisitionAvailabilityReserved(holdPosition: 3, copiesTotal: 5, since: Date(), until: nil)

        let result = BookButtonMapper.map(
            registryState: .holding,
            availability: reservedAvailability,
            isProcessingDownload: false
        )

        XCTAssertEqual(result, .holding, "Non-ready hold should remain .holding")
    }

    /// Holding state with nil availability stays .holding (no availability info).
    func testMap_HoldingState_NilAvailability_ReturnsHolding() {
        let result = BookButtonMapper.map(
            registryState: .holding,
            availability: nil,
            isProcessingDownload: false
        )

        XCTAssertEqual(result, .holding, "Holding with nil availability should remain .holding")
    }

    /// Holding state with unavailable availability stays .holding.
    func testMap_HoldingState_UnavailableAvailability_ReturnsHolding() {
        let unavailable: TPPOPDSAcquisitionAvailability =
            TPPOPDSAcquisitionAvailabilityUnavailable(copiesHeld: 5, copiesTotal: 5)

        let result = BookButtonMapper.map(
            registryState: .holding,
            availability: unavailable,
            isProcessingDownload: false
        )

        XCTAssertEqual(result, .holding, "Holding with unavailable should remain .holding")
    }

    /// Holding state with limited (copies available > 0) availability shows .canBorrow.
    func testMap_HoldingState_LimitedWithCopiesAvailability_ReturnsCanBorrow() {
        let limited: TPPOPDSAcquisitionAvailability =
            TPPOPDSAcquisitionAvailabilityLimited(copiesAvailable: 2, copiesTotal: 5, since: nil, until: nil)

        let result = BookButtonMapper.map(
            registryState: .holding,
            availability: limited,
            isProcessingDownload: false
        )

        XCTAssertEqual(result, .canBorrow, "Holding with available copies should return .canBorrow")
    }

    /// Holding state with limited (copies = 0) stays .holding.
    func testMap_HoldingState_LimitedNoCopiesAvailability_ReturnsHolding() {
        let limited: TPPOPDSAcquisitionAvailability =
            TPPOPDSAcquisitionAvailabilityLimited(copiesAvailable: 0, copiesTotal: 5, since: nil, until: nil)

        let result = BookButtonMapper.map(
            registryState: .holding,
            availability: limited,
            isProcessingDownload: false
        )

        XCTAssertEqual(result, .holding, "Holding with zero copies should remain .holding")
    }

    /// Holding state with unlimited availability shows .canBorrow.
    func testMap_HoldingState_UnlimitedAvailability_ReturnsCanBorrow() {
        let unlimited: TPPOPDSAcquisitionAvailability =
            TPPOPDSAcquisitionAvailabilityUnlimited()

        let result = BookButtonMapper.map(
            registryState: .holding,
            availability: unlimited,
            isProcessingDownload: false
        )

        XCTAssertEqual(result, .canBorrow, "Holding with unlimited availability should return .canBorrow")
    }

    // MARK: - Other States Unaffected

    /// Download states are unaffected by the hold-ready fix.
    func testMap_DownloadingState_Unaffected() {
        let readyAvailability: TPPOPDSAcquisitionAvailability =
            TPPOPDSAcquisitionAvailabilityReady(since: Date(), until: nil)

        let result = BookButtonMapper.map(
            registryState: .downloading,
            availability: readyAvailability,
            isProcessingDownload: false
        )

        XCTAssertEqual(result, .downloadInProgress, "Downloading state should take priority")
    }

    func testMap_ProcessingDownload_Unaffected() {
        let readyAvailability: TPPOPDSAcquisitionAvailability =
            TPPOPDSAcquisitionAvailabilityReady(since: Date(), until: nil)

        let result = BookButtonMapper.map(
            registryState: .holding,
            availability: readyAvailability,
            isProcessingDownload: true
        )

        XCTAssertEqual(result, .downloadInProgress, "isProcessingDownload should take priority")
    }

    // MARK: - stateForAvailability Direct Tests

    func testStateForAvailability_Ready_ReturnsCanBorrow() {
        let ready: TPPOPDSAcquisitionAvailability =
            TPPOPDSAcquisitionAvailabilityReady(since: Date(), until: nil)

        let result = BookButtonMapper.stateForAvailability(ready)

        XCTAssertEqual(result, .canBorrow)
    }

    func testStateForAvailability_Reserved_ReturnsHoldingFrontOfQueue() {
        let reserved: TPPOPDSAcquisitionAvailability =
            TPPOPDSAcquisitionAvailabilityReserved(holdPosition: 1, copiesTotal: 5, since: nil, until: nil)

        let result = BookButtonMapper.stateForAvailability(reserved)

        XCTAssertEqual(result, .holdingFrontOfQueue)
    }

    func testStateForAvailability_Nil_ReturnsNil() {
        let result = BookButtonMapper.stateForAvailability(nil)

        XCTAssertNil(result)
    }
}

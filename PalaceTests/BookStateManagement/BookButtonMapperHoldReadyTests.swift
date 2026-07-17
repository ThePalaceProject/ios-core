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
import PalaceCatalog
@testable import Palace

@MainActor
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

    /// Holding state with limited (copies available > 0) stays .holding — only "ready" triggers canBorrow.
    func testMap_HoldingState_LimitedWithCopiesAvailability_ReturnsHolding() {
        let limited: TPPOPDSAcquisitionAvailability =
            TPPOPDSAcquisitionAvailabilityLimited(copiesAvailable: 2, copiesTotal: 5, since: nil, until: nil)

        let result = BookButtonMapper.map(
            registryState: .holding,
            availability: limited,
            isProcessingDownload: false
        )

        XCTAssertEqual(result, .holding, "Holding with limited availability should remain .holding")
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

    /// Holding state with unlimited availability stays .holding — only "ready" triggers canBorrow.
    func testMap_HoldingState_UnlimitedAvailability_ReturnsHolding() {
        let unlimited: TPPOPDSAcquisitionAvailability =
            TPPOPDSAcquisitionAvailabilityUnlimited()

        let result = BookButtonMapper.map(
            registryState: .holding,
            availability: unlimited,
            isProcessingDownload: false
        )

        XCTAssertEqual(result, .holding, "Holding with unlimited availability should remain .holding")
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

    /// `stateForAvailability` is the cache-friendly availability→button-state
    /// mapper. Lock all three branches (Ready, Reserved, nil) in one body
    /// so a mutant that swaps two branches' return values fails on a
    /// distinct row, AND assert that distinct availability inputs yield
    /// distinct button states (kills constant-return mutants).
    func testStateForAvailability_dispatchesEachAvailabilityToItsExpectedButtonState() {
        let ready = BookButtonMapper.stateForAvailability(
            TPPOPDSAcquisitionAvailabilityReady(since: Date(), until: nil))
        let reserved = BookButtonMapper.stateForAvailability(
            TPPOPDSAcquisitionAvailabilityReserved(holdPosition: 1, copiesTotal: 5, since: nil, until: nil))
        let nilResult = BookButtonMapper.stateForAvailability(nil)

        XCTAssertEqual(ready, .canBorrow,
                       "Ready (loan reserved + ready to borrow) → canBorrow")
        XCTAssertEqual(reserved, .holdingFrontOfQueue,
                       "Reserved with hold position → holdingFrontOfQueue")
        XCTAssertNil(nilResult,
                     "nil availability → nil state (caller falls back to default rendering)")

        // Distinct inputs must yield distinct results — guards a
        // constant-return mutant the per-branch tests can't catch alone.
        XCTAssertNotEqual(ready, reserved,
                          "Ready and Reserved must dispatch to distinct button states")
    }
}

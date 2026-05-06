//
//  BookButtonMapperTests.swift
//  PalaceTests
//
//  Tests for BookButtonMapper.map() and stateForAvailability().
//  Covers all registry state -> button state mappings and
//  OPDS availability -> button state logic.
//
//  Copyright 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class BookButtonMapperExtendedTests: XCTestCase {

    // MARK: - Registry State Priority Tests

    func testMap_downloading_returnsDownloadInProgress() {
        let result = BookButtonMapper.map(
            registryState: .downloading,
            availability: nil,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .downloadInProgress)
    }

    func testMap_isProcessingDownload_returnsDownloadInProgress() {
        let result = BookButtonMapper.map(
            registryState: .unregistered,
            availability: nil,
            isProcessingDownload: true
        )
        XCTAssertEqual(result, .downloadInProgress)
    }

    func testMap_downloadFailed_returnsDownloadFailed() {
        let result = BookButtonMapper.map(
            registryState: .downloadFailed,
            availability: nil,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .downloadFailed)
    }

    func testMap_downloadSuccessful_returnsDownloadSuccessful() {
        let result = BookButtonMapper.map(
            registryState: .downloadSuccessful,
            availability: nil,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .downloadSuccessful)
    }

    func testMap_downloadNeeded_returnsDownloadNeeded() {
        let result = BookButtonMapper.map(
            registryState: .downloadNeeded,
            availability: nil,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .downloadNeeded)
    }

    func testMap_used_returnsUsed() {
        let result = BookButtonMapper.map(
            registryState: .used,
            availability: nil,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .used)
    }

    func testMap_returning_returnsReturning() {
        let result = BookButtonMapper.map(
            registryState: .returning,
            availability: nil,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .returning)
    }

    // MARK: - Holding State Tests

    func testMap_holding_withReadyAvailability_returnsCanBorrow() {
        let ready = TPPOPDSAcquisitionAvailabilityReady(since: nil, until: nil)
        let result = BookButtonMapper.map(
            registryState: .holding,
            availability: ready,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .canBorrow)
    }

    func testMap_holding_withoutReadyAvailability_returnsHolding() {
        let reserved = TPPOPDSAcquisitionAvailabilityReserved(
            holdPosition: 3,
            copiesTotal: 5,
            since: nil,
            until: nil
        )
        let result = BookButtonMapper.map(
            registryState: .holding,
            availability: reserved,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .holding)
    }

    func testMap_holding_withNilAvailability_returnsHolding() {
        let result = BookButtonMapper.map(
            registryState: .holding,
            availability: nil,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .holding)
    }

    // MARK: - Availability Fallthrough Tests

    func testMap_unregistered_withUnlimitedAvailability_returnsCanBorrow() {
        let unlimited = TPPOPDSAcquisitionAvailabilityUnlimited()
        let result = BookButtonMapper.map(
            registryState: .unregistered,
            availability: unlimited,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .canBorrow)
    }

    func testMap_unregistered_withUnavailableAvailability_returnsCanHold() {
        let unavailable = TPPOPDSAcquisitionAvailabilityUnavailable(
            copiesHeld: 5,
            copiesTotal: 5
        )
        let result = BookButtonMapper.map(
            registryState: .unregistered,
            availability: unavailable,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .canHold)
    }

    func testMap_unregistered_withNilAvailability_returnsUnsupported() {
        let result = BookButtonMapper.map(
            registryState: .unregistered,
            availability: nil,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .unsupported)
    }

    // MARK: - stateForAvailability Tests

    func testStateForAvailability_nil_returnsNil() {
        let result = BookButtonMapper.stateForAvailability(nil)
        XCTAssertNil(result)
    }

    func testStateForAvailability_unavailable_returnsCanHold() {
        let unavailable = TPPOPDSAcquisitionAvailabilityUnavailable(
            copiesHeld: 10,
            copiesTotal: 10
        )
        let result = BookButtonMapper.stateForAvailability(unavailable)
        XCTAssertEqual(result, .canHold)
    }

    func testStateForAvailability_limitedWithCopies_returnsCanBorrow() {
        let limited = TPPOPDSAcquisitionAvailabilityLimited(
            copiesAvailable: 3,
            copiesTotal: 10,
            since: nil,
            until: nil
        )
        let result = BookButtonMapper.stateForAvailability(limited)
        XCTAssertEqual(result, .canBorrow)
    }

    func testStateForAvailability_limitedWithZeroCopies_returnsCanHold() {
        let limited = TPPOPDSAcquisitionAvailabilityLimited(
            copiesAvailable: 0,
            copiesTotal: 10,
            since: nil,
            until: nil
        )
        let result = BookButtonMapper.stateForAvailability(limited)
        XCTAssertEqual(result, .canHold)
    }

    func testStateForAvailability_limitedWithUnknownCopies_returnsCanBorrow() {
        let limited = TPPOPDSAcquisitionAvailabilityLimited(
            copiesAvailable: TPPOPDSAcquisitionAvailabilityCopiesUnknown,
            copiesTotal: TPPOPDSAcquisitionAvailabilityCopiesUnknown,
            since: nil,
            until: nil
        )
        let result = BookButtonMapper.stateForAvailability(limited)
        XCTAssertEqual(result, .canBorrow)
    }

    func testStateForAvailability_unlimited_returnsCanBorrow() {
        let unlimited = TPPOPDSAcquisitionAvailabilityUnlimited()
        let result = BookButtonMapper.stateForAvailability(unlimited)
        XCTAssertEqual(result, .canBorrow)
    }

    func testStateForAvailability_reserved_returnsHoldingFrontOfQueue() {
        let reserved = TPPOPDSAcquisitionAvailabilityReserved(
            holdPosition: 1,
            copiesTotal: 5,
            since: nil,
            until: nil
        )
        let result = BookButtonMapper.stateForAvailability(reserved)
        XCTAssertEqual(result, .holdingFrontOfQueue)
    }

    func testStateForAvailability_ready_returnsCanBorrow() {
        let ready = TPPOPDSAcquisitionAvailabilityReady(since: nil, until: nil)
        let result = BookButtonMapper.stateForAvailability(ready)
        XCTAssertEqual(result, .canBorrow)
    }

    // MARK: - Priority Tests (registry state overrides availability)

    func testMap_downloadingOverridesAvailability() {
        let unlimited = TPPOPDSAcquisitionAvailabilityUnlimited()
        let result = BookButtonMapper.map(
            registryState: .downloading,
            availability: unlimited,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .downloadInProgress,
                       "Registry state .downloading should override availability")
    }

    func testMap_downloadFailedOverridesAvailability() {
        let unlimited = TPPOPDSAcquisitionAvailabilityUnlimited()
        let result = BookButtonMapper.map(
            registryState: .downloadFailed,
            availability: unlimited,
            isProcessingDownload: false
        )
        XCTAssertEqual(result, .downloadFailed,
                       "Registry state .downloadFailed should override availability")
    }

    func testMap_isProcessingDownloadOverridesEverything() {
        let unlimited = TPPOPDSAcquisitionAvailabilityUnlimited()
        let result = BookButtonMapper.map(
            registryState: .downloadFailed,
            availability: unlimited,
            isProcessingDownload: true
        )
        XCTAssertEqual(result, .downloadInProgress,
                       "isProcessingDownload should override even downloadFailed state")
    }
}

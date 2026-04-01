//
//  TPPMigrationManagerTests.swift
//  PalaceTests
//
//  Unit tests for TPPMigrationManager.version(_:isLessThan:) comparison logic.
//
//  Copyright (c) 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

/// SRS: SET-001 — Migration version comparison drives upgrade paths
final class TPPMigrationManagerTests: XCTestCase {

    // MARK: - Equal versions

    func testVersion_equalVersions_returnsFalse() {
        XCTAssertFalse(TPPMigrationManager.version([1, 2, 3], isLessThan: [1, 2, 3]))
    }

    func testVersion_emptyArrays_returnsFalse() {
        XCTAssertFalse(TPPMigrationManager.version([], isLessThan: []))
    }

    // MARK: - Clearly less-than

    func testVersion_majorLessThan_returnsTrue() {
        XCTAssertTrue(TPPMigrationManager.version([1, 0, 0], isLessThan: [2, 0, 0]))
    }

    func testVersion_minorLessThan_returnsTrue() {
        XCTAssertTrue(TPPMigrationManager.version([1, 2, 0], isLessThan: [1, 3, 0]))
    }

    func testVersion_patchLessThan_returnsTrue() {
        XCTAssertTrue(TPPMigrationManager.version([1, 2, 3], isLessThan: [1, 2, 4]))
    }

    // MARK: - Clearly greater-than

    func testVersion_majorGreaterThan_returnsFalse() {
        XCTAssertFalse(TPPMigrationManager.version([3, 0, 0], isLessThan: [2, 0, 0]))
    }

    func testVersion_minorGreaterThan_returnsFalse() {
        XCTAssertFalse(TPPMigrationManager.version([1, 5, 0], isLessThan: [1, 3, 0]))
    }

    // MARK: - Different-length versions

    func testVersion_shorterA_withNonZeroRemainder_returnsTrue() {
        // 1.2 < 1.2.1
        XCTAssertTrue(TPPMigrationManager.version([1, 2], isLessThan: [1, 2, 1]))
    }

    func testVersion_shorterA_withZeroRemainder_returnsFalse() {
        // 1.2 is NOT less than 1.2.0
        XCTAssertFalse(TPPMigrationManager.version([1, 2], isLessThan: [1, 2, 0]))
    }

    func testVersion_longerA_returnsFalse() {
        // 1.2.1 is NOT less than 1.2
        XCTAssertFalse(TPPMigrationManager.version([1, 2, 1], isLessThan: [1, 2]))
    }

    // MARK: - Empty a (fresh install)

    func testVersion_emptyA_nonEmptyB_returnsTrue() {
        XCTAssertTrue(TPPMigrationManager.version([], isLessThan: [1, 0, 0]))
    }

    func testVersion_emptyA_zeroB_returnsFalse() {
        // [] is NOT less than [0] because remaining b has no non-zero component
        XCTAssertFalse(TPPMigrationManager.version([], isLessThan: [0]))
    }

    func testVersion_emptyA_zeroZeroB_returnsFalse() {
        XCTAssertFalse(TPPMigrationManager.version([], isLessThan: [0, 0, 0]))
    }

    // MARK: - Single-component versions

    func testVersion_singleComponent_lessThan() {
        XCTAssertTrue(TPPMigrationManager.version([1], isLessThan: [2]))
    }

    func testVersion_singleComponent_equal() {
        XCTAssertFalse(TPPMigrationManager.version([5], isLessThan: [5]))
    }
}

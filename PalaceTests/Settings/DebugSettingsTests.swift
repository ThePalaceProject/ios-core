//
//  DebugSettingsTests.swift
//  PalaceTests
//
//  Tests for DebugSettings: simulated errors, badge logging,
//  test holds configuration, and reset behavior.
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class DebugSettingsTests: XCTestCase {

    private let settings = DebugSettings.shared

    override func tearDown() {
        settings.resetAll()
        super.tearDown()
    }

    // MARK: - SimulatedBorrowError

    // SRS: SimulatedBorrowError all cases have display names
    func testSimulatedBorrowError_allCasesHaveDisplayNames() {
        for errorCase in DebugSettings.SimulatedBorrowError.allCases {
            XCTAssertFalse(errorCase.displayName.isEmpty, "\(errorCase) should have non-empty displayName")
        }
    }

    // SRS: SimulatedBorrowError.none has nil problemDocument
    func testSimulatedBorrowError_none_nilProblemDoc() {
        XCTAssertNil(DebugSettings.SimulatedBorrowError.none.problemDocument)
    }

    // SRS: SimulatedBorrowError.loanLimitReached has problem document
    func testSimulatedBorrowError_loanLimit() {
        let doc = DebugSettings.SimulatedBorrowError.loanLimitReached.problemDocument
        XCTAssertNotNil(doc)
        XCTAssertEqual(doc?.type, TPPProblemDocument.TypePatronLoanLimit)
        XCTAssertEqual(doc?.status, 403)
    }

    // SRS: SimulatedBorrowError.holdLimitReached has problem document
    func testSimulatedBorrowError_holdLimit() {
        let doc = DebugSettings.SimulatedBorrowError.holdLimitReached.problemDocument
        XCTAssertNotNil(doc)
        XCTAssertEqual(doc?.type, TPPProblemDocument.TypePatronHoldLimit)
    }

    // SRS: SimulatedBorrowError.credentialsSuspended has problem document
    func testSimulatedBorrowError_credentialsSuspended() {
        let doc = DebugSettings.SimulatedBorrowError.credentialsSuspended.problemDocument
        XCTAssertNotNil(doc)
        XCTAssertEqual(doc?.type, TPPProblemDocument.TypeCredentialsSuspended)
    }

    // SRS: SimulatedBorrowError.genericServerError has problem document with 500 status
    func testSimulatedBorrowError_generic() {
        let doc = DebugSettings.SimulatedBorrowError.genericServerError.problemDocument
        XCTAssertNotNil(doc)
        XCTAssertEqual(doc?.status, 500)
    }

    // MARK: - DebugSettings Properties

    // SRS: DebugSettings default simulatedBorrowError is .none
    func testDefaultSimulatedBorrowError() {
        settings.resetAll()
        XCTAssertEqual(settings.simulatedBorrowError, .none)
    }

    // SRS: DebugSettings simulatedBorrowError can be set
    func testSimulatedBorrowError_canBeSet() {
        settings.simulatedBorrowError = .loanLimitReached
        XCTAssertEqual(settings.simulatedBorrowError, .loanLimitReached)
    }

    // SRS: isBorrowErrorSimulationEnabled reflects simulatedBorrowError
    func testIsBorrowErrorSimulationEnabled() {
        settings.simulatedBorrowError = .none
        XCTAssertFalse(settings.isBorrowErrorSimulationEnabled)

        settings.simulatedBorrowError = .genericServerError
        XCTAssertTrue(settings.isBorrowErrorSimulationEnabled)
    }

    // SRS: createSimulatedBorrowError returns nil when disabled
    func testCreateSimulatedBorrowError_nilWhenDisabled() {
        settings.simulatedBorrowError = .none
        XCTAssertNil(settings.createSimulatedBorrowError())
    }

    // SRS: createSimulatedBorrowError returns error when enabled
    func testCreateSimulatedBorrowError_returnsErrorWhenEnabled() {
        settings.simulatedBorrowError = .loanLimitReached
        let result = settings.createSimulatedBorrowError()
        XCTAssertNotNil(result)
        XCTAssertNotNil(result?.error)
        XCTAssertNotNil(result?.problemDocument)
    }

    // MARK: - Badge Logging

    // SRS: isBadgeLoggingEnabled defaults to false
    func testBadgeLogging_defaultFalse() {
        settings.resetAll()
        XCTAssertFalse(settings.isBadgeLoggingEnabled)
    }

    // SRS: isBadgeLoggingEnabled can be toggled
    func testBadgeLogging_canBeToggled() {
        settings.isBadgeLoggingEnabled = true
        XCTAssertTrue(settings.isBadgeLoggingEnabled)

        settings.isBadgeLoggingEnabled = false
        XCTAssertFalse(settings.isBadgeLoggingEnabled)
    }

    // MARK: - Test Holds Configuration

    // SRS: TestHoldsConfiguration all cases have display names
    func testTestHoldsConfig_allCasesHaveDisplayNames() {
        for config in DebugSettings.TestHoldsConfiguration.allCases {
            XCTAssertFalse(config.displayName.isEmpty)
        }
    }

    // SRS: TestHoldsConfiguration.none expectedBadgeCount is -1
    func testTestHoldsConfig_none_badgeCount() {
        XCTAssertEqual(DebugSettings.TestHoldsConfiguration.none.expectedBadgeCount, -1)
    }

    // SRS: TestHoldsConfiguration.oneReserved expectedBadgeCount is 0
    func testTestHoldsConfig_oneReserved_badgeCount() {
        XCTAssertEqual(DebugSettings.TestHoldsConfiguration.oneReserved.expectedBadgeCount, 0)
    }

    // SRS: TestHoldsConfiguration.oneReady expectedBadgeCount is 1
    func testTestHoldsConfig_oneReady_badgeCount() {
        XCTAssertEqual(DebugSettings.TestHoldsConfiguration.oneReady.expectedBadgeCount, 1)
    }

    // SRS: TestHoldsConfiguration.mixedHolds expectedBadgeCount is 1
    func testTestHoldsConfig_mixedHolds_badgeCount() {
        XCTAssertEqual(DebugSettings.TestHoldsConfiguration.mixedHolds.expectedBadgeCount, 1)
    }

    // SRS: TestHoldsConfiguration.allReady expectedBadgeCount is 3
    func testTestHoldsConfig_allReady_badgeCount() {
        XCTAssertEqual(DebugSettings.TestHoldsConfiguration.allReady.expectedBadgeCount, 3)
    }

    // SRS: testHoldsConfiguration defaults to .none
    func testTestHoldsConfig_default() {
        settings.resetAll()
        XCTAssertEqual(settings.testHoldsConfiguration, .none)
    }

    // SRS: isTestHoldsEnabled reflects testHoldsConfiguration
    func testIsTestHoldsEnabled() {
        settings.testHoldsConfiguration = .none
        XCTAssertFalse(settings.isTestHoldsEnabled)

        settings.testHoldsConfiguration = .oneReady
        XCTAssertTrue(settings.isTestHoldsEnabled)
    }

    // SRS: createTestHoldBooks returns nil when disabled
    func testCreateTestHoldBooks_nilWhenDisabled() {
        settings.testHoldsConfiguration = .none
        XCTAssertNil(settings.createTestHoldBooks())
    }

    // SRS: createTestHoldBooks returns 1 book for oneReserved
    func testCreateTestHoldBooks_oneReserved() {
        settings.testHoldsConfiguration = .oneReserved
        let books = settings.createTestHoldBooks()
        XCTAssertEqual(books?.count, 1)
    }

    // SRS: createTestHoldBooks returns 1 book for oneReady
    func testCreateTestHoldBooks_oneReady() {
        settings.testHoldsConfiguration = .oneReady
        let books = settings.createTestHoldBooks()
        XCTAssertEqual(books?.count, 1)
    }

    // SRS: createTestHoldBooks returns 4 books for mixedHolds
    func testCreateTestHoldBooks_mixedHolds() {
        settings.testHoldsConfiguration = .mixedHolds
        let books = settings.createTestHoldBooks()
        XCTAssertEqual(books?.count, 4)
    }

    // SRS: createTestHoldBooks returns 3 books for allReady
    func testCreateTestHoldBooks_allReady() {
        settings.testHoldsConfiguration = .allReady
        let books = settings.createTestHoldBooks()
        XCTAssertEqual(books?.count, 3)
    }

    // MARK: - Reset

    // SRS: resetAll resets all settings to defaults
    func testResetAll() {
        settings.simulatedBorrowError = .loanLimitReached
        settings.isBadgeLoggingEnabled = true
        settings.testHoldsConfiguration = .allReady

        settings.resetAll()

        XCTAssertEqual(settings.simulatedBorrowError, .none)
        XCTAssertFalse(settings.isBadgeLoggingEnabled)
        XCTAssertEqual(settings.testHoldsConfiguration, .none)
    }
}

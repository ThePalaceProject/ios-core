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

    private let settings = DebugSettings()

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
        // All display names must be distinct so the picker UI is unambiguous
        let names = DebugSettings.SimulatedBorrowError.allCases.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count,
                       "All SimulatedBorrowError display names must be unique")
    }

    // SRS: SimulatedBorrowError.none has nil problemDocument
    func testSimulatedBorrowError_none_nilProblemDoc() {
        XCTAssertNil(DebugSettings.SimulatedBorrowError.none.problemDocument)
        // The .none case must also have a non-empty display name
        XCTAssertFalse(DebugSettings.SimulatedBorrowError.none.displayName.isEmpty,
                       ".none case must still have a display name for the picker")
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
        XCTAssertEqual(doc?.status, 403, "Hold limit error must carry HTTP 403 status")
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
        // After reset, the simulation must be disabled (isBorrowErrorSimulationEnabled = false)
        XCTAssertFalse(settings.isBorrowErrorSimulationEnabled,
                       "resetAll must set isBorrowErrorSimulationEnabled to false")
    }

    // SRS: DebugSettings simulatedBorrowError can be set
    func testSimulatedBorrowError_canBeSet() {
        let before = settings.simulatedBorrowError
        settings.simulatedBorrowError = .loanLimitReached
        // Setting a non-none error must enable simulation
        XCTAssertTrue(settings.isBorrowErrorSimulationEnabled,
                      "Setting loanLimitReached must enable borrow error simulation")
        XCTAssertNotEqual(settings.simulatedBorrowError, before,
                          "Setting loanLimitReached must change the value from the default .none")
        // Resetting to .none must disable simulation
        settings.simulatedBorrowError = .none
        XCTAssertFalse(settings.isBorrowErrorSimulationEnabled,
                       "Resetting to .none must disable borrow error simulation")
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
        XCTAssertFalse(settings.isBorrowErrorSimulationEnabled,
                       "isBorrowErrorSimulationEnabled must be false when error is .none")
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
        // Enabling then resetting must return to false (not sticky)
        settings.isBadgeLoggingEnabled = true
        settings.resetAll()
        XCTAssertFalse(settings.isBadgeLoggingEnabled,
                       "resetAll must restore isBadgeLoggingEnabled to its default false value")
    }

    // SRS: isBadgeLoggingEnabled persists correctly through resetAll
    func testBadgeLogging_enabledStateIsResetByResetAll() {
        // Arrange: enable badge logging
        settings.isBadgeLoggingEnabled = true
        let beforeReset = settings.isBadgeLoggingEnabled
        XCTAssertTrue(beforeReset, "Precondition: badge logging should be enabled before reset")

        // Act: reset all settings
        settings.resetAll()
        let afterReset = settings.isBadgeLoggingEnabled

        // Assert: resetAll must restore the default (false) regardless of previous state
        XCTAssertFalse(afterReset, "resetAll must restore isBadgeLoggingEnabled to its default false value")
        XCTAssertNotEqual(beforeReset, afterReset,
                          "isBadgeLoggingEnabled value must change after resetAll")
    }

    // MARK: - Test Holds Configuration

    // SRS: TestHoldsConfiguration all cases have display names
    func testTestHoldsConfig_allCasesHaveDisplayNames() {
        for config in DebugSettings.TestHoldsConfiguration.allCases {
            XCTAssertFalse(config.displayName.isEmpty)
        }
        // All names must be unique so the debug picker is unambiguous
        let names = DebugSettings.TestHoldsConfiguration.allCases.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count, "TestHoldsConfiguration display names must all be unique")
    }

    // SRS: TestHoldsConfiguration.none expectedBadgeCount is -1
    func testTestHoldsConfig_none_badgeCount() {
        XCTAssertEqual(DebugSettings.TestHoldsConfiguration.none.expectedBadgeCount, -1)
        // -1 is the sentinel that signals "do not show a badge" to the UI
        XCTAssertLessThan(DebugSettings.TestHoldsConfiguration.none.expectedBadgeCount, 0,
                          ".none badge count must be negative to signal no badge")
    }

    // SRS: TestHoldsConfiguration.oneReserved expectedBadgeCount is 0
    func testTestHoldsConfig_oneReserved_badgeCount() {
        XCTAssertEqual(DebugSettings.TestHoldsConfiguration.oneReserved.expectedBadgeCount, 0)
        // Reserved (position > 1) shows 0 badge — not yet at front of queue
        XCTAssertGreaterThan(DebugSettings.TestHoldsConfiguration.oneReserved.expectedBadgeCount,
                             DebugSettings.TestHoldsConfiguration.none.expectedBadgeCount,
                             "oneReserved badge count must be greater than .none sentinel value")
    }

    // SRS: TestHoldsConfiguration.oneReady expectedBadgeCount is 1
    func testTestHoldsConfig_oneReady_badgeCount() {
        XCTAssertEqual(DebugSettings.TestHoldsConfiguration.oneReady.expectedBadgeCount, 1)
        XCTAssertGreaterThan(DebugSettings.TestHoldsConfiguration.oneReady.expectedBadgeCount,
                             DebugSettings.TestHoldsConfiguration.oneReserved.expectedBadgeCount,
                             "oneReady badge count must exceed oneReserved count")
    }

    // SRS: TestHoldsConfiguration.mixedHolds expectedBadgeCount is 1
    func testTestHoldsConfig_mixedHolds_badgeCount() {
        XCTAssertEqual(DebugSettings.TestHoldsConfiguration.mixedHolds.expectedBadgeCount, 1)
        // mixedHolds and oneReady both show 1 badge (one ready hold each)
        XCTAssertEqual(DebugSettings.TestHoldsConfiguration.mixedHolds.expectedBadgeCount,
                       DebugSettings.TestHoldsConfiguration.oneReady.expectedBadgeCount,
                       "mixedHolds and oneReady should both show 1 ready hold in badge")
    }

    // SRS: TestHoldsConfiguration.allReady expectedBadgeCount is 3
    func testTestHoldsConfig_allReady_badgeCount() {
        XCTAssertEqual(DebugSettings.TestHoldsConfiguration.allReady.expectedBadgeCount, 3)
        XCTAssertGreaterThan(DebugSettings.TestHoldsConfiguration.allReady.expectedBadgeCount,
                             DebugSettings.TestHoldsConfiguration.oneReady.expectedBadgeCount,
                             "allReady badge count must exceed oneReady badge count")
    }

    // SRS: testHoldsConfiguration defaults to .none
    func testTestHoldsConfig_default() {
        settings.resetAll()
        XCTAssertEqual(settings.testHoldsConfiguration, .none)
        XCTAssertFalse(settings.isTestHoldsEnabled,
                       "resetAll must disable test holds (isTestHoldsEnabled = false)")
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
        // Enabling a non-none configuration must produce non-nil results
        settings.testHoldsConfiguration = .oneReserved
        XCTAssertNotNil(settings.createTestHoldBooks(),
                        "createTestHoldBooks must return non-nil for .oneReserved configuration")
        // Disabling again must return nil
        settings.testHoldsConfiguration = .none
        XCTAssertNil(settings.createTestHoldBooks(),
                     "createTestHoldBooks must return nil again after resetting to .none")
    }

    // SRS: createTestHoldBooks returns 1 book for oneReserved
    func testCreateTestHoldBooks_oneReserved() {
        settings.testHoldsConfiguration = .oneReserved
        let books = settings.createTestHoldBooks()
        XCTAssertEqual(books?.count, 1)
        XCTAssertNotNil(books?.first, "createTestHoldBooks must return at least one book for .oneReserved")
    }

    // SRS: createTestHoldBooks returns 1 book for oneReady
    func testCreateTestHoldBooks_oneReady() {
        settings.testHoldsConfiguration = .oneReady
        let books = settings.createTestHoldBooks()
        XCTAssertEqual(books?.count, 1)
        XCTAssertNotNil(books?.first, "createTestHoldBooks must return at least one book for .oneReady")
    }

    // SRS: createTestHoldBooks returns 4 books for mixedHolds
    func testCreateTestHoldBooks_mixedHolds() {
        settings.testHoldsConfiguration = .mixedHolds
        let books = settings.createTestHoldBooks()
        XCTAssertEqual(books?.count, 4)
        // Mixed holds has more books than a single-hold config
        XCTAssertGreaterThan(books?.count ?? 0, 1,
                             "mixedHolds must return more than 1 book")
    }

    // SRS: createTestHoldBooks returns 3 books for allReady
    func testCreateTestHoldBooks_allReady() {
        settings.testHoldsConfiguration = .allReady
        let books = settings.createTestHoldBooks()
        XCTAssertEqual(books?.count, 3)
        XCTAssertGreaterThan(books?.count ?? 0, 1,
                             "allReady must return more than 1 book")
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

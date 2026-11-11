//
//  TPPNetworkExecutorDIInitTests.swift
//  PalaceTests
//
//  The DI initializer must not read `AppContainer.production()` while it runs:
//  the container builds an executor under its build lock (PP-4980).
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

#if DEBUG
@MainActor
final class TPPNetworkExecutorDIInitTests: XCTestCase {

    override func tearDown() {
        // The first test rebuilds the shared graph; leave a fresh one behind.
        AppContainer._resetForTesting()
        super.tearDown()
    }

    /// With no manager supplied, the executor reads the container when it first
    /// needs a manager, so it sees a graph built after the executor was.
    func testDIInit_WithoutAccountsManager_ResolvesTheContainerAtUseNotAtInit() {
        let executor = TPPNetworkExecutor(cachingStrategy: .ephemeral, accountsManager: nil)

        AppContainer._resetForTesting()
        let rebuilt = AppContainer.production().accountsManager // MIGRATED-DEFERRED: resolving the production container at use is the contract under test.

        XCTAssertTrue(executor.accountsManager as AnyObject === rebuilt,
                      "A manager captured during init would belong to the graph that existed then")
    }

    /// A supplied manager is the one the executor uses.
    func testDIInit_WithAccountsManager_UsesTheSuppliedManager() {
        let supplied = TPPLibraryAccountMock()

        let executor = TPPNetworkExecutor(cachingStrategy: .ephemeral, accountsManager: supplied)

        XCTAssertTrue(executor.accountsManager as AnyObject === supplied)
    }
}
#endif

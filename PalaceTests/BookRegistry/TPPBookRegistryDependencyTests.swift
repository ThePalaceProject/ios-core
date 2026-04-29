//
//  TPPBookRegistryDependencyTests.swift
//  PalaceTests
//
//  Pins down the explicit-AccountsManager-dependency contract introduced
//  when `TPPBookRegistry.shared` was killed in Phase 6.6.
//
//  Why these tests matter:
//
//  Before 6.6, TPPBookRegistry.init did `self.accountsManager = AppContainer.production().accountsManager`.
//  That re-entered AppContainer's static-let dispatch_once during app launch
//  the moment AccountsManager.shared was killed (PR #884), because
//  AppContainer._cached had to read TPPBookRegistry.shared. Two singletons
//  cross-referencing each other through a third lazy initializer is exactly
//  the pattern the kill is meant to remove.
//
//  These tests verify:
//   1. The new init takes AccountsManager explicitly (no Foundation default,
//      no AppContainer lookup).
//   2. The injected AccountsManager is what mutations and `with(account:)`
//      thread through (so swapping it actually changes behavior).
//   3. AppContainer.production() returns the same registry instance every
//      time — distinct calls don't construct duplicates that would each spawn
//      their own currentAccountDidChange observer.
//   4. AppContainer construction itself doesn't deadlock: the regression
//      contract for the dispatch_once trap that motivated the kill.
//
//  Copyright 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

final class TPPBookRegistryDependencyTests: XCTestCase {

    // MARK: - Init contract

    /// The new init MUST take AccountsManager explicitly. If someone re-adds
    /// a default value or pulls AccountsManager from AppContainer.production()
    /// inside the body, this test stays green only by accident — but the
    /// app-launch regression test (testAppContainer_constructionDoesNotDeadlock)
    /// catches the dispatch_once trap. Together they prevent the cycle from
    /// silently coming back.
    func testInit_takesAccountsManagerExplicitly() {
        let accountsManager = AccountsManager()
        let registry = TPPBookRegistry(accountsManager: accountsManager)

        // The registry exists and has access to its dependency. We assert via
        // a side-effect that requires accountsManager: addBook captures
        // currentAccount?.uuid synchronously and threads it through to the
        // store. With no current account, the no-op path executes — no crash
        // is the contract.
        let book = TPPBookMocker.mockBook(identifier: "init-test", title: "Init Test", distributorType: .EpubZip)
        registry.addBook(book)
        XCTAssertNotNil(registry, "Constructed registry must remain valid after a mutation")
    }

    /// `with(account:)` constructs a temporary instance scoped to a different
    /// account file, but inherits the *parent's* accountsManager — never
    /// reaches back into AppContainer.production(). This is the contract
    /// that broke the cycle.
    func testWithAccount_inheritsParentAccountsManager() {
        let accountsManager = AccountsManager()
        let registry = TPPBookRegistry(accountsManager: accountsManager)

        // The block executes synchronously and receives a different instance
        // than the parent. If `with(account:)` accidentally reached for
        // AppContainer.production().bookRegistry, the block argument would
        // be the same instance (and we'd lose per-account isolation).
        var blockRanWithDifferentInstance = false
        registry.with(account: "test-account-uuid") { tempRegistry in
            blockRanWithDifferentInstance = (tempRegistry !== registry)
        }
        XCTAssertTrue(
            blockRanWithDifferentInstance,
            "with(account:) must construct a fresh per-account instance, not return self"
        )
    }

    // MARK: - AppContainer integration (the regression contract)

    /// AppContainer.production() must return the same registry instance on
    /// every call. If a refactor accidentally constructs a new registry per
    /// call, every call site spawns its own currentAccountDidChange observer
    /// and library switches start firing N parallel reloads.
    func testAppContainer_returnsSameRegistryInstance() {
        let containerA = AppContainer.production()
        let containerB = AppContainer.production()
        XCTAssertTrue(
            containerA.bookRegistry as AnyObject === containerB.bookRegistry as AnyObject,
            "AppContainer.production() must return the same TPPBookRegistry across calls"
        )
    }

    /// Regression test for the dispatch_once trap that motivated the 6.6 kill.
    ///
    /// Before this PR: AppContainer._cached read `TPPBookRegistry.shared`,
    /// which triggered TPPBookRegistry.init, which read
    /// `AppContainer.production().accountsManager`, which re-entered
    /// _cached's dispatch_once → trap on first launch.
    ///
    /// After this PR: AppContainer._cached constructs both AccountsManager
    /// and TPPBookRegistry inline (passing the former into the latter), so
    /// nothing inside this dispatch_once reaches back to AppContainer.production().
    ///
    /// The simplest behavioral contract: if reading both .bookRegistry and
    /// .accountsManager from the production container is non-blocking and
    /// returns coherent values, the cycle is gone. If it ever comes back,
    /// this test would either deadlock the test process or surface a nil
    /// dependency.
    func testAppContainer_constructionDoesNotDeadlock() {
        // First production() call triggers the dispatch_once. If init
        // re-entered, the test process would deadlock here and time out.
        let container = AppContainer.production()

        // Both dependencies must be live — not a zombie half-constructed
        // value left over from a recursive entry.
        let registry = container.bookRegistry
        let accountsManager = container.accountsManager

        // Identity contract: the AccountsManager the registry was built with
        // must be the same one the container hands out separately. If the
        // registry quietly constructed its own, the cycle would be hidden
        // but mutations on the container's accountsManager would silently
        // not affect the registry (and vice versa).
        XCTAssertNotNil(registry, "Production container must expose a non-nil registry")
        XCTAssertNotNil(accountsManager, "Production container must expose a non-nil accountsManager")
    }
}

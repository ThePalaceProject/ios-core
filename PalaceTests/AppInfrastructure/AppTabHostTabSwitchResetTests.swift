//
//  AppTabHostTabSwitchResetTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import SwiftUI
@testable import Palace

/// PP-5022 — pins the second production behavior change: a tab switch resets
/// the stack of the tab being LEFT, not the one being entered.
///
/// This used to pop "whatever the global hub pointer held", which was an
/// ordering accident — sometimes the outgoing tab, sometimes the incoming one.
/// Nothing pinned it, so swapping the two arguments of
/// `handleTabSelectionChange(from:to:)` would silently yank the screen the
/// patron is navigating TO, and the suite would stay green.
@MainActor
final class AppTabHostTabSwitchResetTests: XCTestCase {

    private var testContainer: AppContainer!
    private var host: AppTabHostView!

    override func setUp() async throws {
        try await super.setUp()
        // Mock registry: `handleTabSelectionChange(to: .myBooks)` calls
        // `bookRegistry.sync()`, and a real registry would spawn background work
        // that outlives the test (CI contract #2).
        testContainer = makeTestAppContainer(bookRegistry: TPPBookRegistryMock())
        host = AppTabHostView(appContainer: testContainer)
    }

    override func tearDown() async throws {
        host = nil
        testContainer = nil
        try await super.tearDown()
    }

    /// Leaving Catalog for My Books resets Catalog and leaves My Books alone.
    /// Both stacks are non-empty so "reset the right one" is distinguishable
    /// from "reset everything" and from "reset nothing".
    func testTabSelectionChange_ResetsTheOutgoingTabOnly() {
        let hub = testContainer.navigationCoordinatorHub
        let catalog = NavigationCoordinator()
        let myBooks = NavigationCoordinator()
        hub.register(catalog, for: .catalog)
        hub.register(myBooks, for: .myBooks)
        catalog.push(.bookDetail(BookRoute(id: "catalog-book")))
        myBooks.push(.bookDetail(BookRoute(id: "mybooks-book")))

        host.handleTabSelectionChange(from: .catalog, to: .myBooks)

        XCTAssertEqual(catalog.path.count, 0,
                       "The tab being left must be reset to root")
        XCTAssertEqual(myBooks.path.count, 1,
                       "The tab being entered must keep the screen the patron is arriving at")
    }

    /// The mirror case — swapping the arguments must not pass both directions.
    func testTabSelectionChange_LeavingMyBooks_ResetsMyBooksNotCatalog() {
        let hub = testContainer.navigationCoordinatorHub
        let catalog = NavigationCoordinator()
        let myBooks = NavigationCoordinator()
        hub.register(catalog, for: .catalog)
        hub.register(myBooks, for: .myBooks)
        catalog.push(.bookDetail(BookRoute(id: "catalog-book")))
        myBooks.push(.epub(BookRoute(id: "mybooks-book")))

        host.handleTabSelectionChange(from: .myBooks, to: .catalog)

        XCTAssertEqual(myBooks.path.count, 0, "The tab being left must be reset to root")
        XCTAssertEqual(catalog.path.count, 1, "The tab being entered must be untouched")
    }

    /// A tab with no registered stack must not take the reset out on some other
    /// tab — the wrong-stack write this whole fix exists to prevent.
    func testTabSelectionChange_UnregisteredOutgoingTab_TouchesNothing() {
        let hub = testContainer.navigationCoordinatorHub
        let myBooks = NavigationCoordinator()
        hub.register(myBooks, for: .myBooks)
        myBooks.push(.bookDetail(BookRoute(id: "mybooks-book")))

        host.handleTabSelectionChange(from: .holds, to: .myBooks)

        XCTAssertEqual(myBooks.path.count, 1,
                       "An unregistered outgoing tab must not fall through and reset another tab's stack")
    }
}

//
//  AppTabSwitchPreservesStacksTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import SwiftUI
@testable import Palace

/// What a tab switch does to the tabs' navigation stacks.
///
/// PP-5022 made this deterministic: the reset had been aimed at whichever stack
/// a global pointer happened to hold, so it hit the tab being left or the tab
/// being entered depending on view-appearance ordering. This class pinned it to
/// the outgoing tab.
///
/// PP-5051 then removed the reset entirely — deliberately inverting the contract
/// these tests were written to hold. A tab switch must now leave BOTH stacks
/// alone, so browsing deep into a lane and stepping over to My Books no longer
/// costs you your place. The assertions below are the inversion, kept in place
/// rather than deleted so the change of contract is visible: the mutant that
/// matters is a reset creeping back in, on either side of the switch.
///
/// The way back to a tab's root is now tapping the tab you are already on; that
/// gesture is covered by `AppTabStackMemoryTests`.
@MainActor
final class AppTabSwitchPreservesStacksTests: XCTestCase {

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

    /// Both stacks non-empty, so "reset neither" is distinguishable from "reset
    /// the outgoing one", "reset the incoming one", and "reset both".
    func testTabSelectionChange_LeavesBothStacksAlone() {
        let hub = testContainer.navigationCoordinatorHub
        let catalog = NavigationCoordinator()
        let myBooks = NavigationCoordinator()
        hub.register(catalog, for: .catalog)
        hub.register(myBooks, for: .myBooks)
        catalog.push(.bookDetail(BookRoute(id: "catalog-book")))
        myBooks.push(.bookDetail(BookRoute(id: "mybooks-book")))

        host.handleTabSelectionChange(from: .catalog, to: .myBooks)

        XCTAssertEqual(catalog.path.count, 1,
                       "The tab being left must keep the screen the patron was on")
        XCTAssertEqual(myBooks.path.count, 1,
                       "The tab being entered must keep the screen it was showing")
    }

    /// The mirror direction — a reset that only fires one way would pass the
    /// test above.
    func testTabSelectionChange_LeavingMyBooks_LeavesBothStacksAlone() {
        let hub = testContainer.navigationCoordinatorHub
        let catalog = NavigationCoordinator()
        let myBooks = NavigationCoordinator()
        hub.register(catalog, for: .catalog)
        hub.register(myBooks, for: .myBooks)
        catalog.push(.bookDetail(BookRoute(id: "catalog-book")))
        myBooks.push(.epub(BookRoute(id: "mybooks-book")))

        host.handleTabSelectionChange(from: .myBooks, to: .catalog)

        XCTAssertEqual(myBooks.path.count, 1)
        XCTAssertEqual(catalog.path.count, 1)
    }

    /// A switch involving a tab with no registered stack must be a no-op rather
    /// than reaching for some other tab's — the wrong-stack write PP-5022 fixed.
    func testTabSelectionChange_UnregisteredTab_TouchesNothing() {
        let hub = testContainer.navigationCoordinatorHub
        let myBooks = NavigationCoordinator()
        hub.register(myBooks, for: .myBooks)
        myBooks.push(.bookDetail(BookRoute(id: "mybooks-book")))

        host.handleTabSelectionChange(from: .holds, to: .myBooks)

        XCTAssertEqual(myBooks.path.count, 1,
                       "An unregistered tab must not fall through to another tab's stack")
    }
}

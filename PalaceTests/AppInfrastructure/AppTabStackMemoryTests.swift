//
//  AppTabStackMemoryTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import SwiftUI
@testable import Palace

/// PP-5051 — tapping the tab you are already on returns that tab to its start,
/// and a library switch now has to clear every tab rather than just the visible
/// one.
///
/// That a tab switch preserves both stacks is pinned by
/// `AppTabSwitchPreservesStacksTests`, the class whose contract this change
/// inverted.
///
/// Before this, leaving a tab reset it: browse deep into a catalog lane, check
/// My Books, come back, and the lane was gone. There was also no way to ask for
/// the top, because a tap on the already-selected tab writes the same value to
/// the selection binding and therefore never reached `onChange`.
@MainActor
final class AppTabStackMemoryTests: XCTestCase {

    private var testContainer: AppContainer!
    private var host: AppTabHostView!

    override func setUp() async throws {
        try await super.setUp()
        testContainer = makeTestAppContainer(bookRegistry: TPPBookRegistryMock())
        host = AppTabHostView(appContainer: testContainer)
    }

    override func tearDown() async throws {
        host = nil
        testContainer = nil
        try await super.tearDown()
    }

    private func registerStacks() -> (catalog: NavigationCoordinator, myBooks: NavigationCoordinator) {
        let catalog = NavigationCoordinator()
        let myBooks = NavigationCoordinator()
        testContainer.navigationCoordinatorHub.register(catalog, for: .catalog)
        testContainer.navigationCoordinatorHub.register(myBooks, for: .myBooks)
        return (catalog, myBooks)
    }

    // MARK: - Re-tapping the active tab

    /// A tap on the tab you are already on is the "back to the top" gesture; a
    /// tap on any other tab is a switch. SwiftUI writes the same value to the
    /// selection binding on a re-tap, which is why this cannot be an onChange.
    func testTabTap_OnTheActiveTab_MeansReturnToRoot() {
        XCTAssertEqual(AppTabHostView.tabTapOutcome(tapped: .catalog, current: .catalog),
                       .returnToRoot(.catalog))
    }

    func testTabTap_OnAnotherTab_MeansSwitch() {
        XCTAssertEqual(AppTabHostView.tabTapOutcome(tapped: .myBooks, current: .catalog),
                       .switchTo(.myBooks))
    }

    /// Every tab, both ways — the decision is a two-cell table and both cells
    /// must hold for each tab, not just the one the test author had in mind.
    func testTabTap_TableHoldsForEveryTab() {
        let tabs: [AppTab] = [.catalog, .myBooks, .holds, .settings]
        for tapped in tabs {
            for current in tabs {
                let expected: TabTapOutcome = tapped == current ? .returnToRoot(tapped) : .switchTo(tapped)
                XCTAssertEqual(AppTabHostView.tabTapOutcome(tapped: tapped, current: current), expected,
                               "tap \(tapped) while on \(current)")
            }
        }
    }

    // MARK: - The composition: decision + effect together

    /// Swapping the two arms of `applyTabTap` makes the app unnavigable while
    /// every table test still passes, so the composition needs its own evidence.
    /// The selection sink is explicit precisely so it can be observed — the
    /// view's `@StateObject` router cannot be (SwiftUI vends a fresh instance on
    /// every access outside a rendered view).
    func testApplyTabTap_OnTheActiveTab_PopsItAndDoesNotSwitch() {
        let (catalog, myBooks) = registerStacks()
        catalog.push(.bookDetail(BookRoute(id: "a-book")))
        myBooks.push(.bookDetail(BookRoute(id: "another-book")))
        var selected: [AppTab] = []

        AppTabHostView.applyTabTap(.catalog,
                                   current: .catalog,
                                   hub: testContainer.navigationCoordinatorHub,
                                   selectTab: { selected.append($0) })

        XCTAssertEqual(catalog.path.count, 0, "Re-tapping the active tab returns it to its start")
        XCTAssertEqual(myBooks.path.count, 1, "…and reaches no other tab")
        XCTAssertTrue(selected.isEmpty, "A re-tap must not re-select — it would fire every switch side effect")
    }

    /// The other arm: a different tab selects and pops nothing.
    func testApplyTabTap_OnAnotherTab_SwitchesAndPopsNothing() {
        let (catalog, myBooks) = registerStacks()
        catalog.push(.bookDetail(BookRoute(id: "a-book")))
        myBooks.push(.bookDetail(BookRoute(id: "another-book")))
        var selected: [AppTab] = []

        AppTabHostView.applyTabTap(.myBooks,
                                   current: .catalog,
                                   hub: testContainer.navigationCoordinatorHub,
                                   selectTab: { selected.append($0) })

        XCTAssertEqual(selected, [.myBooks], "Tapping another tab selects it")
        XCTAssertEqual(catalog.path.count, 1, "Switching away must not reset the tab you left")
        XCTAssertEqual(myBooks.path.count, 1, "Switching in must not reset the tab you entered")
    }

    /// Re-tapping a tab already at its root, or one with no registered stack: a
    /// no-op rather than a crash on an empty path.
    func testApplyTabTap_AtRootOrUnregistered_IsHarmless() {
        let (catalog, _) = registerStacks()
        var selected: [AppTab] = []
        let hub = testContainer.navigationCoordinatorHub

        AppTabHostView.applyTabTap(.catalog, current: .catalog, hub: hub, selectTab: { selected.append($0) })
        AppTabHostView.applyTabTap(.settings, current: .settings, hub: hub, selectTab: { selected.append($0) })

        XCTAssertEqual(catalog.path.count, 0)
        XCTAssertTrue(selected.isEmpty)
    }

    // MARK: - App-initiated navigation lands on the destination's root

    /// Being SENT to a tab is not the same as tapping back to it. A ready-hold
    /// notification must land on the Holds list, not on whatever book detail was
    /// left in that tab.
    func testNavigateToTabRoot_ClearsTheDestinationBeforeSwitching() {
        let (catalog, myBooks) = registerStacks()
        let holds = NavigationCoordinator()
        testContainer.navigationCoordinatorHub.register(holds, for: .holds)
        holds.push(.bookDetail(BookRoute(id: "stale-hold-detail")))
        catalog.push(.bookDetail(BookRoute(id: "keep-me")))
        myBooks.push(.bookDetail(BookRoute(id: "keep-me-too")))

        testContainer.navigateToTabRoot(.holds)

        XCTAssertEqual(holds.path.count, 0, "The destination must be at its root when the patron arrives")
        XCTAssertEqual(catalog.path.count, 1, "Other tabs keep their place")
        XCTAssertEqual(myBooks.path.count, 1)
    }

    /// Being sent to the tab you are already on is a pop the patron watches
    /// happen, so it animates; arriving from elsewhere is hidden by the tab
    /// transition and stays instant. An unknown current tab is a fresh arrival.
    func testShouldAnimateArrival_OnlyWhenAlreadyOnTheDestination() {
        XCTAssertTrue(AppContainer.shouldAnimateArrival(currentTab: .holds, destination: .holds))
        XCTAssertFalse(AppContainer.shouldAnimateArrival(currentTab: .catalog, destination: .holds))
        XCTAssertFalse(AppContainer.shouldAnimateArrival(currentTab: nil, destination: .holds),
                       "No known current tab is a fresh arrival, not a pop the patron is watching")
    }

    // MARK: - Account switch must reach every tab

    /// A host registered without a tab identity must not escape a whole-app
    /// sweep. Unreachable in production today — all four hosts pass a real tab —
    /// but `NavigationHostView.tab` is deliberately optional, and a stack the
    /// sweep cannot reach is exactly the stale-content defect it exists for.
    func testAccountSwitchCleanup_ReachesATablessRegistration() {
        let hub = testContainer.navigationCoordinatorHub
        let tabless = NavigationCoordinator()
        hub.register(tabless, for: nil)
        tabless.push(.bookDetail(BookRoute(id: "old-library-book")))

        AppContainer.popAllToRootForAccountSwitch(hub: hub)

        XCTAssertEqual(tabless.path.count, 0,
                       "A stack with no tab identity must still be cleared on a library switch")
    }

    /// …and a tab-registered stack must be swept exactly once, not twice, when
    /// it is also the most recent registration.
    func testAccountSwitchCleanup_DoesNotDoubleCountTheFallback() {
        let hub = testContainer.navigationCoordinatorHub
        let catalog = NavigationCoordinator()
        hub.register(catalog, for: .catalog)   // also becomes `lastRegistered`
        catalog.push(.bookDetail(BookRoute(id: "a")))
        catalog.push(.bookDetail(BookRoute(id: "b")))

        AppContainer.popAllToRootForAccountSwitch(hub: hub)

        XCTAssertEqual(catalog.path.count, 0)
        XCTAssertEqual(hub.allRegisteredCoordinators().count, 1,
                       "A stack registered under a tab must not also appear as the fallback")
    }

    /// Now that tabs keep their stacks, a library switch has to clear ALL of
    /// them. Previously the account-switch cleanup only had to pop the visible
    /// tab, because leaving a tab had already reset it — remove the reset and
    /// the other tabs would still be showing the previous library's books.
    func testAccountSwitchCleanup_PopsEveryTabNotJustTheVisibleOne() {
        let (catalog, myBooks) = registerStacks()
        let holds = NavigationCoordinator()
        testContainer.navigationCoordinatorHub.register(holds, for: .holds)
        catalog.push(.bookDetail(BookRoute(id: "old-library-book")))
        myBooks.push(.bookDetail(BookRoute(id: "old-library-loan")))
        holds.push(.bookDetail(BookRoute(id: "old-library-hold")))

        AppContainer.popAllToRootForAccountSwitch(hub: testContainer.navigationCoordinatorHub)

        XCTAssertEqual(catalog.path.count, 0)
        XCTAssertEqual(myBooks.path.count, 0, "A tab the patron cannot see still holds the old library's content")
        XCTAssertEqual(holds.path.count, 0)
    }
}

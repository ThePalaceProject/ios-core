//
//  NavigationCoordinatorHubTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

/// PP-5022 — the hub must answer "which navigation stack is on screen", not
/// "which stack appeared most recently".
///
/// The defect: the hub held ONE global `weak var coordinator` that every tab's
/// `NavigationHostView` overwrote from `.onAppear`. Four sibling `NavigationStack`s
/// write it, so the winner is an ordering accident — an offscreen tab's root
/// re-appearing (which `handleTabSelectionChange`'s pop-to-root provokes) leaves
/// the pointer aimed at a stack the patron cannot see. Every reader open then
/// pushes onto that stack: `EPUBReaderView.onAppear` fires, nothing appears, and
/// the Read button looks dead until the app is relaunched.
@MainActor
final class NavigationCoordinatorHubTests: XCTestCase {

    private var hub: NavigationCoordinatorHub!
    private var routerHub: AppTabRouterHub!
    private var router: AppTabRouter!

    override func setUp() {
        super.setUp()
        routerHub = AppTabRouterHub()
        router = AppTabRouter()
        routerHub.router = router
        hub = NavigationCoordinatorHub(tabRouterHub: routerHub)
    }

    override func tearDown() {
        hub = nil
        routerHub = nil
        router = nil
        super.tearDown()
    }

    // MARK: - The regression

    /// The exact PP-5022 shape: My Books is on screen, but the Catalog stack
    /// registered LAST (its root re-appeared offscreen when the tab switch popped
    /// it to root). The hub must still hand back My Books' stack.
    func testCoordinator_WhenAnotherTabsStackRegisteredLast_StillResolvesTheSelectedTab() {
        let myBooks = NavigationCoordinator()
        let catalog = NavigationCoordinator()
        router.selected = .myBooks

        hub.register(myBooks, for: .myBooks)
        hub.register(catalog, for: .catalog)   // the late offscreen appearance

        XCTAssertIdentical(hub.coordinator, myBooks,
                      "The visible tab's stack must win over the most recent registration")
    }

    /// The push must land on the visible stack — asserted through the path, which
    /// is what the patron actually sees change.
    func testCoordinator_PushLandsOnTheVisibleStack_NotTheOffscreenOne() {
        let myBooks = NavigationCoordinator()
        let catalog = NavigationCoordinator()
        router.selected = .myBooks
        hub.register(myBooks, for: .myBooks)
        hub.register(catalog, for: .catalog)

        hub.coordinator?.push(.epub(BookRoute(id: "book-1")))

        XCTAssertEqual(myBooks.path.count, 1, "Reader route must be pushed on the visible stack")
        XCTAssertEqual(catalog.path.count, 0, "Offscreen stack must not receive the reader route")
    }

    /// Switching tabs re-targets the hub with no re-registration — the registry is
    /// keyed by tab, so selection alone decides.
    func testCoordinator_FollowsTabSelection() {
        let myBooks = NavigationCoordinator()
        let catalog = NavigationCoordinator()
        hub.register(myBooks, for: .myBooks)
        hub.register(catalog, for: .catalog)

        router.selected = .catalog
        XCTAssertIdentical(hub.coordinator, catalog)
        router.selected = .myBooks
        XCTAssertIdentical(hub.coordinator, myBooks)
    }

    // MARK: - Unresolvable cases

    /// A selected tab with no stack yet resolves to nil rather than to some other
    /// tab's stack. Callers have a visible fallback (a modal present, or an
    /// "unable to open" alert); silently pushing onto the wrong tab is the defect.
    func testCoordinator_SelectedTabHasNoRegisteredStack_ReturnsNil() {
        let catalog = NavigationCoordinator()
        hub.register(catalog, for: .catalog)
        router.selected = .holds

        XCTAssertNil(hub.coordinator,
                     "An unregistered selected tab must not fall through to another tab's stack")
    }

    /// No router (tests, previews, a backgrounded host) — nothing to resolve
    /// against, so the hub degrades to the LAST registration rather than to nil.
    /// Asserted with two registrations so "last" is distinguishable from "any".
    func testCoordinator_WithNoRouter_FallsBackToTheLastRegistration() {
        let catalog = NavigationCoordinator()
        let holds = NavigationCoordinator()
        let hub = NavigationCoordinatorHub(tabRouterHub: nil)
        hub.register(catalog, for: .catalog)
        hub.register(holds, for: .holds)

        XCTAssertIdentical(hub.coordinator, holds,
                           "With no tab to resolve, the most recent registration is the best guess")
        XCTAssertIdentical(hub.coordinator(for: .catalog), catalog,
                           "The by-tab registry stays intact even when resolution cannot use it")
    }

    /// A host with no tab identity (not one of the four tab stacks) still
    /// registers as the fallback.
    func testRegister_WithNoTab_ProvidesFallbackOnly() {
        let orphan = NavigationCoordinator()
        let catalog = NavigationCoordinator()
        hub.register(catalog, for: .catalog)
        hub.register(orphan, for: nil)
        router.selected = .catalog

        XCTAssertIdentical(hub.coordinator, catalog, "A tabless registration must not hijack a tab")
        XCTAssertNil(hub.coordinator(for: .myBooks), "A tabless registration claims no tab slot")
    }

    // MARK: - Lifetime

    /// The hub must not keep a dead stack alive — a strong registry would resurrect
    /// exactly the stale-target defect after a host is torn down.
    func testRegister_DoesNotRetainTheCoordinator() {
        router.selected = .catalog
        do {
            let catalog = NavigationCoordinator()
            hub.register(catalog, for: .catalog)
            XCTAssertNotNil(hub.coordinator)
        }
        XCTAssertNil(hub.coordinator(for: .catalog),
                     "Registry must hold coordinators weakly")
    }

    /// Re-registering a tab (its root re-appearing after a pop) replaces the slot
    /// rather than stacking a second entry.
    func testRegister_SameTabTwice_ReplacesTheRegistration() {
        let first = NavigationCoordinator()
        let second = NavigationCoordinator()
        router.selected = .settings
        hub.register(first, for: .settings)
        hub.register(second, for: .settings)

        XCTAssertIdentical(hub.coordinator, second)
    }

    // MARK: - Outgoing-tab lookup (tab-switch pop-to-root)

    func testCoordinatorForTab_ResolvesAStackThatIsNotSelected() {
        let catalog = NavigationCoordinator()
        hub.register(catalog, for: .catalog)
        router.selected = .myBooks

        XCTAssertIdentical(hub.coordinator(for: .catalog), catalog,
                      "Popping the tab being left needs an explicit by-tab lookup")
    }

    // MARK: - Router hub's current-tab resolution

    /// A deep link that arrives while the router is deallocated parks the tab in
    /// `pendingTab`; the hub must resolve against that rather than reporting the
    /// stale default.
    func testCurrentTab_WithNoRouter_UsesPendingTab() {
        let orphanHub = AppTabRouterHub()
        orphanHub.navigate(to: .holds)
        XCTAssertEqual(orphanHub.currentTab, .holds,
                       "A deep link parked in pendingTab is the tab the patron is landing on")

        // Once a router attaches and the pending selection is applied, the
        // answer must come from the router and stay the same — not revert to
        // the router's default.
        let attached = AppTabRouter()
        orphanHub.router = attached
        orphanHub.applyPending()
        XCTAssertEqual(attached.selected, .holds)
        XCTAssertEqual(orphanHub.currentTab, .holds)
    }

    func testCurrentTab_PrefersTheLiveRouterOverPending() {
        routerHub.navigate(to: .holds)   // router is live, so this sets it directly
        router.selected = .settings      // the patron then moves on

        XCTAssertEqual(routerHub.currentTab, .settings,
                       "The live router is the truth; a pending value must never shadow it")
    }
}

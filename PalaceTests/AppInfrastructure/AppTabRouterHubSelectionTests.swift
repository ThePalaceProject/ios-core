//
//  AppTabRouterHubSelectionTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace

/// PP-5473 — screens learn about tab switches from the tab router hub, which
/// reports each change of the registered router's selection once.
@MainActor
final class AppTabRouterHubSelectionTests: XCTestCase {

    private var cancellables = Set<AnyCancellable>()

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    private func record(_ hub: AppTabRouterHub) -> TabRecorder {
        let recorder = TabRecorder()
        hub.selectionChanges.sink { recorder.tabs.append($0) }.store(in: &cancellables)
        return recorder
    }

    func testSelectionChange_PublishesTheNewTab() {
        let hub = AppTabRouterHub()
        let router = AppTabRouter()
        hub.router = router
        let recorder = record(hub)

        router.selected = .myBooks
        router.selected = .settings

        XCTAssertEqual(recorder.tabs, [.myBooks, .settings])
    }

    /// Registering a router is not a tab switch, so the catalog keeps an open
    /// search when the tab host reappears.
    func testRegisteringARouter_PublishesNothing() {
        let hub = AppTabRouterHub()
        let recorder = record(hub)

        hub.router = AppTabRouter()

        XCTAssertEqual(recorder.tabs, [])
    }

    func testReselectingTheCurrentTab_PublishesNothing() {
        let hub = AppTabRouterHub()
        let router = AppTabRouter()
        hub.router = router
        let recorder = record(hub)

        router.selected = .catalog

        XCTAssertEqual(recorder.tabs, [])
    }

    /// A pending deep-link tab applied on reappear is a real switch.
    func testApplyingAPendingTab_PublishesIt() {
        let hub = AppTabRouterHub()
        hub.navigate(to: .holds)
        let router = AppTabRouter()
        hub.router = router
        let recorder = record(hub)

        hub.applyPending()

        XCTAssertEqual(recorder.tabs, [.holds])
    }

    /// After the tab host rebuilds, only the router it registered speaks for it.
    func testReplacedRouter_StopsPublishingTheOldRoutersChanges() {
        let hub = AppTabRouterHub()
        let oldRouter = AppTabRouter()
        hub.router = oldRouter
        let newRouter = AppTabRouter()
        hub.router = newRouter
        let recorder = record(hub)

        oldRouter.selected = .myBooks
        newRouter.selected = .holds

        XCTAssertEqual(recorder.tabs, [.holds])
    }
}

@MainActor
private final class TabRecorder {
    var tabs: [AppTab] = []
}

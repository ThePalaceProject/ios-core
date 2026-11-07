//
//  CatalogSearchAnnouncerWiringTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace

/// PP-5473 — screens signal transitions on the container's announcement center,
/// so search announcements must go through that same center to wait for them.
@MainActor
final class CatalogSearchAnnouncerWiringTests: XCTestCase {

    func testSearchViewModel_AnnouncesThroughTheContainersCenter() {
        let container = makeTestAppContainer(bookRegistry: TPPBookRegistryMock())

        let viewModel = CatalogSearchView.makeViewModel(
            repository: container.catalogRepository,
            baseURL: { nil },
            appContainer: container
        )

        XCTAssertTrue(viewModel.announcements === container.accessibilityAnnouncer)
    }
}

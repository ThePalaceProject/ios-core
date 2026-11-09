//
//  BookCellModelConnectivityTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
@testable import Palace
import PalaceBookModel

/// PP-5473 — a list cell clears its own spinner when connectivity comes back,
/// following the reachability it was built with.
@MainActor
final class BookCellModelConnectivityTests: XCTestCase {

    func testReconnecting_ClearsTheCellsSpinner() async throws {
        let container = makeTestAppContainer()
        let reachability = MockReachability(initiallyConnected: false)
        let book = try XCTUnwrap(TPPBook(dictionary: [
            "acquisitions": [TPPFake.genericAcquisition.dictionaryRepresentation()],
            "title": "Connectivity",
            "categories": ["Fiction"],
            "id": "cell-connectivity",
            "updated": "2024-01-01T00:00:00Z"
        ]))
        let registry = TPPBookRegistryMock()
        registry.addBook(book, state: .downloadNeeded)
        let model = BookCellModel(
            book: book,
            imageCache: MockImageCache(),
            bookRegistry: registry,
            downloadCenter: container.downloadCenter,
            accountsManager: container.accountsManager,
            samplePreviewManager: container.samplePreviewManager,
            readerService: container.readerService,
            reachability: reachability
        )
        await drainMainQueueAsync()
        model.isLoading = true

        reachability.simulate(connected: true)
        await drainMainQueueAsync()
        await drainMainQueueAsync()

        XCTAssertFalse(model.isLoading)
    }
}

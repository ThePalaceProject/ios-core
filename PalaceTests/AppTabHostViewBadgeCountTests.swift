//
//  AppTabHostViewBadgeCountTests.swift
//  PalaceTests
//
//  Pins AppTabHostView's badge-count helpers, extracted from inline
//  closures inside `updateHoldsBadge()` so they can be exercised directly.
//

import XCTest
@testable import Palace

@MainActor
final class AppTabHostViewBadgeCountTests: XCTestCase {

    // MARK: - computeReadyCount

    func test_computeReadyCount_emptyArray_returnsZero() {
        XCTAssertEqual(AppTabHostView.computeReadyCount(books: []), 0)
    }

    func test_computeReadyCount_oneReadyBook_returnsOne() {
        let book = TPPBookMocker.snapshotReadyBook()
        XCTAssertEqual(AppTabHostView.computeReadyCount(books: [book]), 1)
    }

    func test_computeReadyCount_threeReadyBooks_returnsThree() {
        let books = (0..<3).map { idx in
            TPPBookMocker.snapshotReadyBook(
                identifier: "ready-\(idx)",
                title: "Ready \(idx)",
                author: "Author \(idx)"
            )
        }
        XCTAssertEqual(AppTabHostView.computeReadyCount(books: books), 3)
    }

    /// Reserved books (still in the hold queue) must NOT be counted as ready.
    func test_computeReadyCount_reservedBooksOnly_returnsZero() {
        let books = (0..<3).map { idx in
            TPPBookMocker.snapshotReservedBook(
                identifier: "reserved-\(idx)",
                title: "Reserved \(idx)",
                author: "Author \(idx)",
                holdPosition: UInt(idx + 1)
            )
        }
        XCTAssertEqual(AppTabHostView.computeReadyCount(books: books), 0)
    }

    /// Mixed input: reserved books filter out, ready books are counted.
    /// Counts must accumulate upward (2, not -2).
    func test_computeReadyCount_mixedReservedAndReady_returnsOnlyReadyCount() {
        let ready = (0..<2).map { idx in
            TPPBookMocker.snapshotReadyBook(
                identifier: "ready-\(idx)",
                title: "R\(idx)",
                author: "A\(idx)"
            )
        }
        let reserved = (0..<3).map { idx in
            TPPBookMocker.snapshotReservedBook(
                identifier: "res-\(idx)",
                title: "Res\(idx)",
                author: "Ax\(idx)",
                holdPosition: UInt(idx + 1)
            )
        }
        XCTAssertEqual(AppTabHostView.computeReadyCount(books: ready + reserved), 2)
    }

    // MARK: - computeReservedCount

    func test_computeReservedCount_emptyArray_returnsZero() {
        XCTAssertEqual(AppTabHostView.computeReservedCount(books: []), 0)
    }

    func test_computeReservedCount_twoReservedBooks_returnsTwo() {
        let books = (0..<2).map { idx in
            TPPBookMocker.snapshotReservedBook(
                identifier: "res-\(idx)",
                title: "Res \(idx)",
                author: "Author \(idx)",
                holdPosition: UInt(idx + 1)
            )
        }
        XCTAssertEqual(AppTabHostView.computeReservedCount(books: books), 2)
    }

    /// Ready books must NOT be counted as reserved. Guards against
    /// swapping the `reserved:` and `ready:` callbacks.
    func test_computeReservedCount_readyBooksOnly_returnsZero() {
        let books = (0..<2).map { idx in
            TPPBookMocker.snapshotReadyBook(
                identifier: "ready-\(idx)",
                title: "Ready \(idx)",
                author: "Author \(idx)"
            )
        }
        XCTAssertEqual(AppTabHostView.computeReservedCount(books: books), 0)
    }

    // MARK: - shouldUpdateBadge

    /// The badge updates only on `.loaded` or `.synced`; any other predicate
    /// skips work it should do or does work it should skip.
    func test_shouldUpdateBadge_loadedOrSynced_returnsTrue() {
        XCTAssertTrue(AppTabHostView.shouldUpdateBadge(for: .loaded))
        XCTAssertTrue(AppTabHostView.shouldUpdateBadge(for: .synced))
    }

    func test_shouldUpdateBadge_unloadedOrLoadingOrSyncing_returnsFalse() {
        XCTAssertFalse(AppTabHostView.shouldUpdateBadge(for: .unloaded))
        XCTAssertFalse(AppTabHostView.shouldUpdateBadge(for: .loading))
        XCTAssertFalse(AppTabHostView.shouldUpdateBadge(for: .syncing))
    }
}

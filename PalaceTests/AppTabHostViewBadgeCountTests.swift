//
//  AppTabHostViewBadgeCountTests.swift
//  PalaceTests
//
//  F-013 follow-up: kills the 6 surviving mutants in AppTabHostView's
//  badge-count update path. Previously these counts were inline closures
//  inside `updateHoldsBadge()` and could not be exercised by tests.
//

import XCTest
@testable import Palace

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
    /// Kills the mutant where the `ready:` callback is replaced by a no-op.
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
    /// Kills the `+= 1` → `-= 1` mutant directly: a `-=` would yield -2 not 2.
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

    /// Ready books must NOT be counted as reserved. Kills the mutant where
    /// the `reserved:` callback is replaced by the `ready:` callback.
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

    /// Kills the mutants on `state == .loaded` and `state == .synced` —
    /// flipping `==` to `!=` or `||` to `&&` makes the badge skip work
    /// when it should run, or run when it should skip.
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

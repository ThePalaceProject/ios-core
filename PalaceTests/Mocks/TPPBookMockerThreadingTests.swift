//
//  TPPBookMockerThreadingTests.swift
//  PalaceTests
//
//  `TPPBookMocker` is called from nonisolated async fixtures, which run on the
//  cooperative pool. `TPPBook.init` schedules its own `coverImage` and
//  `thumbnailImage` writes on the main queue, and `@Published` storage is not
//  thread-safe, so the mocker's writes to the same properties must also run on main.
//

import XCTest
@testable import Palace
import PalaceBookModel

@MainActor
final class TPPBookMockerThreadingTests: XCTestCase {

    /// A book built off main while the main queue is idle races its own
    /// `TPPBook.init` cover writes; the race over-releases the cover, and the
    /// host crashes when the book and its cache are freed.
    func testMockBook_BuiltOffMain_KeepsTheCoverAliveUntilTheBookIsFreed() async {
        for round in 0..<60 {
            var books: [TPPBook] = []
            for index in 0..<40 {
                let book = await Task.detached {
                    TPPBookMocker.mockBook(
                        identifier: "threading-\(round)-\(index)",
                        title: "Book \(index)",
                        distributorType: .EpubZip
                    )
                }.value
                books.append(book)
                // Let the main-queue writes that `TPPBook.init` scheduled run.
                await Task.yield()
            }
            let cached = books.filter { $0.imageCache.get(for: $0.identifier) != nil }
            XCTAssertEqual(cached.count, books.count, "round \(round): every book's cache holds its cover")
            // Dropping the books frees each cover through its last owner.
            books.removeAll()
            await Task.yield()
        }
    }
}

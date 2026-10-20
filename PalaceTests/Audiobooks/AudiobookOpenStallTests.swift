//
//  AudiobookOpenStallTests.swift
//  PalaceTests
//
//  An open still running at its stall deadline is reported with the step it
//  reached; iOS reports no hang, so this is the only trace of a patron left on
//  the loading spinner (PP-4973).
//

import XCTest
@testable import Palace

@MainActor
final class AudiobookOpenStallTests: AudiobookSessionOpenTestCase {

    func testOpenParkedInTheLoad_isReportedAtTheLoadingStep() async throws {
        let book = downloadedBook("book-a")
        await startParkedOpen(book)

        stallChecks.fireAll()

        XCTAssertEqual(stallChecks.reported.map(\.step), [.loading])
        XCTAssertEqual(stallChecks.reported.first?.bookId, book.identifier)
        XCTAssertEqual(stallChecks.reported.first?.origin, .patron)
        await finishOpens()
    }

    func testOpenHeldInTheSignInCheck_isReportedAtThatStep() async throws {
        account._setState(.detailsLoading)
        let book = downloadedBook("book-a")
        startOpen(book)
        await awaitConditionAsync { !self.stallChecks.pending.isEmpty }

        stallChecks.fireAll()

        XCTAssertEqual(stallChecks.reported.map(\.step), [.checkingAccess])
        account._setState(.detailsLoaded(loadedDetails))
        await awaitConditionAsync { self.adapters.count == 1 }
        await finishOpens()
    }

    func testOpenThatFinished_isNotReported() async throws {
        let book = downloadedBook("book-a")
        await startParkedOpen(book)
        adapters[0].complete(with: .failure(.manifestFetchFailed))
        await awaitConditionAsync { self.openResults[book.identifier] != nil }

        stallChecks.fireAll()

        XCTAssertEqual(stallChecks.reported, [])
    }

    /// A recovery re-open replaces the open it recovers; only the current one
    /// can be reported.
    func testRecoveryReopen_reportsOnlyTheCurrentOpen() async throws {
        let book = downloadedBook("book-a")
        await startParkedOpen(book)
        failFirstPlay()
        await awaitConditionAsync { self.adapters.count == 2 && self.adapters[1].resolveCallCount == 1 }

        stallChecks.fireAll()

        XCTAssertEqual(stallChecks.reported.map(\.origin), [.reopen(.coldLoad)])
        await finishOpens()
    }
}

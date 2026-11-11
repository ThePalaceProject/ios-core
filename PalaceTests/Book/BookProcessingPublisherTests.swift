//
//  BookProcessingPublisherTests.swift
//  PalaceTests
//
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace
import PalaceBookRegistry

/// PP-5473 — book detail and the list cell show a book's borrow spinner from
/// the registry's processing changes, so each `setProcessing` call must reach
/// them, on main, for that book only.
@MainActor
final class BookProcessingPublisherTests: PalaceWiringTestCase {

    private func makeRegistry() -> TPPBookRegistry {
        TPPBookRegistry(accountsManager: makeFreshAccountsManager(), imageLoader: MockImageLoader())
    }

    func testSetProcessing_PublishesEachChangeOnMain() async {
        let registry = makeRegistry()
        let recorder = ProcessingRecorder()
        let delivered = expectation(description: "two changes")
        delivered.expectedFulfillmentCount = 2
        registry.bookProcessingPublisher
            .sink { change in
                recorder.append(change, onMain: Thread.isMainThread)
                delivered.fulfill()
            }
            .store(in: &cancellables)

        registry.setProcessing(true, for: "book-1")
        registry.setProcessing(false, for: "book-1")

        await fulfillment(of: [delivered], timeout: 5) // STARVE-001-OK: waits on two main-queue sends the store submits synchronously; no other async work
        XCTAssertEqual(recorder.changes, [
            BookProcessingChange(bookIdentifier: "book-1", isProcessing: true),
            BookProcessingChange(bookIdentifier: "book-1", isProcessing: false)
        ])
        XCTAssertEqual(recorder.mainThreadFlags, [true, true])
    }
}

private final class ProcessingRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [BookProcessingChange] = []
    private var flags: [Bool] = []
    var changes: [BookProcessingChange] { lock.withLock { recorded } }
    var mainThreadFlags: [Bool] { lock.withLock { flags } }
    func append(_ change: BookProcessingChange, onMain: Bool) {
        lock.withLock {
            recorded.append(change)
            flags.append(onMain)
        }
    }
}

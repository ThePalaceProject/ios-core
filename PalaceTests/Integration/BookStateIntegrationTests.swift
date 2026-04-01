//
//  BookStateIntegrationTests.swift
//  PalaceTests
//
//  Integration tests for book state transitions across the book registry,
//  Combine publishers, and concurrent mutation scenarios. Uses the
//  TPPBookRegistryMock for deterministic state management.
//
//  Copyright 2026 The Palace Project. All rights reserved.
//

import XCTest
import Combine
@testable import Palace

// SRS: REQ-BOOKSTATE-001 — Book state transition integration

final class BookStateIntegrationTests: XCTestCase {

    private var bookRegistry: TPPBookRegistryMock!
    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        bookRegistry = TPPBookRegistryMock()
        cancellables = []
    }

    override func tearDown() {
        cancellables = nil
        bookRegistry = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeTestBook(identifier: String, title: String = "Test Book") -> TPPBook {
        return TPPBook(dictionary: [
            "acquisitions": [TPPFake.genericAcquisition.dictionaryRepresentation()],
            "title": title,
            "categories": ["Fiction"],
            "id": identifier,
            "updated": "2024-01-01T00:00:00Z"
        ])!
    }

    // MARK: - State Transitions

    // SRS: REQ-BOOKSTATE-002 — Unregistered -> DownloadNeeded -> Downloading -> Downloaded
    func testBookStateTransition_FullDownloadLifecycle() {
        // Given
        let book = makeTestBook(identifier: "lifecycle-book", title: "Lifecycle Book")

        // Initial state: unregistered
        XCTAssertEqual(bookRegistry.state(for: book.identifier), .unregistered,
                       "Book should start as unregistered")

        // When: Add book (borrow)
        bookRegistry.addBook(book, state: .downloadNeeded)
        XCTAssertEqual(bookRegistry.state(for: book.identifier), .downloadNeeded,
                       "Book should be downloadNeeded after borrow")

        // When: Start download
        bookRegistry.setState(.downloading, for: book.identifier)
        XCTAssertEqual(bookRegistry.state(for: book.identifier), .downloading,
                       "Book should be downloading")

        // When: Download completes
        bookRegistry.setState(.downloadSuccessful, for: book.identifier)
        XCTAssertEqual(bookRegistry.state(for: book.identifier), .downloadSuccessful,
                       "Book should be downloadSuccessful after completion")
    }

    // SRS: REQ-BOOKSTATE-003 — Borrow adds book to registry
    func testBookBorrow_UpdatesRegistry() {
        // Given
        let book = makeTestBook(identifier: "borrow-book", title: "Borrowed Book")

        // When
        bookRegistry.addBook(book, state: .downloadNeeded)

        // Then
        XCTAssertNotNil(bookRegistry.book(forIdentifier: "borrow-book"),
                        "Borrowed book should be in registry")
        XCTAssertEqual(bookRegistry.book(forIdentifier: "borrow-book")?.title, "Borrowed Book")
        XCTAssertEqual(bookRegistry.registry.count, 1)
    }

    // SRS: REQ-BOOKSTATE-004 — Return removes book from registry
    func testBookReturn_RemovesFromRegistry() {
        // Given
        let book = makeTestBook(identifier: "return-book")
        bookRegistry.addBook(book, state: .downloadSuccessful)
        XCTAssertNotNil(bookRegistry.book(forIdentifier: "return-book"),
                        "Book should exist before return")

        // When
        bookRegistry.removeBook(forIdentifier: "return-book")

        // Then
        XCTAssertNil(bookRegistry.book(forIdentifier: "return-book"),
                     "Book should be removed after return")
        XCTAssertEqual(bookRegistry.registry.count, 0,
                       "Registry should be empty after return")
    }

    // SRS: REQ-BOOKSTATE-005 — State change emits via Combine publisher
    func testBookStateChange_PublishesViaCombine() {
        // Given
        let book = makeTestBook(identifier: "combine-book")
        bookRegistry.addBook(book, state: .downloadNeeded)

        let expectation = expectation(description: "State change published")
        var receivedStates: [(String, TPPBookState)] = []

        bookRegistry.bookStatePublisher
            .dropFirst() // Skip initial/add emission
            .sink { (identifier, state) in
                receivedStates.append((identifier, state))
                if state == .downloadSuccessful {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        // When
        bookRegistry.setState(.downloading, for: book.identifier)
        bookRegistry.setState(.downloadSuccessful, for: book.identifier)

        // Then
        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(receivedStates.count, 2,
                       "Should receive 2 state change events")
        XCTAssertEqual(receivedStates[0].1, .downloading)
        XCTAssertEqual(receivedStates[1].1, .downloadSuccessful)
    }

    // SRS: REQ-BOOKSTATE-006 — Concurrent state changes don't corrupt registry
    func testConcurrentStateChanges_DoNotCorruptRegistry() {
        // Given: Add multiple books
        let bookCount = 20
        var books: [TPPBook] = []
        for i in 0..<bookCount {
            let book = makeTestBook(identifier: "concurrent-\(i)", title: "Book \(i)")
            books.append(book)
            bookRegistry.addBook(book, state: .downloadNeeded)
        }

        XCTAssertEqual(bookRegistry.registry.count, bookCount,
                       "All books should be registered")

        // When: Modify states concurrently via DispatchQueue
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)

        for (index, book) in books.enumerated() {
            group.enter()
            queue.async {
                // Alternate between states to stress the registry
                let targetState: TPPBookState = index % 2 == 0 ? .downloading : .downloadSuccessful
                self.bookRegistry.setState(targetState, for: book.identifier)
                group.leave()
            }
        }

        group.wait()

        // Then: Registry should still have all books and no corruption
        XCTAssertEqual(bookRegistry.registry.count, bookCount,
                       "All \(bookCount) books should still be in registry after concurrent mutations")

        for (index, book) in books.enumerated() {
            let state = bookRegistry.state(for: book.identifier)
            let expectedState: TPPBookState = index % 2 == 0 ? .downloading : .downloadSuccessful
            XCTAssertEqual(state, expectedState,
                           "Book \(index) should have expected state after concurrent update")
        }
    }

    // SRS: REQ-BOOKSTATE-007 — Book with holds shows correct availability
    func testBookWithHolds_ShowsHoldingState() {
        // Given
        let book = makeTestBook(identifier: "held-book", title: "Held Book")

        // When: Add as a held book
        bookRegistry.addBook(book, state: .holding)

        // Then
        XCTAssertEqual(bookRegistry.state(for: book.identifier), .holding,
                       "Book should be in holding state")
        XCTAssertTrue(bookRegistry.heldBooks.contains(where: { $0.identifier == "held-book" }),
                      "Book should appear in heldBooks list")
        XCTAssertEqual(bookRegistry.heldBooks.count, 1,
                       "Should have exactly 1 held book")
    }

    // SRS: REQ-BOOKSTATE-008 — Registry publishes on book add
    func testRegistryPublisher_EmitsOnBookAdd() {
        // Given
        let expectation = expectation(description: "Registry publisher emits")
        var receivedRegistry: [String: TPPBookRegistryRecord]?

        bookRegistry.registryPublisher
            .dropFirst() // Skip initial empty value
            .first()
            .sink { registry in
                receivedRegistry = registry
                expectation.fulfill()
            }
            .store(in: &cancellables)

        // When
        let book = makeTestBook(identifier: "publish-book", title: "Published Book")
        bookRegistry.addBook(book, state: .downloadNeeded)

        // Then
        wait(for: [expectation], timeout: 1.0)
        XCTAssertNotNil(receivedRegistry, "Should receive registry update")
        XCTAssertEqual(receivedRegistry?.count, 1, "Registry should have 1 book")
        XCTAssertNotNil(receivedRegistry?["publish-book"],
                        "Registry should contain the added book")
    }

    // SRS: REQ-BOOKSTATE-009 — Download failure transitions to error state
    func testBookDownloadFailure_UpdatesStateToDownloadFailed() {
        // Given
        let book = makeTestBook(identifier: "fail-book", title: "Failing Book")
        bookRegistry.addBook(book, state: .downloadNeeded)
        bookRegistry.setState(.downloading, for: book.identifier)

        let expectation = expectation(description: "Failure state published")

        bookRegistry.bookStatePublisher
            .filter { $0.0 == book.identifier && $0.1 == .downloadFailed }
            .first()
            .sink { (identifier, state) in
                expectation.fulfill()
            }
            .store(in: &cancellables)

        // When: Simulate download failure
        bookRegistry.setState(.downloadFailed, for: book.identifier)

        // Then
        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(bookRegistry.state(for: book.identifier), .downloadFailed,
                       "Book state should be downloadFailed after failure")
    }
}

//
//  CollectionDetailViewModelTests.swift
//  PalaceTests
//
//  Tests for CollectionDetailViewModel collection detail management.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import XCTest
@testable import Palace

@MainActor
final class CollectionDetailViewModelTests: XCTestCase {

    private var sut: CollectionDetailViewModel!
    private var mockService: MockBookCollectionService!
    private var mockRegistry: MockBookRegistryForCollections!
    private var cancellables: Set<AnyCancellable>!
    private var testCollection: BookCollection!

    override func setUp() {
        super.setUp()
        mockService = MockBookCollectionService()
        mockRegistry = MockBookRegistryForCollections()
        cancellables = []

        testCollection = mockService.createCollection(name: "Test Collection", description: "A test")
    }

    override func tearDown() {
        sut = nil
        mockService = nil
        mockRegistry = nil
        cancellables = nil
        testCollection = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeSUT(collection: BookCollection? = nil) -> CollectionDetailViewModel {
        CollectionDetailViewModel(
            collection: collection ?? testCollection,
            collectionService: mockService,
            bookRegistry: mockRegistry
        )
    }

    // MARK: - Initial State

    func testInitialState_LoadsCollectionBooks() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        mockRegistry.stubbedBooks[book.identifier] = book
        mockService.addBook(withID: book.identifier, toCollectionWithID: testCollection.id)

        // Re-fetch the updated collection
        let updated = mockService.collection(withID: testCollection.id)!
        sut = makeSUT(collection: updated)

        XCTAssertEqual(sut.books.count, 1)
        XCTAssertEqual(sut.books.first?.identifier, book.identifier)
    }

    func testInitialState_EmptyCollection_HasNoBooks() {
        sut = makeSUT()
        XCTAssertTrue(sut.books.isEmpty)
    }

    func testInitialState_CollectionNameIsSet() {
        sut = makeSUT()
        XCTAssertEqual(sut.collection.name, "Test Collection")
    }

    // MARK: - Remove Book

    func testRemoveBook_RemovesBookAndUpdatesService() {
        let book = TPPBookMocker.mockBook(distributorType: .EpubZip)
        mockRegistry.stubbedBooks[book.identifier] = book
        mockService.addBook(withID: book.identifier, toCollectionWithID: testCollection.id)

        let updated = mockService.collection(withID: testCollection.id)!
        sut = makeSUT(collection: updated)

        XCTAssertEqual(sut.books.count, 1)

        sut.removeBook(at: IndexSet(integer: 0))

        let expectation = expectation(description: "Books updated")
        sut.$books
            .dropFirst()
            .first { $0.isEmpty }
            .sink { _ in expectation.fulfill() }
            .store(in: &cancellables)

        wait(for: [expectation], timeout: 1.0)

        let serviceCollection = mockService.collection(withID: testCollection.id)
        XCTAssertFalse(serviceCollection?.bookIDs.contains(book.identifier) ?? true)
    }

    func testRemoveBook_OutOfBoundsIndex_NoOp() {
        sut = makeSUT()
        // Should not crash with out of bounds index
        sut.removeBook(at: IndexSet(integer: 5))
        XCTAssertTrue(sut.books.isEmpty)
    }

    // MARK: - Move Book

    func testMoveBook_ReordersCorrectly() {
        let book1 = TPPBookMocker.mockBook(identifier: "book-1", title: "Book 1")
        let book2 = TPPBookMocker.mockBook(identifier: "book-2", title: "Book 2")
        let book3 = TPPBookMocker.mockBook(identifier: "book-3", title: "Book 3")

        mockRegistry.stubbedBooks["book-1"] = book1
        mockRegistry.stubbedBooks["book-2"] = book2
        mockRegistry.stubbedBooks["book-3"] = book3

        mockService.addBook(withID: "book-1", toCollectionWithID: testCollection.id)
        mockService.addBook(withID: "book-2", toCollectionWithID: testCollection.id)
        mockService.addBook(withID: "book-3", toCollectionWithID: testCollection.id)

        let updated = mockService.collection(withID: testCollection.id)!
        sut = makeSUT(collection: updated)

        // Move first item to end (SwiftUI style: from 0, to 3 means after last)
        sut.moveBook(from: IndexSet(integer: 0), to: 3)

        let expectation = expectation(description: "Reorder updated")
        sut.$books
            .dropFirst()
            .first()
            .sink { _ in expectation.fulfill() }
            .store(in: &cancellables)

        wait(for: [expectation], timeout: 1.0)

        let reorderedCollection = mockService.collection(withID: testCollection.id)
        XCTAssertEqual(reorderedCollection?.bookIDs, ["book-2", "book-3", "book-1"])
    }

    // MARK: - Update Name

    func testUpdateName_UpdatesCollectionName() {
        sut = makeSUT()
        sut.updateName("New Name")

        let expectation = expectation(description: "Name updated")
        sut.$collection
            .dropFirst()
            .first { $0.name == "New Name" }
            .sink { _ in expectation.fulfill() }
            .store(in: &cancellables)

        wait(for: [expectation], timeout: 1.0)

        let serviceCollection = mockService.collection(withID: testCollection.id)
        XCTAssertEqual(serviceCollection?.name, "New Name")
    }

    func testUpdateName_EmptyString_NoOp() {
        sut = makeSUT()
        sut.updateName("")

        let serviceCollection = mockService.collection(withID: testCollection.id)
        XCTAssertEqual(serviceCollection?.name, "Test Collection")
    }

    func testUpdateName_WhitespaceOnly_NoOp() {
        sut = makeSUT()
        sut.updateName("   ")

        let serviceCollection = mockService.collection(withID: testCollection.id)
        XCTAssertEqual(serviceCollection?.name, "Test Collection")
    }

    func testUpdateName_TrimsWhitespace() {
        sut = makeSUT()
        sut.updateName("  Trimmed Name  ")

        let serviceCollection = mockService.collection(withID: testCollection.id)
        XCTAssertEqual(serviceCollection?.name, "Trimmed Name")
    }

    // MARK: - Update Description

    func testUpdateDescription_UpdatesCollectionDescription() {
        sut = makeSUT()
        sut.updateDescription("A great collection")

        let expectation = expectation(description: "Description updated")
        sut.$collection
            .dropFirst()
            .first()
            .sink { _ in expectation.fulfill() }
            .store(in: &cancellables)

        wait(for: [expectation], timeout: 1.0)

        let serviceCollection = mockService.collection(withID: testCollection.id)
        XCTAssertEqual(serviceCollection?.collectionDescription, "A great collection")
    }

    func testUpdateDescription_EmptyString_ClearsDescription() {
        sut = makeSUT()
        sut.updateDescription("Something")
        sut.updateDescription("")

        let serviceCollection = mockService.collection(withID: testCollection.id)
        XCTAssertEqual(serviceCollection?.collectionDescription, "")
    }

    // MARK: - Book ID Resolution

    func testResolveBooks_ValidIDs_ReturnsBooks() {
        let book1 = TPPBookMocker.mockBook(identifier: "b1", title: "Book One")
        let book2 = TPPBookMocker.mockBook(identifier: "b2", title: "Book Two")
        mockRegistry.stubbedBooks["b1"] = book1
        mockRegistry.stubbedBooks["b2"] = book2

        mockService.addBook(withID: "b1", toCollectionWithID: testCollection.id)
        mockService.addBook(withID: "b2", toCollectionWithID: testCollection.id)

        let updated = mockService.collection(withID: testCollection.id)!
        sut = makeSUT(collection: updated)

        XCTAssertEqual(sut.books.count, 2)
    }

    func testResolveBooks_InvalidIDs_SkipsUnresolvable() {
        let book1 = TPPBookMocker.mockBook(identifier: "valid-id", title: "Valid Book")
        mockRegistry.stubbedBooks["valid-id"] = book1

        mockService.addBook(withID: "valid-id", toCollectionWithID: testCollection.id)
        mockService.addBook(withID: "invalid-id", toCollectionWithID: testCollection.id)

        let updated = mockService.collection(withID: testCollection.id)!
        sut = makeSUT(collection: updated)

        XCTAssertEqual(sut.books.count, 1)
        XCTAssertEqual(sut.books.first?.identifier, "valid-id")
    }

    func testResolveBooks_AllInvalid_ReturnsEmpty() {
        mockService.addBook(withID: "gone-1", toCollectionWithID: testCollection.id)
        mockService.addBook(withID: "gone-2", toCollectionWithID: testCollection.id)

        let updated = mockService.collection(withID: testCollection.id)!
        sut = makeSUT(collection: updated)

        XCTAssertTrue(sut.books.isEmpty)
    }

    // MARK: - Share Collection

    func testShareCollection_FormatsTextWithBookTitles() {
        let book = TPPBookMocker.mockBook(identifier: "b1", title: "Great Book")
        mockRegistry.stubbedBooks["b1"] = book
        mockService.addBook(withID: "b1", toCollectionWithID: testCollection.id)

        let updated = mockService.collection(withID: testCollection.id)!
        sut = makeSUT(collection: updated)

        let shareText = sut.shareCollection()
        XCTAssertTrue(shareText.contains("Test Collection"))
        XCTAssertTrue(shareText.contains("Great Book"))
    }

    func testShareCollection_MoreThanFiveBooks_ShowsCount() {
        for i in 1...7 {
            let book = TPPBookMocker.mockBook(identifier: "b\(i)", title: "Book \(i)")
            mockRegistry.stubbedBooks["b\(i)"] = book
            mockService.addBook(withID: "b\(i)", toCollectionWithID: testCollection.id)
        }

        let updated = mockService.collection(withID: testCollection.id)!
        sut = makeSUT(collection: updated)

        let shareText = sut.shareCollection()
        XCTAssertTrue(shareText.contains("and 2 more"))
    }

    func testShareCollection_EmptyCollection_NoBookTitles() {
        sut = makeSUT()

        let shareText = sut.shareCollection()
        XCTAssertTrue(shareText.contains("Test Collection"))
    }
}

// MARK: - Mock Book Registry

/// Minimal mock of TPPBookRegistryProvider for collection detail tests.
final class MockBookRegistryForCollections: TPPBookRegistryProvider {

    var stubbedBooks: [String: TPPBook] = [:]

    var registryPublisher: AnyPublisher<[String: TPPBookRegistryRecord], Never> {
        Just([:]).eraseToAnyPublisher()
    }

    var bookStatePublisher: AnyPublisher<(String, TPPBookState), Never> {
        Empty().eraseToAnyPublisher()
    }

    var syncStatePublisher: AnyPublisher<Bool, Never> { Just(false).eraseToAnyPublisher() }
    var isSyncing: Bool { false }
    var myBooks: [TPPBook] { [] }
    var state: TPPBookRegistry.RegistryState { .loaded }
    var registryState: TPPBookRegistry.RegistryState { .loaded }
    var heldBooks: [TPPBook] { [] }

    func sync(completion: ((_ errorDocument: [AnyHashable: Any]?, _ newBooks: Bool) -> Void)?) { completion?(nil, false) }
    func sync() {}
    func load() {}
    func updatedBookMetadata(_ book: TPPBook) -> TPPBook? { stubbedBooks[book.identifier] }

    func book(forIdentifier bookIdentifier: String?) -> TPPBook? {
        guard let id = bookIdentifier else { return nil }
        return stubbedBooks[id]
    }

    // MARK: - Unused stubs

    func coverImage(for book: TPPBook, handler: @escaping (UIImage?) -> Void) { handler(nil) }
    func setProcessing(_ processing: Bool, for bookIdentifier: String) {}
    func processing(forIdentifier bookIdentifier: String) -> Bool { false }
    func state(for bookIdentifier: String?) -> TPPBookState { .unregistered }
    func readiumBookmarks(forIdentifier identifier: String) -> [TPPReadiumBookmark] { [] }
    func setLocation(_ location: TPPBookLocation?, forIdentifier identifier: String) {}
    func location(forIdentifier identifier: String) -> TPPBookLocation? { nil }
    func add(_ bookmark: TPPReadiumBookmark, forIdentifier identifier: String) {}
    func delete(_ bookmark: TPPReadiumBookmark, forIdentifier identifier: String) {}
    func replace(_ oldBookmark: TPPReadiumBookmark, with newBookmark: TPPReadiumBookmark, forIdentifier identifier: String) {}
    func genericBookmarksForIdentifier(_ bookIdentifier: String) -> [TPPBookLocation] { [] }
    func addOrReplaceGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) {}
    func addGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) {}
    func deleteGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) {}
    func replaceGenericBookmark(_ oldLocation: TPPBookLocation, with newLocation: TPPBookLocation, forIdentifier: String) {}
    func addBook(_ book: TPPBook, location: TPPBookLocation?, state: TPPBookState, fulfillmentId: String?, readiumBookmarks: [TPPReadiumBookmark]?, genericBookmarks: [TPPBookLocation]?) {}
    func removeBook(forIdentifier bookIdentifier: String) {}
    func updateAndRemoveBook(_ book: TPPBook) {}
    func setState(_ state: TPPBookState, for bookIdentifier: String) {}
    func fulfillmentId(forIdentifier bookIdentifier: String?) -> String? { nil }
    func setFulfillmentId(_ fulfillmentId: String, for bookIdentifier: String) {}
    func with(account: String, perform block: (TPPBookRegistry) -> Void) {}
    func cachedThumbnailImage(for book: TPPBook) -> UIImage? { nil }
    func thumbnailImage(for book: TPPBook?, handler: @escaping (UIImage?) -> Void) { handler(nil) }
}

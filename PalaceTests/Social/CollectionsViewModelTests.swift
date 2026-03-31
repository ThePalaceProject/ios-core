//
//  CollectionsViewModelTests.swift
//  PalaceTests
//
//  Tests for CollectionsViewModel collection management.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import XCTest
@testable import Palace

@MainActor
final class CollectionsViewModelTests: XCTestCase {

    private var sut: CollectionsViewModel!
    private var mockService: MockBookCollectionService!
    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        mockService = MockBookCollectionService()
        sut = CollectionsViewModel(collectionService: mockService)
        cancellables = []
    }

    override func tearDown() {
        sut = nil
        mockService = nil
        cancellables = nil
        super.tearDown()
    }

    // MARK: - Initial State

    func testInitialState_LoadsCollections() {
        // MockService creates defaults on init
        XCTAssertFalse(sut.collections.isEmpty)
    }

    func testDefaultCollections_FiltersCorrectly() {
        let defaults = sut.defaultCollections
        XCTAssertTrue(defaults.allSatisfy(\.isDefault))
    }

    func testUserCollections_ExcludesDefaults() {
        mockService.createCollection(name: "My Custom List")
        // Force publisher update
        let expectation = expectation(description: "Collections update")
        sut.$collections
            .dropFirst()
            .sink { _ in expectation.fulfill() }
            .store(in: &cancellables)
        wait(for: [expectation], timeout: 1.0)
        XCTAssertTrue(sut.userCollections.contains(where: { $0.name == "My Custom List" }))
        XCTAssertFalse(sut.defaultCollections.contains(where: { $0.name == "My Custom List" }))
    }

    // MARK: - Create

    func testCreateCollection_EmptyName_NoOp() {
        let countBefore = sut.collections.count
        sut.createCollection(name: "   ")
        XCTAssertEqual(mockService.allCollections().count, countBefore)
    }

    func testCreateCollection_TrimsWhitespace() {
        sut.createCollection(name: "  Trimmed  ")
        XCTAssertTrue(mockService.allCollections().contains(where: { $0.name == "Trimmed" }))
    }

    // MARK: - Delete

    func testDeleteCollection_RemovesFromService() {
        let created = mockService.createCollection(name: "ToDelete")
        sut.deleteCollection(created)
        XCTAssertNil(mockService.collection(withID: created.id))
    }

    // MARK: - Book Management

    func testAddBook_DelegatesToService() {
        let collection = mockService.createCollection(name: "Test")
        sut.addBook("book-1", to: collection)
        let updated = mockService.collection(withID: collection.id)
        XCTAssertTrue(updated?.bookIDs.contains("book-1") ?? false)
    }

    func testRemoveBook_DelegatesToService() {
        let collection = mockService.createCollection(name: "Test")
        mockService.addBook(withID: "book-1", toCollectionWithID: collection.id)
        sut.removeBook("book-1", from: collection)
        let updated = mockService.collection(withID: collection.id)
        XCTAssertFalse(updated?.bookIDs.contains("book-1") ?? true)
    }

    // MARK: - Selection

    func testSelectCollection_UpdatesSelected() {
        let collection = mockService.createCollection(name: "Select Me")
        sut.selectCollection(collection)
        XCTAssertEqual(sut.selectedCollection?.id, collection.id)
    }
}

// MARK: - Mock Service

/// In-memory mock of BookCollectionServiceProtocol for ViewModel testing.
final class MockBookCollectionService: BookCollectionServiceProtocol {

    private let subject = CurrentValueSubject<[BookCollection], Never>([])

    var collectionsPublisher: AnyPublisher<[BookCollection], Never> {
        subject.eraseToAnyPublisher()
    }

    init() {
        ensureDefaultCollections()
    }

    func allCollections() -> [BookCollection] {
        subject.value.sorted { $0.sortOrder < $1.sortOrder }
    }

    func collection(withID id: UUID) -> BookCollection? {
        subject.value.first { $0.id == id }
    }

    @discardableResult
    func createCollection(name: String, description: String = "") -> BookCollection {
        let maxSort = subject.value.map(\.sortOrder).max() ?? -1
        let collection = BookCollection(name: name, collectionDescription: description, sortOrder: maxSort + 1)
        var list = subject.value
        list.append(collection)
        subject.send(list)
        return collection
    }

    @discardableResult
    func updateCollection(_ collection: BookCollection) -> BookCollection? {
        var list = subject.value
        guard let index = list.firstIndex(where: { $0.id == collection.id }) else { return nil }
        list[index] = collection
        subject.send(list)
        return collection
    }

    @discardableResult
    func deleteCollection(withID id: UUID) -> Bool {
        var list = subject.value
        guard let index = list.firstIndex(where: { $0.id == id }) else { return false }
        if list[index].isDefault { return false }
        list.remove(at: index)
        subject.send(list)
        return true
    }

    func addBook(withID bookID: String, toCollectionWithID collectionID: UUID) {
        var list = subject.value
        guard let index = list.firstIndex(where: { $0.id == collectionID }) else { return }
        if !list[index].bookIDs.contains(bookID) {
            list[index].bookIDs.append(bookID)
            subject.send(list)
        }
    }

    func removeBook(withID bookID: String, fromCollectionWithID collectionID: UUID) {
        var list = subject.value
        guard let index = list.firstIndex(where: { $0.id == collectionID }) else { return }
        list[index].bookIDs.removeAll { $0 == bookID }
        subject.send(list)
    }

    func reorderBooks(inCollectionWithID collectionID: UUID, fromIndex: Int, toIndex: Int) {
        var list = subject.value
        guard let index = list.firstIndex(where: { $0.id == collectionID }) else { return }
        var bookIDs = list[index].bookIDs
        guard fromIndex >= 0, fromIndex < bookIDs.count, toIndex >= 0, toIndex < bookIDs.count else { return }
        let item = bookIDs.remove(at: fromIndex)
        bookIDs.insert(item, at: toIndex)
        list[index].bookIDs = bookIDs
        subject.send(list)
    }

    func collections(containingBookID bookID: String) -> [BookCollection] {
        subject.value.filter { $0.contains(bookID: bookID) }
    }

    func ensureDefaultCollections() {
        var list = subject.value
        let existingNames = Set(list.map(\.name))
        for defaultName in BookCollection.DefaultName.allCases where !existingNames.contains(defaultName.rawValue) {
            let maxSort = list.map(\.sortOrder).max() ?? -1
            list.append(BookCollection(name: defaultName.rawValue, sortOrder: maxSort + 1))
        }
        subject.send(list)
    }
}

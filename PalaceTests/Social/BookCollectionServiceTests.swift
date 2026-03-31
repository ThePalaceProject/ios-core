//
//  BookCollectionServiceTests.swift
//  PalaceTests
//
//  Tests for BookCollectionService CRUD, persistence, and default collections.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import XCTest
@testable import Palace

final class BookCollectionServiceTests: XCTestCase {

    private var sut: BookCollectionService!
    private var defaults: UserDefaults!
    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "BookCollectionServiceTests")!
        defaults.removePersistentDomain(forName: "BookCollectionServiceTests")
        sut = BookCollectionService(userDefaults: defaults)
        cancellables = []
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "BookCollectionServiceTests")
        defaults = nil
        sut = nil
        cancellables = nil
        super.tearDown()
    }

    // MARK: - Default Collections

    func testEnsureDefaultCollections_CreatesThreeDefaults() {
        let collections = sut.allCollections()
        let defaultNames = BookCollection.DefaultName.allCases.map(\.rawValue)
        for name in defaultNames {
            XCTAssertTrue(collections.contains(where: { $0.name == name }),
                          "Default collection '\(name)' should exist")
        }
        XCTAssertGreaterThanOrEqual(collections.count, 3)
    }

    func testEnsureDefaultCollections_DoesNotDuplicate() {
        sut.ensureDefaultCollections()
        sut.ensureDefaultCollections()
        let wantToRead = sut.allCollections().filter { $0.name == "Want to Read" }
        XCTAssertEqual(wantToRead.count, 1)
    }

    // MARK: - Create

    func testCreateCollection_AddsToList() {
        let created = sut.createCollection(name: "Sci-Fi", description: "Science fiction picks")
        XCTAssertEqual(created.name, "Sci-Fi")
        XCTAssertEqual(created.collectionDescription, "Science fiction picks")
        XCTAssertTrue(sut.allCollections().contains(where: { $0.id == created.id }))
    }

    func testCreateCollection_IncrementsSort() {
        let first = sut.createCollection(name: "A")
        let second = sut.createCollection(name: "B")
        XCTAssertGreaterThan(second.sortOrder, first.sortOrder)
    }

    // MARK: - Read

    func testCollectionWithID_ReturnsCorrectCollection() {
        let created = sut.createCollection(name: "Test")
        let fetched = sut.collection(withID: created.id)
        XCTAssertEqual(fetched?.name, "Test")
    }

    func testCollectionWithID_ReturnsNilForUnknown() {
        XCTAssertNil(sut.collection(withID: UUID()))
    }

    // MARK: - Update

    func testUpdateCollection_ModifiesName() {
        var created = sut.createCollection(name: "Old Name")
        created.name = "New Name"
        let updated = sut.updateCollection(created)
        XCTAssertEqual(updated?.name, "New Name")
        XCTAssertEqual(sut.collection(withID: created.id)?.name, "New Name")
    }

    func testUpdateCollection_ReturnsNilForUnknown() {
        let unknown = BookCollection(name: "Ghost")
        XCTAssertNil(sut.updateCollection(unknown))
    }

    // MARK: - Delete

    func testDeleteCollection_RemovesFromList() {
        let created = sut.createCollection(name: "Temp")
        XCTAssertTrue(sut.deleteCollection(withID: created.id))
        XCTAssertNil(sut.collection(withID: created.id))
    }

    func testDeleteDefaultCollection_Fails() {
        let defaults = sut.allCollections().filter(\.isDefault)
        guard let first = defaults.first else {
            XCTFail("No default collections found")
            return
        }
        XCTAssertFalse(sut.deleteCollection(withID: first.id))
        XCTAssertNotNil(sut.collection(withID: first.id))
    }

    func testDeleteUnknownCollection_ReturnsFalse() {
        XCTAssertFalse(sut.deleteCollection(withID: UUID()))
    }

    // MARK: - Book Management

    func testAddBook_AppendsToCollection() {
        let collection = sut.createCollection(name: "Test")
        sut.addBook(withID: "book-1", toCollectionWithID: collection.id)
        let updated = sut.collection(withID: collection.id)
        XCTAssertEqual(updated?.bookIDs, ["book-1"])
    }

    func testAddBook_NoDuplicates() {
        let collection = sut.createCollection(name: "Test")
        sut.addBook(withID: "book-1", toCollectionWithID: collection.id)
        sut.addBook(withID: "book-1", toCollectionWithID: collection.id)
        let updated = sut.collection(withID: collection.id)
        XCTAssertEqual(updated?.bookIDs.count, 1)
    }

    func testRemoveBook_RemovesFromCollection() {
        let collection = sut.createCollection(name: "Test")
        sut.addBook(withID: "book-1", toCollectionWithID: collection.id)
        sut.addBook(withID: "book-2", toCollectionWithID: collection.id)
        sut.removeBook(withID: "book-1", fromCollectionWithID: collection.id)
        let updated = sut.collection(withID: collection.id)
        XCTAssertEqual(updated?.bookIDs, ["book-2"])
    }

    func testReorderBooks_SwapsPositions() {
        let collection = sut.createCollection(name: "Test")
        sut.addBook(withID: "A", toCollectionWithID: collection.id)
        sut.addBook(withID: "B", toCollectionWithID: collection.id)
        sut.addBook(withID: "C", toCollectionWithID: collection.id)
        sut.reorderBooks(inCollectionWithID: collection.id, fromIndex: 0, toIndex: 2)
        let updated = sut.collection(withID: collection.id)
        XCTAssertEqual(updated?.bookIDs, ["B", "C", "A"])
    }

    func testReorderBooks_InvalidIndicesNoOp() {
        let collection = sut.createCollection(name: "Test")
        sut.addBook(withID: "A", toCollectionWithID: collection.id)
        sut.reorderBooks(inCollectionWithID: collection.id, fromIndex: -1, toIndex: 5)
        let updated = sut.collection(withID: collection.id)
        XCTAssertEqual(updated?.bookIDs, ["A"])
    }

    // MARK: - Querying

    func testCollectionsContainingBook() {
        let c1 = sut.createCollection(name: "C1")
        let c2 = sut.createCollection(name: "C2")
        _ = sut.createCollection(name: "C3")
        sut.addBook(withID: "book-x", toCollectionWithID: c1.id)
        sut.addBook(withID: "book-x", toCollectionWithID: c2.id)
        let containing = sut.collections(containingBookID: "book-x")
        XCTAssertEqual(containing.count, 2)
    }

    // MARK: - Persistence

    func testPersistence_SurvivesReload() {
        let created = sut.createCollection(name: "Persisted")
        sut.addBook(withID: "book-p", toCollectionWithID: created.id)

        // Recreate service from same defaults
        let reloaded = BookCollectionService(userDefaults: defaults)
        let fetched = reloaded.collection(withID: created.id)
        XCTAssertEqual(fetched?.name, "Persisted")
        XCTAssertEqual(fetched?.bookIDs, ["book-p"])
    }

    // MARK: - Combine Publisher

    func testPublisher_EmitsOnChanges() {
        let expectation = expectation(description: "Publisher emits")
        var emitCount = 0

        sut.collectionsPublisher
            .dropFirst() // skip initial
            .sink { _ in
                emitCount += 1
                if emitCount == 1 {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        sut.createCollection(name: "Trigger")
        wait(for: [expectation], timeout: 1.0)
    }
}

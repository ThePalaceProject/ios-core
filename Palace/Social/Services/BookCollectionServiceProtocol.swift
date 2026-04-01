//
//  BookCollectionServiceProtocol.swift
//  Palace
//
//  Created for Social Features — collection service contract.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation

/// Contract for managing user book collections.
protocol BookCollectionServiceProtocol {

    /// Publisher that emits whenever the collections array changes.
    var collectionsPublisher: AnyPublisher<[BookCollection], Never> { get }

    /// Returns all collections, ordered by sortOrder.
    func allCollections() -> [BookCollection]

    /// Returns the collection with the given ID, or nil.
    func collection(withID id: UUID) -> BookCollection?

    /// Creates a new collection with the given name and returns it.
    @discardableResult
    func createCollection(name: String, description: String) -> BookCollection

    /// Updates an existing collection. Returns the updated collection or nil if not found.
    @discardableResult
    func updateCollection(_ collection: BookCollection) -> BookCollection?

    /// Deletes the collection with the given ID. Default collections cannot be deleted.
    /// Returns true if deletion succeeded.
    @discardableResult
    func deleteCollection(withID id: UUID) -> Bool

    /// Adds a book to a collection. No-op if already present.
    func addBook(withID bookID: String, toCollectionWithID collectionID: UUID)

    /// Removes a book from a collection.
    func removeBook(withID bookID: String, fromCollectionWithID collectionID: UUID)

    /// Reorders books within a collection.
    func reorderBooks(inCollectionWithID collectionID: UUID, fromIndex: Int, toIndex: Int)

    /// Returns all collections that contain the given book.
    func collections(containingBookID bookID: String) -> [BookCollection]

    /// Ensures the default collections exist, creating them if needed.
    func ensureDefaultCollections()
}

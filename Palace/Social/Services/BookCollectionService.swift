//
//  BookCollectionService.swift
//  Palace
//
//  Created for Social Features — local collection management.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation

/// Manages user-created book collections, persisted via UserDefaults + JSON.
final class BookCollectionService: BookCollectionServiceProtocol {

    // MARK: - Storage

    private let userDefaults: UserDefaults
    private static let storageKey = "palace.social.bookCollections"

    // MARK: - Combine

    private let collectionsSubject: CurrentValueSubject<[BookCollection], Never>

    var collectionsPublisher: AnyPublisher<[BookCollection], Never> {
        collectionsSubject.eraseToAnyPublisher()
    }

    // MARK: - Init

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults

        let loaded = Self.load(from: userDefaults)
        self.collectionsSubject = CurrentValueSubject(loaded)

        ensureDefaultCollections()
    }

    // MARK: - Read

    func allCollections() -> [BookCollection] {
        collectionsSubject.value.sorted { $0.sortOrder < $1.sortOrder }
    }

    func collection(withID id: UUID) -> BookCollection? {
        collectionsSubject.value.first { $0.id == id }
    }

    func collections(containingBookID bookID: String) -> [BookCollection] {
        collectionsSubject.value.filter { $0.contains(bookID: bookID) }
    }

    // MARK: - Create

    @discardableResult
    func createCollection(name: String, description: String = "") -> BookCollection {
        let maxSortOrder = collectionsSubject.value.map(\.sortOrder).max() ?? -1
        let collection = BookCollection(
            name: name,
            collectionDescription: description,
            sortOrder: maxSortOrder + 1
        )
        var collections = collectionsSubject.value
        collections.append(collection)
        save(collections)
        return collection
    }

    // MARK: - Update

    @discardableResult
    func updateCollection(_ collection: BookCollection) -> BookCollection? {
        var collections = collectionsSubject.value
        guard let index = collections.firstIndex(where: { $0.id == collection.id }) else {
            return nil
        }
        var updated = collection
        updated.modifiedDate = Date()
        collections[index] = updated
        save(collections)
        return updated
    }

    // MARK: - Delete

    @discardableResult
    func deleteCollection(withID id: UUID) -> Bool {
        var collections = collectionsSubject.value
        guard let index = collections.firstIndex(where: { $0.id == id }) else {
            return false
        }
        // Prevent deletion of default collections
        if collections[index].isDefault {
            return false
        }
        collections.remove(at: index)
        save(collections)
        return true
    }

    // MARK: - Book Management

    func addBook(withID bookID: String, toCollectionWithID collectionID: UUID) {
        var collections = collectionsSubject.value
        guard let index = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        guard !collections[index].bookIDs.contains(bookID) else { return }
        collections[index].bookIDs.append(bookID)
        collections[index].modifiedDate = Date()
        save(collections)
    }

    func removeBook(withID bookID: String, fromCollectionWithID collectionID: UUID) {
        var collections = collectionsSubject.value
        guard let index = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        collections[index].bookIDs.removeAll { $0 == bookID }
        collections[index].modifiedDate = Date()
        save(collections)
    }

    func reorderBooks(inCollectionWithID collectionID: UUID, fromIndex: Int, toIndex: Int) {
        var collections = collectionsSubject.value
        guard let index = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        var bookIDs = collections[index].bookIDs
        guard fromIndex >= 0, fromIndex < bookIDs.count,
              toIndex >= 0, toIndex < bookIDs.count else { return }
        let item = bookIDs.remove(at: fromIndex)
        bookIDs.insert(item, at: toIndex)
        collections[index].bookIDs = bookIDs
        collections[index].modifiedDate = Date()
        save(collections)
    }

    // MARK: - Defaults

    func ensureDefaultCollections() {
        var collections = collectionsSubject.value
        let existingNames = Set(collections.map(\.name))
        var changed = false

        for defaultName in BookCollection.DefaultName.allCases {
            if !existingNames.contains(defaultName.rawValue) {
                let maxSortOrder = collections.map(\.sortOrder).max() ?? -1
                let collection = BookCollection(
                    name: defaultName.rawValue,
                    sortOrder: maxSortOrder + 1
                )
                collections.append(collection)
                changed = true
            }
        }

        if changed {
            save(collections)
        }
    }

    // MARK: - Persistence

    private func save(_ collections: [BookCollection]) {
        collectionsSubject.send(collections)
        guard let data = try? JSONEncoder().encode(collections) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
    }

    private static func load(from userDefaults: UserDefaults) -> [BookCollection] {
        guard let data = userDefaults.data(forKey: storageKey),
              let collections = try? JSONDecoder().decode([BookCollection].self, from: data) else {
            return []
        }
        return collections
    }
}

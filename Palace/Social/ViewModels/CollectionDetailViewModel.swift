//
//  CollectionDetailViewModel.swift
//  Palace
//
//  Created for Social Features — manages a single collection's detail view.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation

/// ViewModel for viewing and editing a single book collection.
@MainActor
final class CollectionDetailViewModel: ObservableObject {

    // MARK: - Published State

    @Published var collection: BookCollection
    @Published var books: [TPPBook] = []
    @Published var isEditing: Bool = false

    // MARK: - Dependencies

    private let collectionService: BookCollectionServiceProtocol
    private let bookRegistry: TPPBookRegistryProvider
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(
        collection: BookCollection,
        collectionService: BookCollectionServiceProtocol,
        bookRegistry: TPPBookRegistryProvider
    ) {
        self.collection = collection
        self.collectionService = collectionService
        self.bookRegistry = bookRegistry

        // Observe collection changes and resolve book IDs
        collectionService.collectionsPublisher
            .receive(on: DispatchQueue.main)
            .compactMap { [id = collection.id] collections in
                collections.first { $0.id == id }
            }
            .sink { [weak self] updated in
                self?.collection = updated
                self?.resolveBooks(from: updated.bookIDs)
            }
            .store(in: &cancellables)

        resolveBooks(from: collection.bookIDs)
    }

    // MARK: - Actions

    func removeBook(at offsets: IndexSet) {
        for index in offsets {
            guard index < books.count else { continue }
            let book = books[index]
            collectionService.removeBook(
                withID: book.identifier,
                fromCollectionWithID: collection.id
            )
        }
    }

    func moveBook(from source: IndexSet, to destination: Int) {
        guard let fromIndex = source.first else { return }
        let toIndex = fromIndex < destination ? destination - 1 : destination
        collectionService.reorderBooks(
            inCollectionWithID: collection.id,
            fromIndex: fromIndex,
            toIndex: toIndex
        )
    }

    func updateName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = collection
        updated.name = trimmed
        collectionService.updateCollection(updated)
    }

    func updateDescription(_ description: String) {
        var updated = collection
        updated.collectionDescription = description
        collectionService.updateCollection(updated)
    }

    func shareCollection() -> String {
        let bookTitles = books.prefix(5).map(\.title).joined(separator: ", ")
        let suffix = books.count > 5 ? " and \(books.count - 5) more" : ""
        return "Check out my \"\(collection.name)\" collection on Palace: \(bookTitles)\(suffix)"
    }

    // MARK: - Private

    private func resolveBooks(from bookIDs: [String]) {
        books = bookIDs.compactMap { bookRegistry.book(forIdentifier: $0) }
    }
}

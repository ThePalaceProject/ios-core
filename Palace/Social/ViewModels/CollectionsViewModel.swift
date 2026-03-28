//
//  CollectionsViewModel.swift
//  Palace
//
//  Created for Social Features — manages all collections.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Combine
import Foundation

/// ViewModel for the top-level collections list.
@MainActor
final class CollectionsViewModel: ObservableObject {

    // MARK: - Published State

    @Published var collections: [BookCollection] = []
    @Published var selectedCollection: BookCollection?
    @Published var isEditing: Bool = false

    // MARK: - Dependencies

    private let collectionService: BookCollectionServiceProtocol
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(collectionService: BookCollectionServiceProtocol) {
        self.collectionService = collectionService

        collectionService.collectionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] updated in
                self?.collections = updated.sorted { $0.sortOrder < $1.sortOrder }
            }
            .store(in: &cancellables)
    }

    // MARK: - Actions

    func createCollection(name: String, description: String = "") {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        collectionService.createCollection(name: trimmed, description: description)
    }

    func deleteCollection(_ collection: BookCollection) {
        collectionService.deleteCollection(withID: collection.id)
    }

    func addBook(_ bookID: String, to collection: BookCollection) {
        collectionService.addBook(withID: bookID, toCollectionWithID: collection.id)
    }

    func removeBook(_ bookID: String, from collection: BookCollection) {
        collectionService.removeBook(withID: bookID, fromCollectionWithID: collection.id)
    }

    func reorderBooks(in collection: BookCollection, from source: IndexSet, to destination: Int) {
        guard let fromIndex = source.first else { return }
        let toIndex = fromIndex < destination ? destination - 1 : destination
        collectionService.reorderBooks(
            inCollectionWithID: collection.id,
            fromIndex: fromIndex,
            toIndex: toIndex
        )
    }

    func selectCollection(_ collection: BookCollection) {
        selectedCollection = collection
    }

    /// Default collections are always shown first and cannot be deleted.
    var defaultCollections: [BookCollection] {
        collections.filter(\.isDefault)
    }

    /// User-created collections.
    var userCollections: [BookCollection] {
        collections.filter { !$0.isDefault }
    }
}

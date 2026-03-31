//
//  BookCollection.swift
//  Palace
//
//  Created for Social Features — user-created book collections.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import Foundation

/// A user-created collection (list) of books, persisted locally.
struct BookCollection: Codable, Identifiable, Equatable {

    /// Unique identifier for this collection.
    let id: UUID

    /// User-facing name for the collection.
    var name: String

    /// Optional description.
    var collectionDescription: String

    /// Up to 4 cover image URLs used to build a mosaic thumbnail.
    var coverImageURLs: [URL]

    /// Ordered list of book identifiers in this collection.
    var bookIDs: [String]

    /// When the collection was created.
    let createdDate: Date

    /// When the collection was last modified.
    var modifiedDate: Date

    /// Whether the collection is publicly visible (future use).
    var isPublic: Bool

    /// Display sort order among all collections.
    var sortOrder: Int

    // MARK: - Defaults

    /// Well-known default collection names.
    enum DefaultName: String, CaseIterable {
        case wantToRead = "Want to Read"
        case favorites = "Favorites"
        case finished = "Finished"
    }

    /// Creates a new collection with sensible defaults.
    init(
        id: UUID = UUID(),
        name: String,
        collectionDescription: String = "",
        coverImageURLs: [URL] = [],
        bookIDs: [String] = [],
        createdDate: Date = Date(),
        modifiedDate: Date = Date(),
        isPublic: Bool = false,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.collectionDescription = collectionDescription
        self.coverImageURLs = coverImageURLs
        self.bookIDs = bookIDs
        self.createdDate = createdDate
        self.modifiedDate = modifiedDate
        self.isPublic = isPublic
        self.sortOrder = sortOrder
    }

    /// Whether this is one of the built-in default collections.
    var isDefault: Bool {
        DefaultName.allCases.map(\.rawValue).contains(name)
    }

    /// Number of books in the collection.
    var bookCount: Int {
        bookIDs.count
    }

    /// Returns true if the collection contains the given book identifier.
    func contains(bookID: String) -> Bool {
        bookIDs.contains(bookID)
    }

    // MARK: - Factory

    /// Creates the set of default collections that every user starts with.
    static func createDefaults() -> [BookCollection] {
        DefaultName.allCases.enumerated().map { index, defaultName in
            BookCollection(
                name: defaultName.rawValue,
                sortOrder: index
            )
        }
    }
}

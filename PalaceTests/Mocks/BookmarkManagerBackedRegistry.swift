//
//  BookmarkManagerBackedRegistry.swift
//  PalaceTests
//
//  A registry mock whose generic bookmarks go through the production
//  `BookmarkManager`, for tests whose outcome depends on how the registry
//  matches, replaces and deletes stored bookmark records.
//

import Foundation
import PalaceBookModel
@testable import Palace
@testable import PalaceBookRegistry

final class BookmarkManagerBackedRegistry: TPPBookRegistryMock, @unchecked Sendable {
    private let store = BookRegistryStore()
    private let manager: BookmarkManager

    override init() {
        manager = BookmarkManager(store: store, save: { _ in }, savePosition: { _ in }, saveSync: { _ in })
        super.init()
    }

    override func addBook(_ book: TPPBook, location: TPPBookLocation? = nil, state: TPPBookState, fulfillmentId: String? = nil, readiumBookmarks: [TPPReadiumBookmark]? = nil, genericBookmarks: [TPPBookLocation]? = nil) {
        super.addBook(book, location: location, state: state, fulfillmentId: fulfillmentId,
                      readiumBookmarks: readiumBookmarks, genericBookmarks: genericBookmarks)
        // The store reports completion on its barrier queue, never on the caller's.
        let added = DispatchSemaphore(value: 0)
        store.addBook(book, state: state, genericBookmarks: genericBookmarks ?? []) { _ in added.signal() }
        added.wait()
    }

    override func genericBookmarksForIdentifier(_ bookIdentifier: String) -> [TPPBookLocation] {
        manager.genericBookmarks(forIdentifier: bookIdentifier)
    }

    override func addGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) {
        manager.addGenericBookmark(location, forIdentifier: bookIdentifier, account: nil)
    }

    override func addOrReplaceGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) {
        manager.addOrReplaceGenericBookmark(location, forIdentifier: bookIdentifier, account: nil)
    }

    override func deleteGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) {
        manager.deleteGenericBookmark(location, forIdentifier: bookIdentifier, account: nil)
    }

    override func deleteGenericBookmark(identicalTo location: TPPBookLocation, forIdentifier bookIdentifier: String) {
        manager.deleteGenericBookmark(identicalTo: location, forIdentifier: bookIdentifier, account: nil)
    }

    override func replaceGenericBookmark(_ oldLocation: TPPBookLocation, with newLocation: TPPBookLocation, forIdentifier bookIdentifier: String) {
        manager.replaceGenericBookmark(oldLocation, with: newLocation, forIdentifier: bookIdentifier, account: nil)
    }
}

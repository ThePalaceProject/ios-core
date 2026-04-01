import Foundation

/// Manages bookmark CRUD operations and reading location tracking.
/// Delegates thread-safe storage access to a BookRegistryStore.
class BookmarkManager {

  private let store: BookRegistryStore
  private let save: () -> Void
  private let saveSync: () -> Void

  init(store: BookRegistryStore, save: @escaping () -> Void, saveSync: @escaping () -> Void) {
    self.store = store
    self.save = save
    self.saveSync = saveSync
  }

  // MARK: - Location tracking

  func setLocation(_ location: TPPBookLocation?, forIdentifier identifier: String) {
    guard !identifier.isEmpty else { return }
    store.mutateRegistry { [save] registry in
      registry[identifier]?.location = location
      save()
    }
  }

  func setLocationSync(_ location: TPPBookLocation?, forIdentifier identifier: String) {
    guard !identifier.isEmpty else { return }
    store.mutateRegistrySync { registry in
      registry[identifier]?.location = location
      Log.debug(#function, "Synchronously set location for \(identifier)")
    }
    saveSync()
  }

  func location(forIdentifier identifier: String) -> TPPBookLocation? {
    return store.readRegistry { $0[identifier]?.location }
  }

  // MARK: - Readium bookmarks

  func readiumBookmarks(forIdentifier identifier: String) -> [TPPReadiumBookmark] {
    return store.readRegistry { registry in
      guard let record = registry[identifier] else { return [] }
      return record.readiumBookmarks?.sorted { $0.progressWithinBook < $1.progressWithinBook } ?? []
    }
  }

  func addReadiumBookmark(_ bookmark: TPPReadiumBookmark, forIdentifier identifier: String) {
    store.mutateRegistry { [save] registry in
      guard registry[identifier] != nil else { return }
      if registry[identifier]?.readiumBookmarks == nil {
        registry[identifier]?.readiumBookmarks = [TPPReadiumBookmark]()
      }
      registry[identifier]?.readiumBookmarks?.append(bookmark)
      save()
    }
  }

  func deleteReadiumBookmark(_ bookmark: TPPReadiumBookmark, forIdentifier identifier: String) {
    store.mutateRegistry { [save] registry in
      registry[identifier]?.readiumBookmarks?.removeAll { $0 == bookmark }
      save()
    }
  }

  func replaceReadiumBookmark(_ oldBookmark: TPPReadiumBookmark, with newBookmark: TPPReadiumBookmark, forIdentifier identifier: String) {
    store.mutateRegistry { [save] registry in
      registry[identifier]?.readiumBookmarks?.removeAll { $0 == oldBookmark }
      registry[identifier]?.readiumBookmarks?.append(newBookmark)
      save()
    }
  }

  // MARK: - Generic bookmarks

  func genericBookmarks(forIdentifier identifier: String) -> [TPPBookLocation] {
    return store.readRegistry { registry in
      let bookmarks = registry[identifier]?.genericBookmarks ?? []
      Log.info(#function, "Fetching \(bookmarks.count) generic bookmarks for book: \(identifier)")
      return bookmarks
    }
  }

  func addOrReplaceGenericBookmark(_ location: TPPBookLocation, forIdentifier identifier: String) {
    store.mutateRegistry { [weak self, save] registry in
      guard let self, registry[identifier] != nil else { return }
      if registry[identifier]?.genericBookmarks == nil {
        registry[identifier]?.genericBookmarks = [TPPBookLocation]()
      }
      self.deleteGenericBookmarkInline(location, forIdentifier: identifier, registry: &registry)
      self.addGenericBookmarkInline(location, forIdentifier: identifier, registry: &registry)
      save()
    }
  }

  func addGenericBookmark(_ location: TPPBookLocation, forIdentifier identifier: String) {
    store.mutateRegistry { [weak self, save] registry in
      self?.addGenericBookmarkInline(location, forIdentifier: identifier, registry: &registry)
      save()
    }
  }

  func deleteGenericBookmark(_ location: TPPBookLocation, forIdentifier identifier: String) {
    store.mutateRegistry { [weak self, save] registry in
      self?.deleteGenericBookmarkInline(location, forIdentifier: identifier, registry: &registry)
      save()
    }
  }

  func replaceGenericBookmark(_ oldLocation: TPPBookLocation, with newLocation: TPPBookLocation, forIdentifier identifier: String) {
    store.mutateRegistry { [weak self] registry in
      self?.deleteGenericBookmarkInline(oldLocation, forIdentifier: identifier, registry: &registry)
      self?.addGenericBookmarkInline(newLocation, forIdentifier: identifier, registry: &registry)
    }
  }

  // MARK: - Inline helpers (called within mutateRegistry barrier)

  private func addGenericBookmarkInline(_ location: TPPBookLocation, forIdentifier identifier: String, registry: inout [String: TPPBookRegistryRecord]) {
    guard registry[identifier] != nil else {
      Log.warn(#function, "Cannot add bookmark, book not in registry: \(identifier)")
      return
    }
    if registry[identifier]?.genericBookmarks == nil {
      registry[identifier]?.genericBookmarks = [TPPBookLocation]()
    }
    registry[identifier]?.genericBookmarks?.append(location)
    let count = registry[identifier]?.genericBookmarks?.count ?? 0
    Log.info(#function, "Added generic bookmark for \(identifier), total count now: \(count)")
  }

  private func deleteGenericBookmarkInline(_ location: TPPBookLocation, forIdentifier identifier: String, registry: inout [String: TPPBookRegistryRecord]) {
    let beforeCount = registry[identifier]?.genericBookmarks?.count ?? 0

    // First try matching by annotation ID if available
    if let locationDict = location.locationStringDictionary(),
       let annotationId = locationDict["annotationId"] as? String,
       !annotationId.isEmpty {

      registry[identifier]?.genericBookmarks?.removeAll { existingLocation in
        guard let existingDict = existingLocation.locationStringDictionary(),
              let existingId = existingDict["annotationId"] as? String else {
          return false
        }
        return existingId == annotationId
      }

      let afterCount = registry[identifier]?.genericBookmarks?.count ?? 0
      let deleted = beforeCount - afterCount

      if deleted > 0 {
        Log.info(#function, "Deleted \(deleted) bookmark(s) by annotationId for \(identifier), remaining: \(afterCount)")
        return
      } else {
        Log.warn(#function, "No match by annotationId '\(annotationId)', trying content match")
      }
    }

    // Fallback to content-based matching
    registry[identifier]?.genericBookmarks?.removeAll { $0.isSimilarTo(location) }
    let afterCount = registry[identifier]?.genericBookmarks?.count ?? 0
    let deleted = beforeCount - afterCount
    Log.info(#function, "Deleted \(deleted) bookmark(s) by content for \(identifier), remaining: \(afterCount)")
  }
}

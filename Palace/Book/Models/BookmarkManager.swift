import Foundation
import PalaceLogging

/// Manages bookmark CRUD operations and reading location tracking.
/// Delegates thread-safe storage access to a BookRegistryStore.
///
/// Every mutating method takes an explicit `account` and passes it to the
/// injected save closure. The caller (the facade) captures
/// `AccountsManager.shared.currentAccount` synchronously at the moment of
/// dispatch, not inside the async barrier — otherwise a save queued here could
/// land in the wrong account's registry file if the user switched libraries
/// while the async work was in flight (PP-4129 regression).
class BookmarkManager {

  private let store: BookRegistryStore
  private let save: (String) -> Void
  private let saveSync: (String) -> Void

  init(store: BookRegistryStore, save: @escaping (String) -> Void, saveSync: @escaping (String) -> Void) {
    self.store = store
    self.save = save
    self.saveSync = saveSync
  }

  // MARK: - Location tracking

  func setLocation(_ location: TPPBookLocation?, forIdentifier identifier: String, account: String?) {
    guard !identifier.isEmpty else { return }
    store.mutateRegistry({ registry in
      registry[identifier]?.location = location
    }, onComplete: { [save] in if let account { save(account) } })
  }

  func setLocationSync(_ location: TPPBookLocation?, forIdentifier identifier: String, account: String?) {
    guard !identifier.isEmpty else { return }
    store.mutateRegistrySync({ registry in
      registry[identifier]?.location = location
      Log.debug(#function, "Synchronously set location for \(identifier)")
    }, onComplete: { [saveSync] in if let account { saveSync(account) } })
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

  func addReadiumBookmark(_ bookmark: TPPReadiumBookmark, forIdentifier identifier: String, account: String?) {
    // Capture by reference via a class box so the onComplete barrier sees the
    // value set inside the mutation barrier. Swift auto-boxes a local var
    // captured mutably by multiple closures; we rely on that.
    var didMutate = false
    store.mutateRegistry({ registry in
      guard registry[identifier] != nil else { return }
      if registry[identifier]?.readiumBookmarks == nil {
        registry[identifier]?.readiumBookmarks = [TPPReadiumBookmark]()
      }
      registry[identifier]?.readiumBookmarks?.append(bookmark)
      didMutate = true
    }, onComplete: { [save] in if didMutate, let account { save(account) } })
  }

  func deleteReadiumBookmark(_ bookmark: TPPReadiumBookmark, forIdentifier identifier: String, account: String?) {
    store.mutateRegistry({ registry in
      registry[identifier]?.readiumBookmarks?.removeAll { $0 == bookmark }
    }, onComplete: { [save] in if let account { save(account) } })
  }

  func replaceReadiumBookmark(_ oldBookmark: TPPReadiumBookmark, with newBookmark: TPPReadiumBookmark, forIdentifier identifier: String, account: String?) {
    store.mutateRegistry({ registry in
      registry[identifier]?.readiumBookmarks?.removeAll { $0 == oldBookmark }
      registry[identifier]?.readiumBookmarks?.append(newBookmark)
    }, onComplete: { [save] in if let account { save(account) } })
  }

  // MARK: - Generic bookmarks

  func genericBookmarks(forIdentifier identifier: String) -> [TPPBookLocation] {
    return store.readRegistry { registry in
      let bookmarks = registry[identifier]?.genericBookmarks ?? []
      Log.info(#function, "Fetching \(bookmarks.count) generic bookmarks for book: \(identifier)")
      return bookmarks
    }
  }

  func addOrReplaceGenericBookmark(_ location: TPPBookLocation, forIdentifier identifier: String, account: String?) {
    store.mutateRegistry({ [weak self] registry in
      guard let self, registry[identifier] != nil else { return }
      if registry[identifier]?.genericBookmarks == nil {
        registry[identifier]?.genericBookmarks = [TPPBookLocation]()
      }
      self.deleteGenericBookmarkInline(location, forIdentifier: identifier, registry: &registry)
      self.addGenericBookmarkInline(location, forIdentifier: identifier, registry: &registry)
    }, onComplete: { [save] in if let account { save(account) } })
  }

  func addGenericBookmark(_ location: TPPBookLocation, forIdentifier identifier: String, account: String?) {
    var didMutate = false
    store.mutateRegistry({ [weak self] registry in
      guard registry[identifier] != nil else {
        Log.warn(#function, "Skipping bookmark add + save for missing book: \(identifier)")
        return
      }
      self?.addGenericBookmarkInline(location, forIdentifier: identifier, registry: &registry)
      didMutate = true
    }, onComplete: { [save] in if didMutate, let account { save(account) } })
  }

  func deleteGenericBookmark(_ location: TPPBookLocation, forIdentifier identifier: String, account: String?) {
    store.mutateRegistry({ [weak self] registry in
      self?.deleteGenericBookmarkInline(location, forIdentifier: identifier, registry: &registry)
    }, onComplete: { [save] in if let account { save(account) } })
  }

  func replaceGenericBookmark(_ oldLocation: TPPBookLocation, with newLocation: TPPBookLocation, forIdentifier identifier: String, account: String?) {
    store.mutateRegistry({ [weak self] registry in
      self?.deleteGenericBookmarkInline(oldLocation, forIdentifier: identifier, registry: &registry)
      self?.addGenericBookmarkInline(newLocation, forIdentifier: identifier, registry: &registry)
    }, onComplete: { [save] in if let account { save(account) } })
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

import Foundation
import PalaceLogging
import PalaceBookModel

/// Manages bookmark CRUD operations and reading location tracking.
/// Delegates thread-safe storage access to a BookRegistryStore.
///
/// Every mutating method takes an explicit `account` and passes it to the
/// injected save closure. The caller (the facade) captures
/// `appContainer.accountsManager.currentAccount` synchronously at the moment of
/// dispatch, not inside the async barrier — otherwise a save queued here could
/// land in the wrong account's registry file if the user switched libraries
/// while the async work was in flight (PP-4129 regression).
class BookmarkManager {

  private let store: BookRegistryStore
  private let save: (String) -> Void
  /// Persists a change that only moved a reading position. See `setLocation`.
  private let savePosition: (String) -> Void
  private let saveSync: (String) -> Void
  private let now: () -> Date

  /// A `.coalesced` position reaches disk at most this often per book.
  static let coalescedPositionWriteInterval: TimeInterval = 15

  private struct PositionKey: Hashable {
    let account: String
    let identifier: String
  }

  /// Guards `lastPositionWrite` and `pendingPositions`. Held only for dictionary
  /// access, never while saving.
  private let positionLock = NSLock()
  private var lastPositionWrite: [PositionKey: Date] = [:]
  /// Account to identifiers whose newest position is in memory but not on disk.
  private var pendingPositions: [String: Set<String>] = [:]

  init(
    store: BookRegistryStore,
    save: @escaping (String) -> Void,
    savePosition: @escaping (String) -> Void,
    saveSync: @escaping (String) -> Void,
    now: @escaping () -> Date = { Date() }
  ) {
    self.store = store
    self.save = save
    self.savePosition = savePosition
    self.saveSync = saveSync
    self.now = now
  }

  // MARK: - Location tracking

  /// The periodic position write: audiobooks call it every ~15 seconds of
  /// playback, and the EPUB and PDF readers as the reader moves. It is
  /// persisted, but not announced as a shelf change and not copied to the
  /// last-good backup: every reader of a location pulls it on demand, and
  /// nothing that observes the shelf renders one (PP-5268).
  ///
  /// The in-memory record changes on every call in both modes; `persistence`
  /// decides only when the registry file is written (PP-5507).
  func setLocation(
    _ location: TPPBookLocation?,
    forIdentifier identifier: String,
    account: String?,
    persistence: RegistryPositionPersistence = .immediate
  ) {
    guard !identifier.isEmpty else { return }
    store.mutateRegistry({ registry in
      registry[identifier]?.location = location
    }, announce: false, onComplete: { [self] in
      // Runs as a store barrier, so the write-or-defer decisions follow mutation order.
      guard let account, positionWriteIsDue(account: account, identifier: identifier, persistence: persistence) else { return }
      savePosition(account)
    })
  }

  /// Returns true when this change is written now, and records the write.
  /// Otherwise marks the book's position as pending for its account.
  private func positionWriteIsDue(account: String, identifier: String, persistence: RegistryPositionPersistence) -> Bool {
    let key = PositionKey(account: account, identifier: identifier)
    let now = self.now()
    positionLock.lock()
    defer { positionLock.unlock() }
    if persistence == .coalesced, let last = lastPositionWrite[key],
       now.timeIntervalSince(last) < Self.coalescedPositionWriteInterval {
      pendingPositions[account, default: []].insert(identifier)
      return false
    }
    lastPositionWrite[key] = now
    // The save stores the account's whole in-memory shelf, pending positions included.
    pendingPositions[account] = nil
    return true
  }

  /// Writes the pending positions of `loadedAccount`, the account whose shelf the
  /// store holds. Pending positions of any other account are dropped: their shelf
  /// is no longer in memory, and saving under that account would write the loaded
  /// shelf into its file. Runs as a store barrier, after every change already queued.
  func flushPendingPositions(loadedAccount: String?) {
    store.performBarrierSync({ [self] in
      let now = self.now()
      positionLock.lock()
      let pending = pendingPositions
      pendingPositions.removeAll()
      let due = loadedAccount.flatMap { pending[$0] } ?? []
      if let loadedAccount {
        for identifier in due {
          lastPositionWrite[PositionKey(account: loadedAccount, identifier: identifier)] = now
        }
      }
      positionLock.unlock()

      let dropped = pending.filter { $0.key != loadedAccount }.values.reduce(0) { $0 + $1.count }
      if dropped > 0 {
        Log.warn(#file, "Dropped \(dropped) pending reading position(s) of a library that is no longer loaded")
      }
      if let loadedAccount, !due.isEmpty {
        savePosition(loadedAccount)
      }
    }, operation: "flushPendingPositions")
  }

  /// Forgets pending positions and write times of a signed-out account.
  func dropPendingPositions(for account: String) {
    positionLock.lock()
    defer { positionLock.unlock() }
    pendingPositions[account] = nil
    lastPositionWrite = lastPositionWrite.filter { $0.key.account != account }
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

  /// Matches by identity, not content: the caller holds the exact record it
  /// read, while a content match can miss it (parsing adds fields) or hit a
  /// different record at the same position. A missing record is not re-added,
  /// so a bookmark deleted locally during its upload is not written back.
  func replaceGenericBookmark(_ oldLocation: TPPBookLocation, with newLocation: TPPBookLocation, forIdentifier identifier: String, account: String?) {
    var didMutate = false
    store.mutateRegistry({ registry in
      guard let index = registry[identifier]?.genericBookmarks?.firstIndex(where: { $0.isSameRecord(as: oldLocation) }) else {
        Log.info(#function, "No stored record to replace for \(identifier); leaving bookmarks unchanged")
        return
      }
      registry[identifier]?.genericBookmarks?[index] = newLocation
      didMutate = true
    }, onComplete: { [save] in if didMutate, let account { save(account) } })
  }

  func deleteGenericBookmark(identicalTo location: TPPBookLocation, forIdentifier identifier: String, account: String?) {
    var didMutate = false
    store.mutateRegistry({ registry in
      guard let index = registry[identifier]?.genericBookmarks?.firstIndex(where: { $0.isSameRecord(as: location) }) else {
        return
      }
      registry[identifier]?.genericBookmarks?.remove(at: index)
      didMutate = true
    }, onComplete: { [save] in if didMutate, let account { save(account) } })
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

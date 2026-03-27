import Foundation
import Combine

/// Thread-safe in-memory storage for book registry records.
/// Uses a concurrent DispatchQueue with barrier writes for thread safety.
class BookRegistryStore {

  private let syncQueueKey = DispatchSpecificKey<Void>()
  private let syncQueue = DispatchQueue(
    label: "com.palace.bookRegistryStore",
    attributes: .concurrent
  )

  private var registry = [String: TPPBookRegistryRecord]() {
    didSet {
      let snapshot = registry
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        registrySubject.send(snapshot)
        NotificationCenter.default.post(name: .TPPBookRegistryDidChange, object: nil, userInfo: nil)
      }
    }
  }

  private var processingIdentifiers = Set<String>()

  // MARK: - Combine subjects

  let registrySubject = CurrentValueSubject<[String: TPPBookRegistryRecord], Never>([:])
  let bookStateSubject = PassthroughSubject<(String, TPPBookState), Never>()

  // MARK: - Init

  init() {
    syncQueue.setSpecific(key: syncQueueKey, value: ())
  }

  // MARK: - Thread-safe helpers

  func performSync<T>(_ block: () -> T) -> T {
    if DispatchQueue.getSpecific(key: syncQueueKey) != nil {
      return block()
    } else {
      return syncQueue.sync { block() }
    }
  }

  func performBarrier(_ block: @escaping () -> Void) {
    syncQueue.async(flags: .barrier, execute: block)
  }

  func performBarrierSync(_ block: () -> Void) {
    if DispatchQueue.getSpecific(key: syncQueueKey) != nil {
      block()
    } else {
      syncQueue.sync(flags: .barrier, execute: block)
    }
  }

  // MARK: - Direct registry access (for sync/load operations that need batch mutations)

  /// Provides direct read access to the registry dictionary within a sync block.
  func readRegistry<T>(_ block: (_ registry: [String: TPPBookRegistryRecord]) -> T) -> T {
    return performSync { block(self.registry) }
  }

  /// Provides direct write access to the registry dictionary within a barrier block.
  func mutateRegistrySync(_ block: (_ registry: inout [String: TPPBookRegistryRecord]) -> Void) {
    performBarrierSync { block(&self.registry) }
  }

  func mutateRegistry(_ block: @escaping (_ registry: inout [String: TPPBookRegistryRecord]) -> Void) {
    performBarrier { block(&self.registry) }
  }

  // MARK: - Query

  var allBooks: [TPPBook] {
    return performSync {
      registry.values
        .filter { TPPBookStateHelper.allBookStates().contains($0.state.rawValue) }
        .map { $0.book }
    }
  }

  var heldBooks: [TPPBook] {
    return performSync {
      registry.values
        .filter { $0.state == .holding }
        .map { $0.book }
    }
  }

  var myBooks: [TPPBook] {
    let matchingStates: [TPPBookState] = [
      .downloadNeeded, .downloading, .SAMLStarted, .downloadFailed, .downloadSuccessful, .used
    ]
    return performSync {
      registry.values
        .filter { matchingStates.contains($0.state) }
        .map { $0.book }
    }
  }

  func record(forIdentifier identifier: String?) -> TPPBookRegistryRecord? {
    guard let identifier, !identifier.isEmpty else { return nil }
    return performSync { registry[identifier] }
  }

  func book(forIdentifier identifier: String?) -> TPPBook? {
    return record(forIdentifier: identifier)?.book
  }

  func state(for identifier: String?) -> TPPBookState {
    guard let identifier, !identifier.isEmpty else { return .unregistered }
    return performSync { registry[identifier]?.state ?? .unregistered }
  }

  func fulfillmentId(forIdentifier identifier: String?) -> String? {
    guard let identifier, !identifier.isEmpty else { return nil }
    return performSync { registry[identifier]?.fulfillmentId }
  }

  // MARK: - Mutations

  func addBook(
    _ book: TPPBook,
    location: TPPBookLocation? = nil,
    state: TPPBookState = .downloadNeeded,
    fulfillmentId: String? = nil,
    readiumBookmarks: [TPPReadiumBookmark]? = nil,
    genericBookmarks: [TPPBookLocation]? = nil,
    onComplete: ((_ snapshot: [String: TPPBookRegistryRecord]) -> Void)? = nil
  ) {
    performBarrier { [weak self] in
      guard let self else { return }
      self.registry[book.identifier] = TPPBookRegistryRecord(
        book: book,
        location: location,
        state: state,
        fulfillmentId: fulfillmentId,
        readiumBookmarks: readiumBookmarks,
        genericBookmarks: genericBookmarks
      )
      let snapshot = self.registry
      onComplete?(snapshot)
    }
  }

  func removeBook(forIdentifier identifier: String, onComplete: ((_ removedBook: TPPBook?, _ snapshot: [String: TPPBookRegistryRecord]) -> Void)? = nil) {
    performBarrier { [weak self] in
      guard let self else { return }
      let removedBook = self.registry[identifier]?.book
      self.registry.removeValue(forKey: identifier)
      let snapshot = self.registry
      onComplete?(removedBook, snapshot)
    }
  }

  func updateBook(_ book: TPPBook, onComplete: ((_ previousState: TPPBookState, _ nextState: TPPBookState, _ snapshot: [String: TPPBookRegistryRecord]) -> Void)? = nil) {
    performBarrier { [weak self] in
      guard let self, let record = self.registry[book.identifier] else { return }

      let previousState = record.state
      var nextState = record.state
      if record.state == .unregistered {
        book.defaultAcquisition?.availability.matchUnavailable(
          nil, limited: nil, unlimited: nil,
          reserved: { _ in nextState = .holding },
          ready: { _ in nextState = .holding }
        )
      }

      NotificationService.compareAvailability(cachedRecord: record, andNewBook: book)
      self.registry[book.identifier] = TPPBookRegistryRecord(
        book: book,
        location: record.location,
        state: nextState,
        fulfillmentId: record.fulfillmentId,
        readiumBookmarks: record.readiumBookmarks,
        genericBookmarks: record.genericBookmarks
      )
      let snapshot = self.registry
      onComplete?(previousState, nextState, snapshot)
    }
  }

  func updateAndRemoveBook(_ book: TPPBook, onComplete: ((_ snapshot: [String: TPPBookRegistryRecord]) -> Void)? = nil) {
    performBarrier { [weak self] in
      guard let self, let record = self.registry[book.identifier] else { return }
      record.book = book
      record.state = .unregistered
      let snapshot = self.registry
      onComplete?(snapshot)
    }
  }

  func updatedBookMetadata(_ book: TPPBook) -> TPPBook? {
    return performSync {
      guard let bookRecord = self.registry[book.identifier] else { return nil }
      let updatedBook = bookRecord.book.bookWithMetadata(from: book)
      self.registry[book.identifier]?.book = updatedBook
      return updatedBook
    }
  }

  func setState(_ state: TPPBookState, for identifier: String, onComplete: (() -> Void)? = nil) {
    performBarrier { [weak self] in
      guard let self else { return }
      self.registry[identifier]?.state = state
      onComplete?()
    }
  }

  func setFulfillmentId(_ fulfillmentId: String, for identifier: String) {
    performBarrier { [weak self] in
      guard let self else { return }
      self.registry[identifier]?.fulfillmentId = fulfillmentId
    }
  }

  // MARK: - Processing

  func setProcessing(_ processing: Bool, for identifier: String) {
    performBarrier { [weak self] in
      guard let self else { return }
      if processing {
        self.processingIdentifiers.insert(identifier)
      } else {
        self.processingIdentifiers.remove(identifier)
      }
      DispatchQueue.main.async {
        NotificationCenter.default.post(name: .TPPBookProcessingDidChange, object: nil, userInfo: [
          TPPNotificationKeys.bookProcessingBookIDKey: identifier,
          TPPNotificationKeys.bookProcessingValueKey: processing
        ])
      }
    }
  }

  func processing(forIdentifier identifier: String) -> Bool {
    return performSync { processingIdentifiers.contains(identifier) }
  }

  // MARK: - Bulk operations

  func removeAll() {
    performBarrier { [weak self] in
      self?.registry.removeAll()
    }
  }

  func registrySnapshot() -> [[String: Any]] {
    return performSync {
      self.registry.values.map { $0.dictionaryRepresentation }
    }
  }
}

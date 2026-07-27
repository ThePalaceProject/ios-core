import Foundation
import Combine
import PalaceBookModel

/// Thread-safe in-memory storage for book registry records.
/// Uses a concurrent DispatchQueue with barrier writes for thread safety.
///
/// `@unchecked Sendable` invariant (verified, not waived):
///   ALL access to the two pieces of mutable state — the `registry`
///   dictionary and the `processingIdentifiers` set — is funnelled through
///   `syncQueue`, a *concurrent* queue used as a reader/writer lock:
///     • Every READ (`allBooks`, `heldBooks`, `myBooks`, `record(for:)`,
///       `book(for:)`, `state(for:)`, `fulfillmentId(for:)`,
///       `processing(for:)`, `readRegistry`, `registrySnapshot`) goes through
///       `performSync`, which runs the block on `syncQueue` (a plain
///       concurrent read).
///     • Every WRITE (`addBook`, `removeBook`, `updateBook`,
///       `updateAndRemoveBook`, `updatedBookMetadata`, `setState`,
///       `setFulfillmentId`, `setProcessing`, `removeAll`, `mutateRegistry*`)
///       goes through `performBarrier` / `performBarrierSync` (an
///       `async(flags: .barrier)` / `sync(flags: .barrier)` write), which
///       excludes all concurrent readers and other writers for its duration.
///   The `syncQueueKey` `DispatchSpecific` guard makes the sync helpers
///   re-entrant (a barrier block that calls back into `performSync` runs
///   inline instead of deadlocking) without ever escaping the serialized
///   write window. No property is read or written outside these helpers.
///   The Combine subjects (`registrySubject`, `bookStateSubject`) are `let`
///   and thread-safe by construction. Therefore instances are safe to share
///   across concurrency domains: the class carries its own synchronization,
///   which is exactly the condition `@unchecked Sendable` documents.
final class BookRegistryStore: @unchecked Sendable {

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

  /// Fired when `updateBook` reconciles a record whose availability changed
  /// (drives the app's push-notification comparison). Injected app-side (god-class
  /// decomp Wave 2b — `NotificationService` stays app-target). Defaults to a no-op
  /// so white-box tests that construct a bare store need not supply it.
  private let onAvailabilityChange: @Sendable (_ cachedRecord: TPPBookRegistryRecord, _ newBook: TPPBook) -> Void

  // MARK: - Init

  init(onAvailabilityChange: @escaping @Sendable (_ cachedRecord: TPPBookRegistryRecord, _ newBook: TPPBook) -> Void = { _, _ in }) {
    self.onAvailabilityChange = onAvailabilityChange
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
    // `DispatchQueue.async(execute:)` wants a `@Sendable` closure in Swift 6
    // `complete` mode, but `block` is a plain non-Sendable `() -> Void` (its
    // callers — `mutateRegistry`, `BookmarkManager`'s CRUD closures — capture
    // non-Sendable state like `save` and `TPPBookLocation`, so `@Sendable`ing
    // this parameter would ripple the diagnostic up the whole chain). Confine
    // the non-Sendable closure to a carrier box and submit a `@Sendable`
    // trampoline instead. INVARIANT: the box's `block` is invoked exactly once,
    // on `syncQueue` inside the serialized barrier window — the same
    // single-threaded execution the parameter already had — so no capture races
    // another thread. Mirrors `SyncCallbacks` / `SendableErrorDocument`.
    let carrier = BarrierBlockBox(block)
    syncQueue.async(flags: .barrier) { carrier.run() }
  }

  func performBarrierSync(_ block: () -> Void) {
    if DispatchQueue.getSpecific(key: syncQueueKey) != nil {
      block()
    } else {
      syncQueue.sync(flags: .barrier, execute: block)
    }
  }

  // MARK: - Test-only deterministic-join seam

  /// Test-only: await every write enqueued on `syncQueue` before this call.
  ///
  /// Bounded by construction — a `.barrier` block on the concurrent `syncQueue`
  /// runs only AFTER every previously-enqueued `addBook`/`removeBook`/
  /// `updateBook`/`setState` barrier block (and its `onComplete`) has finished,
  /// so the continuation is always resumed exactly once. This is NOT a bare
  /// `await handle` that could hang and it adds NO sleep/poll/clock: it merely
  /// drains the existing queue via one more trailing barrier hop.
  ///
  /// No XCTest gate is needed (unlike the retained-task seams): this spawns no
  /// retained state and production never calls it. Mirrors the intent of
  /// `TokenRefreshInterceptor._awaitAuthDispatchForTesting` /
  /// `AccountsManager._awaitAllCrawlTasksForTesting`.
  func _awaitPendingWritesForTesting() async {
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      performBarrier { cont.resume() }
    }
  }

  // MARK: - Direct registry access (for sync/load operations that need batch mutations)

  /// Provides direct read access to the registry dictionary within a sync block.
  func readRegistry<T>(_ block: (_ registry: [String: TPPBookRegistryRecord]) -> T) -> T {
    return performSync { block(self.registry) }
  }

  /// Provides direct write access to the registry dictionary within a barrier block.
  ///
  /// `onComplete` runs on the barrier queue AFTER `block(&self.registry)` has
  /// fully completed — it is dispatched as a separate barrier job so Swift's
  /// exclusivity tracking does NOT consider the `inout` access still open during
  /// `onComplete`. Use `onComplete` for snapshot-and-save work (reading the
  /// registry) that cannot be done inside the mutation block itself without
  /// triggering "Simultaneous accesses to registry, but modification requires
  /// exclusive access" (PP-4129 crash fix).
  func mutateRegistrySync(
    _ block: (_ registry: inout [String: TPPBookRegistryRecord]) -> Void,
    onComplete: (() -> Void)? = nil
  ) {
    performBarrierSync { block(&self.registry) }
    // Second barrier dispatch: inout access from `block` has fully ended before
    // `onComplete` runs. onComplete can safely read `self.registry` (e.g. to
    // snapshot it for save) without tripping exclusivity.
    if let onComplete = onComplete {
      performBarrierSync { onComplete() }
    }
  }

  func mutateRegistry(
    _ block: @escaping (_ registry: inout [String: TPPBookRegistryRecord]) -> Void,
    onComplete: (() -> Void)? = nil
  ) {
    performBarrier { block(&self.registry) }
    if let onComplete = onComplete {
      performBarrier { onComplete() }
    }
  }

  // MARK: - Query

  var allBooks: [TPPBook] {
    return performSync {
      registry.values
        .filter { record in TPPBookState.allCases.map { $0.rawValue }.contains(record.state.rawValue) }
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
        book.defaultAcquisition?.availability.match(unavailable: 
          nil, limited: nil, unlimited: nil,
          reserved: { _ in nextState = .holding },
          ready: { _ in nextState = .holding }
        )
      }

      onAvailabilityChange(record, book)
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
    var result: TPPBook?
    let block = {
      guard let bookRecord = self.registry[book.identifier] else { return }
      // Previously used `bookWithMetadata(from:)`, which unconditionally takes
      // every metadata field from the incoming catalog entry. That works when
      // the catalog feed is always richer than the registry record, but the
      // Palace Circulation Manager's OPDS responses can return lean entries
      // for a subset of books on a given call (missing authors / summary /
      // categories). In that case the catalog enrichment path would wipe the
      // registry's already-populated authors, MyBooks would reload with a
      // blank author line, and the visible "flicker" we're chasing would
      // return on the next reload.
      //
      // `mergingPreservingMetadata(from:)` takes the fresh state-carrying
      // fields (acquisitions, updated) from the catalog entry but prefers
      // self's metadata wherever the incoming one is empty. Catalog-enriched
      // fields still flow through when they're present; previously-enriched
      // fields are retained when they're not.
      let updatedBook = bookRecord.book.mergingPreservingMetadata(from: book)
      self.registry[book.identifier]?.book = updatedBook
      result = updatedBook
    }
    if DispatchQueue.getSpecific(key: syncQueueKey) != nil {
      block()
    } else {
      syncQueue.sync(flags: .barrier, execute: block)
    }
    return result
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
        NotificationCenter.default.post(name: .registryBookProcessingDidChange, object: nil, userInfo: [
          RegistryProcessingNotificationKeys.bookID: identifier,
          RegistryProcessingNotificationKeys.value: processing
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

// MARK: - Sendable carrier for `performBarrier`

/// Sendable carrier for the non-Sendable `() -> Void` block that `performBarrier`
/// submits to `syncQueue`. `DispatchQueue.async(execute:)` expects a `@Sendable`
/// closure under Swift 6 `complete`; wrapping the block here lets the barrier
/// submission capture this box (Sendable) instead of the raw non-Sendable
/// closure — without pushing `@Sendable` onto `performBarrier`'s public
/// parameter (which would ripple through `mutateRegistry` and every
/// `BookmarkManager` CRUD closure, since those capture non-Sendable `save` /
/// `TPPBookLocation` values).
///
/// `@unchecked Sendable` invariant: `run()` is called exactly once, on
/// `syncQueue` inside the serialized `.barrier` window — the identical
/// single-threaded execution the block had before boxing. The stored closure is
/// never invoked from more than one thread, so moving the box across the
/// dispatch boundary is race-free. Mirrors `SyncCallbacks` / `SendableErrorDocument`.
private final class BarrierBlockBox: @unchecked Sendable {
  private let block: () -> Void
  init(_ block: @escaping () -> Void) { self.block = block }
  func run() { block() }
}

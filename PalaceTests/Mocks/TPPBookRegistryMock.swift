import Foundation
import Combine
import UIKit
@testable import Palace

/// `@unchecked Sendable`: `TPPBookRegistryProvider` is `Sendable` (so production
/// consumers can capture the registry across concurrency domains), and this mock
/// HONORS that contract: all mutable state (`_registry`, `_myBooks`, `_state`,
/// `_isSyncing`, `_mockImages`, …) is guarded by a single `NSLock`, matching the
/// thread-safety production `TPPBookRegistry` provides via its split-lock
/// (ba4a03c69). Concurrency tests may legitimately share one instance across
/// tasks/threads.
///
/// Locking rules (architect-reviewed, fix/sync-mock-race-segv-bookmark-keys):
/// - Public methods take the lock EXACTLY ONCE and delegate any work shared
///   between public entry points to private UNLOCKED `_`-prefixed helpers
///   (`preloadData` → `_addGenericBookmark`). No public method calls another
///   public method while holding the lock. `NSRecursiveLock` is deliberately
///   not used — it would mask lock-ordering mistakes.
/// - Combine `send(...)` and `NotificationCenter.post(...)` happen OUTSIDE the
///   lock: a synchronous subscriber re-entering the mock must not deadlock.
/// - Direct `registry`/`myBooks`/… property access (used single-threaded by
///   many tests) goes through locked computed accessors; record-object
///   mutation via that path (`mock.registry[id]?.state = …`) remains a
///   single-threaded convenience — concurrent access must use the protocol
///   methods, which mutate records under the lock.
class TPPBookRegistryMock: NSObject, TPPBookRegistryProvider, @unchecked Sendable {

    private let lock = NSLock()

    /// Records the libraryID(s) passed to `reset` so tests can assert the
    /// registry was reset for the expected (active) library only.
    private var _resetCalledLibraryIDs: [String] = []
    private(set) var resetCalledLibraryIDs: [String] {
        get { lock.withLock { _resetCalledLibraryIDs } }
        set { lock.withLock { _resetCalledLibraryIDs = newValue } }
    }

    // MARK: - Publishers
    private let registrySubject = CurrentValueSubject<[String: TPPBookRegistryRecord], Never>([:])
    private let bookStateSubject = CurrentValueSubject<(String, TPPBookState), Never>(("", .unregistered))

    private var _isSyncing: Bool = false
    var isSyncing: Bool {
        get { lock.withLock { _isSyncing } }
        set { lock.withLock { _isSyncing = newValue } }
    }

    private var _myBooks: [TPPBook] = []
    var myBooks: [TPPBook] {
        get { lock.withLock { _myBooks } }
        set { lock.withLock { _myBooks = newValue } }
    }

    private var _state: TPPBookRegistry.RegistryState = .loaded
    var state: TPPBookRegistry.RegistryState {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }
    var registryState: TPPBookRegistry.RegistryState { state }

    var registryPublisher: AnyPublisher<[String: TPPBookRegistryRecord], Never> {
        registrySubject.eraseToAnyPublisher()
    }

    var bookStatePublisher: AnyPublisher<(String, TPPBookState), Never> {
        bookStateSubject.eraseToAnyPublisher()
    }

    private let syncStateSubject = CurrentValueSubject<Bool, Never>(false)
    var syncStatePublisher: AnyPublisher<Bool, Never> {
        syncStateSubject.eraseToAnyPublisher()
    }

    func sync(completion: ((_ errorDocument: [AnyHashable: Any]?, _ newBooks: Bool) -> Void)?) {
        completion?(nil, false)
    }

    func load() {}

    // MARK: - Mock Data Storage
    private var _registry = [String: TPPBookRegistryRecord]()
    var registry: [String: TPPBookRegistryRecord] {
        get { lock.withLock { _registry } }
        set { lock.withLock { _registry = newValue } }
    }
    private var _processingBooks = Set<String>()

    var heldBooks: [TPPBook] {
        lock.withLock {
            _registry.values
                .filter { $0.state == .holding }
                .map { $0.book }
        }
    }

    // MARK: - TPPBookRegistryProvider Methods

    func coverImage(for book: TPPBook, handler: @escaping (UIImage?) -> Void) {
        // Simulate fetching a cover image
        let mockImage = UIImage(systemName: "book.fill")
        handler(mockImage)
    }

    func setProcessing(_ processing: Bool, for bookIdentifier: String) {
        lock.withLock {
            if processing {
                _processingBooks.insert(bookIdentifier)
            } else {
                _processingBooks.remove(bookIdentifier)
            }
        }
    }

    func processing(forIdentifier bookIdentifier: String) -> Bool {
        lock.withLock { _processingBooks.contains(bookIdentifier) }
    }

    func state(for bookIdentifier: String?) -> TPPBookState {
        guard let bookIdentifier = bookIdentifier else { return .unregistered }
        return lock.withLock { _registry[bookIdentifier]?.state ?? .unregistered }
    }

    func readiumBookmarks(forIdentifier identifier: String) -> [TPPReadiumBookmark] {
        lock.withLock { _registry[identifier]?.readiumBookmarks ?? [] }
    }

    func setLocation(_ location: TPPBookLocation?, forIdentifier identifier: String) {
        lock.withLock { _registry[identifier]?.location = location }
    }

    func location(forIdentifier identifier: String) -> TPPBookLocation? {
        lock.withLock { _registry[identifier]?.location }
    }

    func add(_ bookmark: TPPReadiumBookmark, forIdentifier identifier: String) {
        lock.withLock { _registry[identifier]?.readiumBookmarks?.append(bookmark) }
    }

    func delete(_ bookmark: TPPReadiumBookmark, forIdentifier identifier: String) {
        lock.withLock { _registry[identifier]?.readiumBookmarks?.removeAll { $0 == bookmark } }
    }

    func replace(_ oldBookmark: TPPReadiumBookmark, with newBookmark: TPPReadiumBookmark, forIdentifier identifier: String) {
        lock.withLock {
            if let index = _registry[identifier]?.readiumBookmarks?.firstIndex(of: oldBookmark) {
                _registry[identifier]?.readiumBookmarks?[index] = newBookmark
            }
        }
    }

    func genericBookmarksForIdentifier(_ bookIdentifier: String) -> [TPPBookLocation] {
        lock.withLock { _registry[bookIdentifier]?.genericBookmarks ?? [] }
    }

    func addOrReplaceGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) {
        lock.withLock {
            if let index = _registry[bookIdentifier]?.genericBookmarks?.firstIndex(where: { $0.isSimilarTo(location) }) {
                _registry[bookIdentifier]?.genericBookmarks?[index] = location
            } else {
                _addGenericBookmark(location, forIdentifier: bookIdentifier)
            }
        }
    }

    func preloadData(bookIdentifier: String, locations: [TPPBookLocation]) {
        lock.withLock {
            _registry[bookIdentifier]?.genericBookmarks = []
            locations.forEach { _addGenericBookmark($0, forIdentifier: bookIdentifier) }
        }
    }

    func addGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) {
        lock.withLock { _addGenericBookmark(location, forIdentifier: bookIdentifier) }
    }

    /// Unlocked helper — callers MUST hold `lock`.
    private func _addGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) {
        _registry[bookIdentifier]?.genericBookmarks?.append(location)
    }

    func deleteGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) {
        lock.withLock { _registry[bookIdentifier]?.genericBookmarks?.removeAll { $0.isSimilarTo(location) } }
    }

    func replaceGenericBookmark(_ oldLocation: TPPBookLocation, with newLocation: TPPBookLocation, forIdentifier bookIdentifier: String) {
        lock.withLock {
            if let index = _registry[bookIdentifier]?.genericBookmarks?.firstIndex(where: { $0.isSimilarTo(oldLocation) }) {
                _registry[bookIdentifier]?.genericBookmarks?[index] = newLocation
            }
        }
    }

    func addBook(_ book: TPPBook, location: TPPBookLocation? = nil, state: TPPBookState, fulfillmentId: String? = nil, readiumBookmarks: [TPPReadiumBookmark]? = nil, genericBookmarks: [TPPBookLocation]? = nil) {
        let record = TPPBookRegistryRecord(
            book: book,
            location: location,
            state: state,
            fulfillmentId: fulfillmentId,
            readiumBookmarks: readiumBookmarks ?? [],
            genericBookmarks: genericBookmarks ?? []
        )
        let snapshot: [String: TPPBookRegistryRecord] = lock.withLock {
            _registry[book.identifier] = record
            return _registry
        }
        // Subject sends + notification post OUTSIDE the lock (re-entrancy rule).
        registrySubject.send(snapshot)
        bookStateSubject.send((book.identifier, state))

        // Simulate Notification (if real registry sends one)
        NotificationCenter.default.post(name: .TPPBookRegistryDidChange, object: nil)
    }

    func removeBook(forIdentifier bookIdentifier: String) {
        let snapshot: [String: TPPBookRegistryRecord] = lock.withLock {
            _registry.removeValue(forKey: bookIdentifier)
            return _registry
        }
        registrySubject.send(snapshot)
    }

    func updateAndRemoveBook(_ book: TPPBook) {
        let snapshot: [String: TPPBookRegistryRecord] = lock.withLock {
            _registry[book.identifier]?.book = book
            _registry.removeValue(forKey: book.identifier)
            return _registry
        }
        registrySubject.send(snapshot)
    }

    func setState(_ state: TPPBookState, for bookIdentifier: String) {
        lock.withLock { _registry[bookIdentifier]?.state = state }
        bookStateSubject.send((bookIdentifier, state))
    }

    func book(forIdentifier bookIdentifier: String?) -> TPPBook? {
        guard let bookIdentifier = bookIdentifier else { return nil }
        return lock.withLock { _registry[bookIdentifier]?.book }
    }

    func fulfillmentId(forIdentifier bookIdentifier: String?) -> String? {
        guard let bookIdentifier = bookIdentifier else { return nil }
        return lock.withLock { _registry[bookIdentifier]?.fulfillmentId }
    }

    func setFulfillmentId(_ fulfillmentId: String, for bookIdentifier: String) {
        lock.withLock { _registry[bookIdentifier]?.fulfillmentId = fulfillmentId }
    }

    func with(account: String, perform block: (_ registry: TPPBookRegistry) -> Void) {
        // Mock implementation does not support account-specific operations
    }

    // MARK: - Image Loading (for snapshot testing)

    /// Mock image storage for testing
    private var _mockImages: [String: UIImage] = [:]
    var mockImages: [String: UIImage] {
        get { lock.withLock { _mockImages } }
        set { lock.withLock { _mockImages = newValue } }
    }

    func cachedThumbnailImage(for book: TPPBook) -> UIImage? {
        lock.withLock { _mockImages[book.identifier] }
    }

    func thumbnailImage(for book: TPPBook?, handler: @escaping (UIImage?) -> Void) {
        guard let book = book else {
            handler(nil)
            return
        }
        // Return mock image or generate a placeholder
        if let cached = lock.withLock({ _mockImages[book.identifier] }) {
            handler(cached)
        } else {
            // Return a system image as placeholder
            handler(UIImage(systemName: "book.fill"))
        }
    }

    func thumbnailImages(forBooks books: Set<TPPBook>, handler: @escaping ([String: UIImage]) -> Void) {
        let result: [String: UIImage] = lock.withLock {
            var images: [String: UIImage] = [:]
            for book in books {
                if let img = _mockImages[book.identifier] {
                    images[book.identifier] = img
                }
            }
            return images
        }
        handler(result)
    }

    func updatedBookMetadata(_ book: TPPBook) -> TPPBook? {
        lock.withLock { _registry[book.identifier]?.book }
    }

    /// Helper to set a mock image for testing
    func setMockImage(_ image: UIImage, for bookIdentifier: String) {
        lock.withLock { _mockImages[bookIdentifier] = image }
    }
}

extension TPPBookRegistryMock: TPPBookRegistrySyncing {
    // MARK: - Syncing
    func reset(_ libraryAccountUUID: String) {
        lock.withLock {
            _resetCalledLibraryIDs.append(libraryAccountUUID)
            _isSyncing = false
            _registry.removeAll()
        }
    }

    func sync() {
        lock.withLock {
            _isSyncing = true
            // Mock completes synchronously - no delay needed for tests
            _isSyncing = false
        }
    }

    func save() {
        // No-op for mock
    }
}

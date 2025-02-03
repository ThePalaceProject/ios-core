import Foundation
import Combine
import UIKit

class TPPBookRegistryMock: NSObject, TPPBookRegistrySyncing, TPPBookRegistryProvider {

  // MARK: - Publishers
  var registryPublisher: AnyPublisher<[String: TPPBookRegistryRecord], Never> {
    registrySubject.eraseToAnyPublisher()
  }

  var bookStatePublisher: AnyPublisher<(String, TPPBookState), Never> {
    bookStateSubject.eraseToAnyPublisher()
  }

  private let registrySubject = CurrentValueSubject<[String: TPPBookRegistryRecord], Never>([:])
  private let bookStateSubject = PassthroughSubject<(String, TPPBookState), Never>()

  // MARK: - Mock Data
  var isSyncing = false
  private var registry = [String: TPPBookRegistryRecord]() {
    didSet {
      registrySubject.send(registry)
    }
  }
  private var processing = [String: Bool]()

  var allBooks: [TPPBook] {
    registry
      .map { $0.value }
      .filter { TPPBookStateHelper.allBookStates().contains($0.state.rawValue) }
      .map { $0.book }
  }

  // MARK: - Syncing
  func reset(_ libraryAccountUUID: String) {
    isSyncing = false
    registry.removeAll()
  }

  func sync() {
    isSyncing = true
    DispatchQueue.global(qos: .background).async {
      sleep(1) // Simulate syncing delay
      self.isSyncing = false
    }
  }

  func save() {
    // No-op for mock
  }

  // MARK: - Book Management
  func addBook(book: TPPBook, state: TPPBookState) {
    registry[book.identifier] = TPPBookRegistryRecord(book: book, location: nil, state: state, fulfillmentId: nil, readiumBookmarks: [], genericBookmarks: [])
    bookStateSubject.send((book.identifier, state))
  }

  func addBook(_ book: TPPBook, location: TPPBookLocation?, state: TPPBookState, fulfillmentId: String?, readiumBookmarks: [TPPReadiumBookmark]?, genericBookmarks: [TPPBookLocation]?) {
    registry[book.identifier] = TPPBookRegistryRecord(
      book: book,
      location: location,
      state: state,
      fulfillmentId: fulfillmentId,
      readiumBookmarks: readiumBookmarks ?? [],
      genericBookmarks: genericBookmarks ?? []
    )
    bookStateSubject.send((book.identifier, state))
  }

  func removeBook(forIdentifier bookIdentifier: String) {
    registry.removeValue(forKey: bookIdentifier)
  }

  func updateAndRemoveBook(_ book: TPPBook) {
    registry.removeValue(forKey: book.identifier)
  }

  func book(forIdentifier bookIdentifier: String?) -> TPPBook? {
    guard let bookIdentifier else { return nil }
    return registry[bookIdentifier]?.book
  }

  // MARK: - Book State Management
  func state(for bookIdentifier: String?) -> TPPBookState {
    guard let bookIdentifier else { return .unregistered }
    return registry[bookIdentifier]?.state ?? .unregistered
  }

  func setState(_ state: TPPBookState, for bookIdentifier: String) {
    registry[bookIdentifier]?.state = state
    bookStateSubject.send((bookIdentifier, state))
  }

  func setProcessing(_ processing: Bool, for bookIdentifier: String) {
    self.processing[bookIdentifier] = processing
  }

  // MARK: - Bookmark Management
  func readiumBookmarks(forIdentifier identifier: String) -> [TPPReadiumBookmark] {
    registry[identifier]?.readiumBookmarks?.sorted { $0.progressWithinBook < $1.progressWithinBook } ?? []
  }

  func add(_ bookmark: TPPReadiumBookmark, forIdentifier identifier: String) {
    guard registry[identifier] != nil else { return }
    if registry[identifier]?.readiumBookmarks == nil {
      registry[identifier]?.readiumBookmarks = []
    }
    registry[identifier]?.readiumBookmarks?.append(bookmark)
  }

  func delete(_ bookmark: TPPReadiumBookmark, forIdentifier identifier: String) {
    registry[identifier]?.readiumBookmarks?.removeAll { $0 == bookmark }
  }

  func replace(_ oldBookmark: TPPReadiumBookmark, with newBookmark: TPPReadiumBookmark, forIdentifier identifier: String) {
    delete(oldBookmark, forIdentifier: identifier)
    add(newBookmark, forIdentifier: identifier)
  }

  // MARK: - Generic Bookmarks
  func genericBookmarksForIdentifier(_ bookIdentifier: String) -> [TPPBookLocation] {
    registry[bookIdentifier]?.genericBookmarks ?? []
  }

  func addOrReplaceGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) {
    deleteGenericBookmark(location, forIdentifier: bookIdentifier)
    addGenericBookmark(location, forIdentifier: bookIdentifier)
  }

  func addGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) {
    if registry[bookIdentifier]?.genericBookmarks == nil {
      registry[bookIdentifier]?.genericBookmarks = []
    }
    registry[bookIdentifier]?.genericBookmarks?.append(location)
  }

  func deleteGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) {
    registry[bookIdentifier]?.genericBookmarks?.removeAll { $0.isSimilarTo(location) }
  }

  func replaceGenericBookmark(_ oldLocation: TPPBookLocation, with newLocation: TPPBookLocation, forIdentifier bookIdentifier: String) {
    deleteGenericBookmark(oldLocation, forIdentifier: bookIdentifier)
    addGenericBookmark(newLocation, forIdentifier: bookIdentifier)
  }

  // MARK: - Cover Image
  func coverImage(for book: TPPBook, handler: @escaping (UIImage?) -> Void) {
    let mockImage = UIImage(systemName: "book")
    handler(mockImage)
  }

  // MARK: - Fulfillment ID
  func fulfillmentId(forIdentifier bookIdentifier: String?) -> String? {
    guard let bookIdentifier else { return nil }
    return registry[bookIdentifier]?.fulfillmentId
  }

  func setFulfillmentId(_ fulfillmentId: String, for bookIdentifier: String) {
    registry[bookIdentifier]?.fulfillmentId = fulfillmentId
  }

  // MARK: - Helper
  func preloadData(bookIdentifier: String, locations: [TPPBookLocation]) {
    registry[bookIdentifier]?.genericBookmarks = []
    locations.forEach { addGenericBookmark($0, forIdentifier: bookIdentifier) }
  }

  func setLocation(_ location: TPPBookLocation?, forIdentifier identifier: String) {
  }

  func location(forIdentifier identifier: String) -> TPPBookLocation? {
    guard let record = registry[identifier] else { return nil }
    return record.location
  }

  func with(account: String, perform block: (Palace.TPPBookRegistry) -> Void) {
    NSLog("Uncompleted function")
  }
}

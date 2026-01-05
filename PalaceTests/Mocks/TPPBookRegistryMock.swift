import Foundation
import Combine
import UIKit
@testable import Palace

class TPPBookRegistryMock: NSObject, TPPBookRegistryProvider {

  // MARK: - Publishers
  private let registrySubject = CurrentValueSubject<[String: TPPBookRegistryRecord], Never>([:])
  private let bookStateSubject = CurrentValueSubject<(String, TPPBookState), Never>(("", .unregistered))
  var isSyncing: Bool = false

  var registryPublisher: AnyPublisher<[String: TPPBookRegistryRecord], Never> {
    registrySubject.eraseToAnyPublisher()
  }

  var bookStatePublisher: AnyPublisher<(String, TPPBookState), Never> {
    bookStateSubject.eraseToAnyPublisher()
  }

  // MARK: - Mock Data Storage
  var registry = [String: TPPBookRegistryRecord]()
  private var processingBooks = Set<String>()

  // MARK: - TPPBookRegistryProvider Methods

  func coverImage(for book: TPPBook, handler: @escaping (UIImage?) -> Void) {
    // Simulate fetching a cover image
    let mockImage = UIImage(systemName: "book.fill")
    handler(mockImage)
  }

  func setProcessing(_ processing: Bool, for bookIdentifier: String) {
    if processing {
      processingBooks.insert(bookIdentifier)
    } else {
      processingBooks.remove(bookIdentifier)
    }
  }

  func processing(forIdentifier bookIdentifier: String) -> Bool {
    processingBooks.contains(bookIdentifier)
  }

  func state(for bookIdentifier: String?) -> TPPBookState {
    guard let bookIdentifier = bookIdentifier else { return .unregistered }
    return registry[bookIdentifier]?.state ?? .unregistered
  }

  func readiumBookmarks(forIdentifier identifier: String) -> [TPPReadiumBookmark] {
    return registry[identifier]?.readiumBookmarks ?? []
  }

  func setLocation(_ location: TPPBookLocation?, forIdentifier identifier: String) {
    registry[identifier]?.location = location
  }

  func location(forIdentifier identifier: String) -> TPPBookLocation? {
    return registry[identifier]?.location
  }

  func add(_ bookmark: TPPReadiumBookmark, forIdentifier identifier: String) {
    registry[identifier]?.readiumBookmarks?.append(bookmark)
  }

  func delete(_ bookmark: TPPReadiumBookmark, forIdentifier identifier: String) {
    registry[identifier]?.readiumBookmarks?.removeAll { $0 == bookmark }
  }

  func replace(_ oldBookmark: TPPReadiumBookmark, with newBookmark: TPPReadiumBookmark, forIdentifier identifier: String) {
    if let index = registry[identifier]?.readiumBookmarks?.firstIndex(of: oldBookmark) {
      registry[identifier]?.readiumBookmarks?[index] = newBookmark
    }
  }

  func genericBookmarksForIdentifier(_ bookIdentifier: String) -> [TPPBookLocation] {
    return registry[bookIdentifier]?.genericBookmarks ?? []
  }

  func addOrReplaceGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) {
    if let index = registry[bookIdentifier]?.genericBookmarks?.firstIndex(where: { $0.isSimilarTo(location) }) {
      registry[bookIdentifier]?.genericBookmarks?[index] = location
    } else {
      registry[bookIdentifier]?.genericBookmarks?.append(location)
    }
  }

  func preloadData(bookIdentifier: String, locations: [TPPBookLocation]) {
    registry[bookIdentifier]?.genericBookmarks = []
    locations.forEach { addGenericBookmark($0, forIdentifier: bookIdentifier) }
  }

  func addGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) {
    registry[bookIdentifier]?.genericBookmarks?.append(location)
  }

  func deleteGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) {
    registry[bookIdentifier]?.genericBookmarks?.removeAll { $0.isSimilarTo(location) }
  }

  func replaceGenericBookmark(_ oldLocation: TPPBookLocation, with newLocation: TPPBookLocation, forIdentifier bookIdentifier: String) {
    if let index = registry[bookIdentifier]?.genericBookmarks?.firstIndex(where: { $0.isSimilarTo(oldLocation) }) {
      registry[bookIdentifier]?.genericBookmarks?[index] = newLocation
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
    registry[book.identifier] = record
    registrySubject.send(registry)
    bookStateSubject.send((book.identifier, state))

    // Simulate Notification (if real registry sends one)
    NotificationCenter.default.post(name: .TPPBookRegistryDidChange, object: nil)
  }

  func removeBook(forIdentifier bookIdentifier: String) {
    registry.removeValue(forKey: bookIdentifier)
    registrySubject.send(registry)
  }

  func updateAndRemoveBook(_ book: TPPBook) {
    registry[book.identifier]?.book = book
    registry.removeValue(forKey: book.identifier)
    registrySubject.send(registry)
  }

  func setState(_ state: TPPBookState, for bookIdentifier: String) {
    registry[bookIdentifier]?.state = state
    bookStateSubject.send((bookIdentifier, state))
  }

  func book(forIdentifier bookIdentifier: String?) -> TPPBook? {
    guard let bookIdentifier = bookIdentifier else { return nil }
    return registry[bookIdentifier]?.book
  }

  func fulfillmentId(forIdentifier bookIdentifier: String?) -> String? {
    guard let bookIdentifier = bookIdentifier else { return nil }
    return registry[bookIdentifier]?.fulfillmentId
  }

  func setFulfillmentId(_ fulfillmentId: String, for bookIdentifier: String) {
    registry[bookIdentifier]?.fulfillmentId = fulfillmentId
  }

  func with(account: String, perform block: (_ registry: TPPBookRegistry) -> Void) {
    // Mock implementation does not support account-specific operations
  }

  // MARK: - Image Loading (for snapshot testing)
  
  /// Mock image storage for testing
  var mockImages: [String: UIImage] = [:]
  
  func cachedThumbnailImage(for book: TPPBook) -> UIImage? {
    mockImages[book.identifier]
  }
  
  func thumbnailImage(for book: TPPBook?, handler: @escaping (UIImage?) -> Void) {
    guard let book = book else {
      handler(nil)
      return
    }
    // Return mock image or generate a placeholder
    if let cached = mockImages[book.identifier] {
      handler(cached)
    } else {
      // Return a system image as placeholder
      handler(UIImage(systemName: "book.fill"))
    }
  }
  
  /// Helper to set a mock image for testing
  func setMockImage(_ image: UIImage, for bookIdentifier: String) {
    mockImages[bookIdentifier] = image
  }
}

extension TPPBookRegistryMock: TPPBookRegistrySyncing {
  // MARK: - Syncing
  func reset(_ libraryAccountUUID: String) {
    isSyncing = false
    registry.removeAll()
  }

  func sync() {
    isSyncing = true
    // Mock completes synchronously - no delay needed for tests
    isSyncing = false
  }

  func save() {
    // No-op for mock
  }
}

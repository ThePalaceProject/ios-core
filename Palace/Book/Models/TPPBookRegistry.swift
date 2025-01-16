//
//  TPPBookRegistry.swift
//  Palace
//
//  Created by Vladimir Fedorov on 13.10.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation
import Combine
import UIKit

protocol TPPBookRegistryProvider {
  var registryPublisher: AnyPublisher<[String: TPPBookRegistryRecord], Never> { get }
  var bookStatePublisher: AnyPublisher<(String, TPPBookState), Never> { get }

  func coverImage(for book: TPPBook, handler: @escaping (_ image: UIImage?) -> Void)
  func setProcessing(_ processing: Bool, for bookIdentifier: String)
  func state(for bookIdentifier: String?) -> TPPBookState
  func readiumBookmarks(forIdentifier identifier: String) -> [TPPReadiumBookmark]
  func setLocation(_ location: TPPBookLocation?, forIdentifier identifier: String)
  func location(forIdentifier identifier: String) -> TPPBookLocation?
  func add(_ bookmark: TPPReadiumBookmark, forIdentifier identifier: String)
  func delete(_ bookmark: TPPReadiumBookmark, forIdentifier identifier: String)
  func replace(_ oldBookmark: TPPReadiumBookmark, with newBookmark: TPPReadiumBookmark, forIdentifier identifier: String)
  func genericBookmarksForIdentifier(_ bookIdentifier: String) -> [TPPBookLocation]
  func addOrReplaceGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String)
  func addGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String)
  func deleteGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String)
  func replaceGenericBookmark(_ oldLocation: TPPBookLocation, with newLocation: TPPBookLocation, forIdentifier: String)
  func addBook(_ book: TPPBook, location: TPPBookLocation?, state: TPPBookState, fulfillmentId: String?, readiumBookmarks: [TPPReadiumBookmark]?, genericBookmarks: [TPPBookLocation]?)
  func removeBook(forIdentifier bookIdentifier: String)
  func updateAndRemoveBook(_ book: TPPBook)
  func setState(_ state: TPPBookState, for bookIdentifier: String)
  func book(forIdentifier bookIdentifier: String?) -> TPPBook?
  func fulfillmentId(forIdentifier bookIdentifier: String?) -> String?
  func setFulfillmentId(_ fulfillmentId: String, for bookIdentifier: String)
  func with(account: String, perform block: (_ registry: TPPBookRegistry) -> Void)
}

typealias TPPBookRegistryData = [String: Any]

extension TPPBookRegistryData {
  func value(for key: TPPBookRegistryKey) -> Any? {
    return self[key.rawValue]
  }
  mutating func setValue(_ value: Any?, for key: TPPBookRegistryKey) {
    self[key.rawValue] = value
  }
  func object(for key: TPPBookRegistryKey) -> TPPBookRegistryData? {
    self[key.rawValue] as? TPPBookRegistryData
  }
  func array(for key: TPPBookRegistryKey) -> [TPPBookRegistryData]? {
    self[key.rawValue] as? [TPPBookRegistryData]
  }
}

enum TPPBookRegistryKey: String {
  case records = "records"

  case book = "metadata"
  case state = "state"
  case fulfillmentId = "fulfillmentId"
  case location = "location"
  case readiumBookmarks = "bookmarks"
  case genericBookmarks = "genericBookmarks"

}

fileprivate class BoolWithDelay {
  private var switchBackDelay: Double
  private var resetTask: DispatchWorkItem?
  private var onChange: ((_ value: Bool) -> Void)?

  init(delay: Double = 5, onChange: ((_ value: Bool) -> Void)? = nil) {
    self.switchBackDelay = delay
    self.onChange = onChange
  }
  
  var value: Bool = false {
    willSet {
      if value != newValue {
        onChange?(newValue)
      }
    }
    didSet {
      resetTask?.cancel()
      if value {
        let task = DispatchWorkItem { [weak self] in
          self?.value = false
        }
        resetTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + switchBackDelay, execute: task)
      }
    }
  }
}

@objcMembers
class TPPBookRegistry: NSObject {
  
  @objc
  enum RegistryState: Int {
    case unloaded, loading, loaded, syncing
  }
  
  private let registryFolderName = "registry"
  private let registryFileName = "registry.json"
  
  // Reloads book registry when library account is changed.
  private var accountDidChange = NotificationCenter.default.publisher(for: .TPPCurrentAccountDidChange)
    .receive(on: RunLoop.main)
    .sink { _ in
      TPPBookRegistry.shared.load()
      TPPBookRegistry.shared.sync()
    }
  
  /// Book registry with book identifiers as keys.
  private var registry = [String: TPPBookRegistryRecord]() {
    didSet {
      registrySubject.send(registry)
      NotificationCenter.default.post(name: .TPPBookRegistryDidChange, object: nil, userInfo: nil)
    }
  }
  
  private var coverRegistry = TPPBookCoverRegistry()
  private let syncQueue = DispatchQueue(label: "com.palace.syncQueue")

  /// Book identifiers that are being processed.
  private var processingIdentifiers = Set<String>()
  
  static let shared = TPPBookRegistry()

  private let registrySubject = CurrentValueSubject<[String: TPPBookRegistryRecord], Never>([:])
  private let bookStateSubject = PassthroughSubject<(String, TPPBookState), Never>()

  var registryPublisher: AnyPublisher<[String: TPPBookRegistryRecord], Never> {
    registrySubject.eraseToAnyPublisher()
  }
  var bookStatePublisher: AnyPublisher<(String, TPPBookState), Never> {
    bookStateSubject.eraseToAnyPublisher()
  }
  /// Identifies that the synchronsiation process is going on.
  private(set) var isSyncing: Bool
  {
    get {
      syncState.value
    }
    set { }
  }
  
  /// `syncState` switches back after a delay to prevent locking in synchronization state
  private var syncState = BoolWithDelay { value in
    if value {
      NotificationCenter.default.post(name: .TPPSyncBegan, object: nil, userInfo: nil)
    } else {
      NotificationCenter.default.post(name: .TPPSyncEnded, object: nil, userInfo: nil)
    }
  }
  
  private(set) var state: RegistryState  = .unloaded {
    didSet {
      syncState.value = state == .syncing
      NotificationCenter.default.post(name: .TPPBookRegistryStateDidChange, object: nil, userInfo: nil)
    }
  }

  /// Keeps loans URL of current synchronisation process.
  /// TPPBookRegistry is a shared object, this value is used to cancel synchronisation callback when the user changes library account.
  private var syncUrl: URL?
  
  private override init() {
    super.init()
    
  }
  
  fileprivate init(account: String) {
    super.init()
    load(account: account)
  }
  
  /// Performs a block of operations on the provided account.
  /// - Parameters:
  ///   - account: Library account identifier.
  ///   - block: Provides registry object for the provided account.
  func with(account: String, perform block: (_ registry: TPPBookRegistry) -> Void) {
    block(TPPBookRegistry(account: account))
  }
  
  /// Registry file URL.
  /// - Parameter account: Library account identifier.
  /// - Returns: Registry file URL.
  func registryUrl(for account: String) -> URL? {
    TPPBookContentMetadataFilesHelper.directory(for: account)?
      .appendingPathComponent(registryFolderName)
      .appendingPathComponent(registryFileName)
  }
  
  /// Loads the book registry for the provided library account.
  /// - Parameter account: Library account identifier.
  func load(account: String? = nil) {
    guard let account = account ?? AccountsManager.shared.currentAccountId,
          let registryFileUrl = self.registryUrl(for: account)
    else {
      return
    }
    state = .loading
    registry.removeAll()
    if FileManager.default.fileExists(atPath: registryFileUrl.path),
      let registryData = try? Data(contentsOf: registryFileUrl),
      let jsonObject = try? JSONSerialization.jsonObject(with: registryData),
      let registryObject = jsonObject as? TPPBookRegistryData {
      if let records = registryObject.array(for: .records) {
        for recordObject in records {
          guard let record = TPPBookRegistryRecord(record: recordObject) else {
            continue
          }
          if record.state == .Downloading || record.state == .SAMLStarted {
            record.state = .DownloadFailed
          }
          self.registry[record.book.identifier] = record
        }
      }
    }
    state = .loaded
  }
  
  /// Removes registry data.
  /// - Parameter account: Library account identifier.
  func reset(_ account: String) {
    state = .unloaded
    syncUrl = nil
    registry.removeAll()
    if let registryUrl = registryUrl(for: account) {
      do {
        try FileManager.default.removeItem(at: registryUrl)
      } catch {
        Log.error(#file, "Error deleting registry data: \(error.localizedDescription)")
      }
    }
  }
  
  /// Synchronizes local registry data and current loans data.
  /// - Parameter completion: Completion handler provides an error document for error handling and a boolean value, indicating the presence of books available for download.
  func sync(completion: ((_ errorDocument: [AnyHashable: Any]?, _ newBooks: Bool) -> Void)? = nil) {
    guard let loansUrl = AccountsManager.shared.currentAccount?.loansUrl else {
      return
    }
    
    state = .syncing
    syncUrl = loansUrl
    
    TPPOPDSFeed.withURL(loansUrl, shouldResetCache: true, useTokenIfAvailable: true) { feed, errorDocument in
      DispatchQueue.main.async {
        defer {
          self.state = .loaded
          self.syncUrl = nil
        }
        
        if self.syncUrl != loansUrl {
          return
        }
        if let errorDocument {
          completion?(errorDocument, false)
          return
        }
        guard let feed else {
          completion?(nil, false)
          return
        }
        if let licensor = feed.licensor as? [String: Any] {
          TPPUserAccount.sharedAccount().setLicensor(licensor)
        }
        
        self.syncQueue.sync {
          var recordsToDelete = Set<String>(self.registry.keys.map { $0 as String })
          for entry in feed.entries {
            guard let opdsEntry = entry as? TPPOPDSEntry,
                  let book = TPPBook(entry: opdsEntry) else {
              continue
            }
            recordsToDelete.remove(book.identifier)
            if let existingRecord = self.registry[book.identifier] {
              self.updateBook(book)
            } else {
              self.addBook(book)
            }
          }
          
          // Handle expired books
          recordsToDelete.forEach { identifier in
            if let state = self.registry[identifier]?.state, state == .DownloadSuccessful || state == .Used {
              MyBooksDownloadCenter.shared.deleteLocalContent(for: identifier)
            }
            self.registry[identifier]?.state = .Unregistered
            self.removeBook(forIdentifier: identifier)
          }
          
          self.save()
        }
        
        self.myBooks.forEach { book in
          book.defaultAcquisition?.availability.matchUnavailable({ _ in
            MyBooksDownloadCenter.shared.returnBook(withIdentifier: book.identifier)
            self.removeBook(forIdentifier: book.identifier)
          }, limited: { limited in
            if let until = limited.until, until.timeIntervalSinceNow <= 0 {
              MyBooksDownloadCenter.shared.returnBook(withIdentifier: book.identifier)
              self.removeBook(forIdentifier: book.identifier)
            }
          }, unlimited: nil, reserved: nil, ready: { ready in
            if let until = ready.until, until.timeIntervalSinceNow <= 0 {
              MyBooksDownloadCenter.shared.returnBook(withIdentifier: book.identifier)
              self.removeBook(forIdentifier: book.identifier)
            }
          })
        }
      }
    }
  }

  /// Saves book registry data.
  private func save() {
    guard let account = AccountsManager.shared.currentAccount?.uuid,
          let registryUrl = registryUrl(for: account)
    else {
      return
    }
    do {
      if !FileManager.default.fileExists(atPath: registryUrl.path) {
        try FileManager.default.createDirectory(at: registryUrl.deletingLastPathComponent(), withIntermediateDirectories: true)
      }
      let registryValues = registry.values.map { $0.dictionaryRepresentation } //.withNullValues() }
      let registryObject = [TPPBookRegistryKey.records.rawValue: registryValues]
      let registryData = try JSONSerialization.data(withJSONObject: registryObject, options: .fragmentsAllowed)
      try registryData.write(to: registryUrl, options: .atomic)
      NotificationCenter.default.post(name: .TPPBookRegistryDidChange, object: nil, userInfo: nil)
    } catch {
      Log.error(#file, "Error saving book registry: \(error.localizedDescription)")
    }
  }
  
  // For Objective-C code
  func load() {
    load(account: nil)
  }
  func sync() {
    sync(completion: nil)
  }

  
  // MARK: - Books
  
  /// Returns all registered books.
  var allBooks: [TPPBook] {
    registry
      .map { $0.value }
      .filter { TPPBookStateHelper.allBookStates().contains($0.state.rawValue) }
      .map { $0.book }
  }
  
  /// Returns all books that are on hold.
  var heldBooks: [TPPBook] {
    registry
      .map { $0.value }
      .filter { $0.state == .Holding }
      .map { $0.book }
  }
  
  /// Returns all books not on hold (borrowed or kept).
  var myBooks: [TPPBook] {
    let matchingStates: [TPPBookState] = [
      .DownloadNeeded, .Downloading, .SAMLStarted, .DownloadFailed, .DownloadSuccessful, .Used
    ]
    return registry
      .map { $0.value }
      .filter { matchingStates.contains($0.state) }
      .map { $0.book }
  }
  
  /// Adds a book to the book registry until it is manually removed. It allows the application to
  /// present information about obtained books when offline. Attempting to add a book already present
  /// will overwrite the existing book as if `updateBook` were called. The location may be nil. The
  /// state provided must be one of `TPPBookState` and must not be `TPPBookState.Unregistered`.
  func addBook(_ book: TPPBook, location: TPPBookLocation? = nil, state: TPPBookState = .DownloadNeeded, fulfillmentId: String? = nil, readiumBookmarks: [TPPReadiumBookmark]? = nil, genericBookmarks: [TPPBookLocation]? = nil) {
    // Cache the thumbnail image if it exists
    DispatchQueue.main.async { [weak self] in
      self?.coverRegistry.thumbnailImageForBook(book) { _ in
        // The image is automatically cached by `thumbnailImageForBook`, so no need to handle it here
      }
    }

    // Create and store the book record in the registry
    registry[book.identifier] = TPPBookRegistryRecord(
      book: book,
      location: location,
      state: state,
      fulfillmentId: fulfillmentId,
      readiumBookmarks: readiumBookmarks,
      genericBookmarks: genericBookmarks
    )
    
    // Save the registry data
    save()
  }
  
  func updateAndRemoveBook(_ book: TPPBook) {
    guard let existingRecord = registry[book.identifier] else {
      return
    }
    
    // Remove the pinned thumbnail image if cached
    coverRegistry.cachedThumbnailImageForBook(book)
    
    // Update the book in the registry, set it to unregistered, and then save the changes
    existingRecord.book = book
    existingRecord.state = .Unregistered
    
    // Save the updated registry
    save()
  }
  
  func removeBook(forIdentifier bookIdentifier: String) {
    // Remove the pinned thumbnail image if cached
    if let book = registry[bookIdentifier]?.book {
      coverRegistry.cachedThumbnailImageForBook(book)
    }
    
    // Remove the book from the registry
    registry.removeValue(forKey: bookIdentifier)
    
    // Save the updated registry
    save()
  }

  
  /// This method should be called whenever new book information is retrieved from a server. Doing so
  /// ensures that once the user has seen the new information, they will continue to do so when
  /// accessing the application off-line or when viewing books outside of the catalog. Attempts to
  /// update a book not already stored in the registry will simply be ignored, so it's reasonable to
  /// call this method whenever new information is obtained regardless of a given book's state.
  func updateBook(_ book: TPPBook) {
    guard let record = registry[book.identifier] else {
      return
    }
    TPPUserNotifications.compareAvailability(cachedRecord: record, andNewBook: book)
    // TPPBookRegistryRecord.init() contains logics for correct record updates
    registry[book.identifier] = TPPBookRegistryRecord(
      book: book,
      location: record.location,
      state: record.state,
      fulfillmentId: record.fulfillmentId,
      readiumBookmarks: record.readiumBookmarks,
      genericBookmarks: record.genericBookmarks
    )
  }
  
  /// Updates book metadata (e.g., from OPDS feed) in the registry and returns the updated book.
  func updatedBookMetadata(_ book: TPPBook) -> TPPBook? {
    guard let bookRecord = registry[book.identifier] else {
      return nil
    }
    let updatedBook = bookRecord.book.bookWithMetadata(from: book)
    registry[book.identifier]?.book = updatedBook
    save()
    return updatedBook
  }

  /// Returns the state of a book given its identifier.
  func state(for bookIdentifier: String?) -> TPPBookState {
    guard let bookIdentifier = bookIdentifier, !bookIdentifier.isEmpty else {
      return .Unregistered
    }

    guard let record = registry[bookIdentifier] else {
      return .Unregistered
    }

    return record.state
  }
  /// Sets the state for a book previously registered given its identifier.
  func setState(_ state: TPPBookState, for bookIdentifier: String) {
    registry[bookIdentifier]?.state = state
    bookStateSubject.send((bookIdentifier, state))
    postStateNotification(bookIdentifier: bookIdentifier, state: state)
    save()
  }

  @available(*, deprecated, message: "Use Combine publishers instead.")
  private func postStateNotification(bookIdentifier: String, state: TPPBookState) {
    NotificationCenter.default.post(
      name: .TPPBookRegistryStateDidChange,
      object: nil,
      userInfo: [
        "bookIdentifier": bookIdentifier,
        "state": state.rawValue
      ]
    )
  }

  /// Returns the book for a given identifier if it is registered, else nil.
  func book(forIdentifier bookIdentifier: String?) -> TPPBook? {
    guard let bookIdentifier = bookIdentifier, !bookIdentifier.isEmpty,
          let record = registry[bookIdentifier] else {
      return nil
    }
    return record.book
  }

  /// Sets the fulfillmentId for a book previously registered given its identifier.
  func setFulfillmentId(_ fulfillmentId: String, for bookIdentifier: String) {
    registry[bookIdentifier]?.fulfillmentId = fulfillmentId
    save()
  }

  /// Returns the fulfillmentId of a book given its identifier.
  func fulfillmentId(forIdentifier bookIdentifier: String?) -> String? {
    guard let bookIdentifier = bookIdentifier, !bookIdentifier.isEmpty,
          let record = registry[bookIdentifier] else {
      return nil
    }
    return record.fulfillmentId
  }

  /// Sets the processing flag for a book previously registered given its identifier.
  func setProcessing(_ processing: Bool, for bookIdentifier: String) {
    if processing {
      processingIdentifiers.insert(bookIdentifier)
    } else {
      processingIdentifiers.remove(bookIdentifier)
    }
    NotificationCenter.default.post(name: .TPPBookProcessingDidChange, object: nil, userInfo: [
      TPPNotificationKeys.bookProcessingBookIDKey: bookIdentifier,
      TPPNotificationKeys.bookProcessingValueKey: processing
    ])
  }
  
  /// Returns whether a book is processing something, given its identifier.
  func processing(forIdentifier bookIdentifier: String) -> Bool {
    processingIdentifiers.contains(bookIdentifier)
  }

  
  // MARK: - Book Cover
  
  /// Immediately returns the cached thumbnail if available, else nil. Generated images are not
  /// returned. The book does not have to be registered in order to retrieve a cover.
  func cachedThumbnailImage(for book: TPPBook) -> UIImage? {
    return coverRegistry.cachedThumbnailImageForBook(book)
  }
  
  /// Returns the thumbnail for a book via a handler called on the main thread. The book does not have
  /// to be registered in order to retrieve a cover.
  @MainActor
  func thumbnailImage(for book: TPPBook?, handler: @escaping (_ image: UIImage?) -> Void) {
    guard let book else {
      handler(nil)
      return
    }
    coverRegistry.thumbnailImageForBook(book, handler: handler)
  }

  /// The dictionary passed to the handler maps book identifiers to images.
  /// The handler is always called on the main thread.
  /// The books do not have to be registered in order to retrieve covers.
  @MainActor
  func thumbnailImages(forBooks books: Set<TPPBook>, handler: @escaping (_ bookIdentifiersToImages: [String: UIImage]) -> Void) {
    coverRegistry.thumbnailImagesForBooks(books, handler: handler)
  }
  
  /// Returns cover image if it exists, or falls back to thumbnail image load.
  @MainActor func coverImage(for book: TPPBook, handler: @escaping (_ image: UIImage?) -> Void) {
    coverRegistry.coverImageForBook(book, handler: handler)
  }
}

// MARK: - TPPBookRegistryProvider

extension TPPBookRegistry: TPPBookRegistryProvider {
  
  /// Sets the location for a book previously registered given its identifier.
  func setLocation(_ location: TPPBookLocation?, forIdentifier bookIdentifier: String) {
    guard !bookIdentifier.isEmpty else { return }
    registry[bookIdentifier]?.location = location
    save()
  }

  /// Returns the location of a book given its identifier.
  func location(forIdentifier bookIdentifier: String) -> TPPBookLocation? {
    guard let record = registry[bookIdentifier] else {
      return nil
    }
    return record.location
  }

  /// Returns the bookmarks for a book given its identifier.
  func readiumBookmarks(forIdentifier bookIdentifier: String) -> [TPPReadiumBookmark] {
    guard let record = registry[bookIdentifier] else {
      return []
    }
    return record.readiumBookmarks?.sorted { $0.progressWithinBook < $1.progressWithinBook } ?? []
  }

  /// Adds bookmark for a book given its identifier
  func add(_ bookmark: TPPReadiumBookmark, forIdentifier bookIdentifier: String) {
    guard registry[bookIdentifier] != nil else {
      return
    }
    if registry[bookIdentifier]?.readiumBookmarks == nil {
      registry[bookIdentifier]?.readiumBookmarks = [TPPReadiumBookmark]()
    }
    registry[bookIdentifier]?.readiumBookmarks?.append(bookmark)
    save()
  }
  
  /// Deletes bookmark for a book given its identifer.
  func delete(_ bookmark: TPPReadiumBookmark, forIdentifier bookIdentifier: String) {
    registry[bookIdentifier]?.readiumBookmarks?.removeAll { $0 == bookmark }
    save()
  }
  
  /// Replace a bookmark with another, given its identifer.
  func replace(_ oldBookmark: TPPReadiumBookmark, with newBookmark: TPPReadiumBookmark, forIdentifier bookIdentifier: String) {
    registry[bookIdentifier]?.readiumBookmarks?.removeAll { $0 == oldBookmark }
    registry[bookIdentifier]?.readiumBookmarks?.append(newBookmark)
    save()
  }
  
  // MARK: - Generic Bookmarks
  
  /// Returns the generic bookmarks for a any renderer's bookmarks given its identifier
  func genericBookmarksForIdentifier(_ bookIdentifier: String) -> [TPPBookLocation] {
    registry[bookIdentifier]?.genericBookmarks ?? []
  }
  
  func addOrReplaceGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) {
    guard registry[bookIdentifier] != nil else { return }
    
    if registry[bookIdentifier]?.genericBookmarks == nil {
      registry[bookIdentifier]?.genericBookmarks = [TPPBookLocation]()
    }
    
    deleteGenericBookmark(location, forIdentifier: bookIdentifier)
    addGenericBookmark(location, forIdentifier: bookIdentifier)
    save()
  }
  
  /// Adds a generic bookmark (book location) for a book given its identifier
  func addGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) {
    registry[bookIdentifier]?.genericBookmarks?.append(location)
    save()
  }
  
   /// Deletes a generic bookmark (book location) for a book given its identifier
  func deleteGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) {
    registry[bookIdentifier]?.genericBookmarks?.removeAll { $0.isSimilarTo(location) }
    save()
  }
  
  func replaceGenericBookmark(_ oldLocation: TPPBookLocation, with newLocation: TPPBookLocation, forIdentifier bookIdentifier: String) {
    deleteGenericBookmark(oldLocation, forIdentifier: bookIdentifier)
    addGenericBookmark(newLocation, forIdentifier: bookIdentifier)
  }
}

extension TPPBookLocation {
  
  func locationStringDictionary() -> [String: Any]? {
    guard let data = locationString.data(using: .utf8),
            let dictionary = try? JSONSerialization.jsonObject(with: data, options: .allowFragments) as? [String: Any]
    else { return nil }
    
    return dictionary
  }

  func isSimilarTo(_ location: TPPBookLocation) -> Bool {
    guard renderer == location.renderer,
          let locationDict = locationStringDictionary(),
          let otherLocationDict = location.locationStringDictionary() else {
      return false
    }
    
    // Keys to be excluded from the comparison.
    let excludedKeys = ["timeStamp", "annotationId"]
    
    // Prepare dictionaries excluding the keys not relevant for comparison.
    let filteredDict = locationDict.filter { !excludedKeys.contains($0.key) }
    let filteredOtherDict = otherLocationDict.filter { !excludedKeys.contains($0.key) }
    
    // Compare the filtered dictionaries.
    return NSDictionary(dictionary: filteredDict).isEqual(to: filteredOtherDict)
  }
}

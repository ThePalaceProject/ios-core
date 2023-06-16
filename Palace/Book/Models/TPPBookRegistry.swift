//
//  TPPBookRegistry.swift
//  Palace
//
//  Created by Vladimir Fedorov on 13.10.2022.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import Foundation
import UIKit

protocol TPPBookRegistryProvider {
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
      NotificationCenter.default.post(name: .TPPBookRegistryDidChange, object: nil, userInfo: nil)
    }
  }
  
  private var coverRegistry = TPPBookCoverRegistry()
  
  /// Book identifiers that are being processed.
  private var processingIdentifiers = Set<String>()
  
  static let shared = TPPBookRegistry()
  
  /// Identifies that the synchronsiation process is going on.
  private(set) var isSyncing = false {
    didSet {
      if isSyncing {
        NotificationCenter.default.post(name: .TPPSyncBegan, object: nil, userInfo: nil)
      } else {
        NotificationCenter.default.post(name: .TPPSyncEnded, object: nil, userInfo: nil)
      }
    }
  }
  
  private(set) var state: RegistryState  = .unloaded {
    didSet {
      isSyncing = state == .syncing
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
    if syncUrl == loansUrl {
      return
    }
    state = .syncing
    syncUrl = loansUrl
    TPPOPDSFeed.withURL(loansUrl, shouldResetCache: true) { feed, errorDocument in
      DispatchQueue.main.async {
        defer {
          self.state = .loaded
          self.syncUrl = nil
        }
        if self.syncUrl != loansUrl {
          return
        }
        if let errorDocument = errorDocument {
          completion?(errorDocument, false)
          return
        }
        guard let feed = feed else {
          completion?(nil, false)
          return
        }
        if let licensor = feed.licensor as? [String: Any] {
          TPPUserAccount.sharedAccount().setLicensor(licensor)
        }
        var recordsToDelete = Set<String>(self.registry.keys.map { $0 as String })
        for entry in feed.entries {
          guard let opdsEntry = entry as? TPPOPDSEntry,
                let book = TPPBook(entry: opdsEntry)
          else {
            continue
          }
          recordsToDelete.remove(book.identifier)
          if self.registry[book.identifier] != nil {
            self.updateBook(book)
          } else {
            self.addBook(book)
          }
        }
        recordsToDelete.forEach {
          if let state = self.registry[$0]?.state, state == .DownloadSuccessful || state == .Used {
            TPPMyBooksDownloadCenter.shared().deleteLocalContent(forBookIdentifier: $0)
          }
          self.registry[$0] = nil
        }
        self.save()
        
        // Count new books
        var readyBooks = 0
        self.heldBooks.forEach { book in
          book.defaultAcquisition?.availability.matchUnavailable(nil, limited: nil, unlimited: nil, reserved: nil, ready: { _ in
            readyBooks += 1
          })
        }
        if UIApplication.shared.applicationIconBadgeNumber != readyBooks {
          UIApplication.shared.applicationIconBadgeNumber = readyBooks
        }
        completion?(nil, readyBooks > 0)
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
    coverRegistry.pinThumbnailImageForBook(book)
    registry[book.identifier] = TPPBookRegistryRecord(book: book, location: location, state: state, fulfillmentId: fulfillmentId, readiumBookmarks: readiumBookmarks, genericBookmarks: genericBookmarks)
    save()
  }
  
  /// This will update the book like updateBook does, but will also set its state to unregistered, then
  /// broadcast the change, then remove the book from the registry. This gives any views using the book
  /// a chance to update their copy with the new one, without having to keep it in the registry after.
  func updateAndRemoveBook(_ book: TPPBook) {
    guard registry[book.identifier] != nil else {
      return
    }
    coverRegistry.removePinnedThumbnailImageForBookIdentifier(book.identifier)
    registry[book.identifier]?.book = book
    registry[book.identifier]?.state = .Unregistered
    save()
  }

  /// Given an identifier, this method removes a book from the registry.
  func removeBook(forIdentifier bookIdentifier: String) {
    coverRegistry.removePinnedThumbnailImageForBookIdentifier(bookIdentifier)
    registry.removeValue(forKey: bookIdentifier)
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
    registry[book.identifier]?.book = book
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
  func state(for bookIdentifier: String) -> TPPBookState {
    return registry[bookIdentifier]?.state ?? .Unregistered
  }
  
  /// Sets the state for a book previously registered given its identifier.
  func setState(_ state: TPPBookState, for bookIdentifier: String) {
    registry[bookIdentifier]?.state = state
    save()
  }
  
  /// Returns the book for a given identifier if it is registered, else nil.
  func book(forIdentifier bookIdentifier: String) -> TPPBook? {
    registry[bookIdentifier]?.book
  }
  
  /// Sets the fulfillmentId for a book previously registered given its identifier.
  func setFulfillmentId(_ fulfillmentId: String, for bookIdentifier: String) {
    registry[bookIdentifier]?.fulfillmentId = fulfillmentId
    save()
  }

  /// Returns the fulfillmentId of a book given its identifier.
  func fulfillmentId(forIdentifier bookIdentifier: String) -> String? {
    registry[bookIdentifier]?.fulfillmentId
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
  func thumbnailImage(for book: TPPBook, handler: @escaping (_ image: UIImage?) -> Void) {
    coverRegistry.thumbnailImageForBook(book, handler: handler)
  }

  /// The dictionary passed to the handler maps book identifiers to images.
  /// The handler is always called on the main thread.
  /// The books do not have to be registered in order to retrieve covers.
  func thumbnailImages(forBooks books: Set<TPPBook>, handler: @escaping (_ bookIdentifiersToImages: [String: UIImage]) -> Void) {
    coverRegistry.thumbnailImagesForBooks(books, handler: handler)
  }
  
  /// Returns cover image if it exists, or falls back to thumbnail image load.
  func coverImage(for book: TPPBook, handler: @escaping (_ image: UIImage?) -> Void) {
    coverRegistry.coverImageForBook(book, handler: handler)
  }
}

// MARK: - TPPBookRegistryProvider

extension TPPBookRegistry: TPPBookRegistryProvider {
  
  /// Sets the location for a book previously registered given its identifier.
  func setLocation(_ location: TPPBookLocation?, forIdentifier bookIdentifier: String) {
    registry[bookIdentifier]?.location = location
    save()
  }
  
  /// Returns the location of a book given its identifier.
  func location(forIdentifier bookIdentifier: String) -> TPPBookLocation? {
    registry[bookIdentifier]?.location
  }
  
  /// Returns the bookmarks for a book given its identifier.
  func readiumBookmarks(forIdentifier bookIdentifier: String) -> [TPPReadiumBookmark] {
    registry[bookIdentifier]?.readiumBookmarks?
      .sorted { $0.progressWithinBook < $1.progressWithinBook } ?? []
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
    guard let existingBookmark = registry[bookIdentifier]?.genericBookmarks?.first(where: { $0 == location }) else {
      addGenericBookmark(location, forIdentifier: bookIdentifier)
      return
    }

    replaceGenericBookmark(existingBookmark, with: location, forIdentifier: bookIdentifier)
  }
  
  /// Adds a generic bookmark (book location) for a book given its identifier
  func addGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) {
    guard registry[bookIdentifier] != nil else {
      return
    }

    if registry[bookIdentifier]?.genericBookmarks == nil {
      registry[bookIdentifier]?.genericBookmarks = [TPPBookLocation]()
    }
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
    registry[bookIdentifier]?.genericBookmarks?.append(newLocation)
    save()
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
          let otherLocationDict = location.locationStringDictionary()
    else { return false }
            
    var areEqual = true
    
    for (key, value) in locationDict {
      if key == "lastSavedTimeStamp" { continue }
      
      if let otherValue = otherLocationDict[key] {
        if "\(value)" != "\(otherValue)" {
          areEqual = false
          break
        }
      } else {
        areEqual = false
        break
      }
    }
    
    return areEqual
  }
}

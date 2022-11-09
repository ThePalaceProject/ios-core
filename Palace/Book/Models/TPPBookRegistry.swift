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
}

typealias TPPBookRegistryData = [String: Any]

extension TPPBookRegistryData {
  func value(for key: TPPBookRegistryKey) -> Any? {
    return self[key.rawValue]
  }
  mutating func setValue(_ value: AnyHashable, for key: TPPBookRegistryKey) {
    self[key.rawValue] = value
  }
  func object(for key: TPPBookRegistryKey) -> TPPBookRegistryData? {
    self[key.rawValue] as? TPPBookRegistryData
  }
  mutating func setObject(_ object: TPPBookRegistryData, for key: TPPBookRegistryKey) {
    self[key.rawValue] = object
  }
  func array(for key: TPPBookRegistryKey) -> [TPPBookRegistryData]? {
    self[key.rawValue] as? [TPPBookRegistryData]
  }
  mutating func setArray(_ array: [TPPBookRegistryData], for key: TPPBookRegistryKey) {
    self[key.rawValue] = array
  }
}

enum TPPBookRegistryKey: String {
  case records = "records"

  case book = "metadata"
  case state = "state"
  case fulfillmentId = "fulfillmentId"
  case readiumBookmarks = "bookmarks"
  case genericBookmarks = "genericBookmarks"

}

@objcMembers
class TPPBookRegistry: NSObject {
  
  private let registryFolderName = "registry"
  private let registryFileName = "registry.json"

  private var accountDidChange = NotificationCenter.default.publisher(for: .TPPCurrentAccountDidChange)
    .receive(on: RunLoop.main)
    .sink { _ in
      TPPBookRegistry.shared.load()
    }
  
  private var registry = [String: TPPBookRegistryRecord]() {
    didSet {
      NotificationCenter.default.post(name: .TPPBookRegistryDidChange, object: nil, userInfo: nil)
    }
  }
  
  private var coverRegistry = TPPBookCoverRegistry()
  
  private var processingIdentifiers = Set<String>()
  
  static let shared = TPPBookRegistry()
  
  private(set) var isSyncing = false {
    didSet {
      if isSyncing {
        NotificationCenter.default.post(name: .TPPSyncBegan, object: nil, userInfo: nil)
      } else {
        NotificationCenter.default.post(name: .TPPSyncEnded, object: nil, userInfo: nil)
      }
    }
  }
  private var syncUrl: URL?
  
  private override init() {
    super.init()
    
  }

  lazy var registryUrl: URL? = {
    TPPBookContentMetadataFilesHelper.currentAccountDirectory()?.appendingPathComponent(registryFolderName)
        .appendingPathComponent(registryFileName)
  }()
  
  func registryUrl(for account: String) -> URL? {
    TPPBookContentMetadataFilesHelper.directory(for: account)?
      .appendingPathComponent(registryFolderName)
      .appendingPathComponent(registryFileName)
  }
    
  func load(account: String? = nil) {
    guard let account = account ?? AccountsManager.shared.currentAccount?.uuid,
          let registryFileUrl = self.registryUrl(for: account)
    else {
      return
    }
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
    sync()
  }
  
  func reset(_ account: String) {
    registry.removeAll()
    if let registryUrl = registryUrl(for: account) {
      do {
        try FileManager.default.removeItem(at: registryUrl)
      } catch {
        // Log error
      }
    }
  }
    
  func sync(completion: ((_ errorDocument: [AnyHashable: Any]?, _ newBooks: Bool) -> Void)? = nil) {
    guard let loansUrl = AccountsManager.shared.currentAccount?.loansUrl else {
      return
    }
    if syncUrl == loansUrl {
      return
    }
    isSyncing = true
    syncUrl = loansUrl
    TPPOPDSFeed.withURL(loansUrl, shouldResetCache: true) { feed, errorDocument in
      DispatchQueue.main.async {
        defer {
          self.isSyncing = false
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
        recordsToDelete.forEach { self.registry[$0] = nil }
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
      let registryValues = registry.values.map { $0.dictionaryRepresentation }
      let registryObject = [TPPBookRegistryKey.records.rawValue: registryValues]
      let registryData = try JSONSerialization.data(withJSONObject: registryObject, options: .fragmentsAllowed)
      try registryData.write(to: registryUrl, options: .atomic)
      NotificationCenter.default.post(name: .TPPBookRegistryDidChange, object: nil, userInfo: nil)
    } catch {

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
  
  var allBooks: [TPPBook] {
    registry
      .map { $0.value }
      .filter { TPPBookStateHelper.allBookStates().contains($0.state.rawValue) }
      .map { $0.book }
  }
  
  var heldBooks: [TPPBook] {
    registry
      .map { $0.value }
      .filter { $0.state == .Holding }
      .map { $0.book }
  }
  
  var myBooks: [TPPBook] {
    let matchingStates: [TPPBookState] = [
      .DownloadNeeded, .Downloading, .SAMLStarted, .DownloadFailed, .DownloadSuccessful, .Used
    ]
    return registry
      .map { $0.value }
      .filter { matchingStates.contains($0.state) }
      .map { $0.book }
  }

  func addBook(_ book: TPPBook, location: TPPBookLocation? = nil, state: TPPBookState = .DownloadNeeded, fulfillmentId: String? = nil, readiumBookmarks: [TPPReadiumBookmark]? = nil, genericBookmarks: [TPPBookLocation]? = nil) {
    
    registry[book.identifier] = TPPBookRegistryRecord(book: book, location: location, state: state, fulfillmentId: fulfillmentId, readiumBookmarks: readiumBookmarks, genericBookmarks: genericBookmarks)
    save()
  }
  
  func updateAndRemoveBook(_ book: TPPBook) {
    guard registry[book.identifier] != nil else {
      return
    }
    coverRegistry.removePinnedThumbnailImageForBookIdentifier(book.identifier)
    registry[book.identifier]?.state = .Unregistered
    save()
  }

  
  func removeBook(forIdentifier bookIdentifier: String) {
    coverRegistry.removePinnedThumbnailImageForBookIdentifier(bookIdentifier)
    registry.removeValue(forKey: bookIdentifier)
    save()
  }
  
  func updateBook(_ book: TPPBook) {
    guard let record = registry[book.identifier] else {
      return
    }
    TPPUserNotifications.compareAvailability(cachedRecord: record, andNewBook: book)
    registry[book.identifier]?.book = book
  }
  
  func updatedBookMetadata(_ book: TPPBook) -> TPPBook? {
    guard let bookRecord = registry[book.identifier] else {
      return nil
    }
    let updatedBook = bookRecord.book.bookWithMetadata(from: book)
    registry[book.identifier]?.book = updatedBook
    save()
    return updatedBook
  }

    
  func state(for bookIdentifier: String) -> TPPBookState {
    return registry[bookIdentifier]?.state ?? .DownloadNeeded
  }
  
  func setState(_ state: TPPBookState, for bookIdentifier: String) {
    registry[bookIdentifier]?.state = state
    save()
  }
  
  func book(forIdentifier bookIdentifier: String) -> TPPBook? {
    registry[bookIdentifier]?.book
  }
  
  func setFulfillmentId(_ fulfillmentId: String, for bookIdentifier: String) {
    registry[bookIdentifier]?.fulfillmentId = fulfillmentId
    save()
  }

  func fulfillmentId(forIdentifier bookIdentifier: String) -> String? {
    registry[bookIdentifier]?.fulfillmentId
  }
  
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
  
  func processing(forIdentifier bookIdentifier: String) -> Bool {
    processingIdentifiers.contains(bookIdentifier)
  }
    
  func performUsingAccount(_ account: String, block: () -> Void) {
    if account == AccountsManager.shared.currentAccount?.uuid {
      block()
    } else {
      let currentRegistry = registry
      load(account: account)
      block()
      registry = currentRegistry
      save()
    }
  }

  // MARK: - Book Covers

  func cachedThumbnailImage(for book: TPPBook) -> UIImage? {
    return coverRegistry.cachedThumbnailImageForBook(book)
  }
  
  func thumbnailImage(for book: TPPBook, handler: @escaping (_ image: UIImage?) -> Void) {
    coverRegistry.thumbnailImageForBook(book, handler: handler)
  }

  func thumbnailImages(forBooks books: Set<TPPBook>, handler: @escaping (_ bookIdentifiersToImages: [String: UIImage]) -> Void) {
    coverRegistry.thumbnailImagesForBooks(books, handler: handler)
  }
  
  func coverImage(for book: TPPBook, handler: @escaping (_ image: UIImage?) -> Void) {
    coverRegistry.coverImageForBook(book, handler: handler)
  }

  // MARK: - Generic Bookmarks
  
  func genericBookmarksForIdentifier(_ bookIdentifier: String) -> [TPPBookLocation] {
    registry[bookIdentifier]?.genericBookmarks ?? []
  }
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
  func deleteGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) {
    registry[bookIdentifier]?.genericBookmarks?.removeAll { $0 == location }
    save()
  }
}

extension TPPBookRegistry: TPPBookRegistryProvider {
  func setLocation(_ location: TPPBookLocation?, forIdentifier bookIdentifier: String) {
    registry[bookIdentifier]?.location = location
    save()
  }
  
  func location(forIdentifier bookIdentifier: String) -> TPPBookLocation? {
    registry[bookIdentifier]?.location
  }
  
  func readiumBookmarks(forIdentifier bookIdentifier: String) -> [TPPReadiumBookmark] {
    registry[bookIdentifier]?.readiumBookmarks?
      .sorted { $0.progressWithinBook < $1.progressWithinBook } ?? []
  }

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
  
  func delete(_ bookmark: TPPReadiumBookmark, forIdentifier bookIdentifier: String) {
    registry[bookIdentifier]?.readiumBookmarks?.removeAll { $0 == bookmark }
    save()
  }
  
  func replace(_ oldBookmark: TPPReadiumBookmark, with newBookmark: TPPReadiumBookmark, forIdentifier bookIdentifier: String) {
    registry[bookIdentifier]?.readiumBookmarks?.removeAll { $0 == oldBookmark }
    registry[bookIdentifier]?.readiumBookmarks?.append(newBookmark)
    save()
  }
}

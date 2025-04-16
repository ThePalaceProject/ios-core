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
    return self[key.rawValue] as? TPPBookRegistryData
  }
  func array(for key: TPPBookRegistryKey) -> [TPPBookRegistryData]? {
    return self[key.rawValue] as? [TPPBookRegistryData]
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
class TPPBookRegistry: NSObject, TPPBookRegistrySyncing {
  private let syncQueueKey = DispatchSpecificKey<Void>()

  @objc enum RegistryState: Int {
    case unloaded, loading, loaded, syncing, synced
  }

  private let registryFolderName = "registry"
  private let registryFileName = "registry.json"

  private var accountDidChange = NotificationCenter.default.publisher(for: .TPPCurrentAccountDidChange)
    .receive(on: RunLoop.main)
    .sink { _ in
      TPPBookRegistry.shared.load()
      TPPBookRegistry.shared.sync()
    }

  private var registry = [String: TPPBookRegistryRecord]() {
    didSet {
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        registrySubject.send(registry)
        NotificationCenter.default.post(name: .TPPBookRegistryDidChange, object: nil, userInfo: nil)
      }
    }
  }

  private var coverRegistry = TPPBookCoverRegistry()
  private let syncQueue = DispatchQueue(label: "com.palace.syncQueue")
  private var processingIdentifiers = Set<String>()

  static let shared = TPPBookRegistry()

  private(set) var isSyncing: Bool {
    get { return syncState.value }
    set { }
  }

  private let registrySubject = CurrentValueSubject<[String: TPPBookRegistryRecord], Never>([:])
  private let bookStateSubject = PassthroughSubject<(String, TPPBookState), Never>()

  var registryPublisher: AnyPublisher<[String: TPPBookRegistryRecord], Never> {
    registrySubject.eraseToAnyPublisher()
  }
  var bookStatePublisher: AnyPublisher<(String, TPPBookState), Never> {
    bookStateSubject.eraseToAnyPublisher()
  }

  private var syncState = BoolWithDelay { value in
    if value {
      NotificationCenter.default.post(name: .TPPSyncBegan, object: nil, userInfo: nil)
    } else {
      NotificationCenter.default.post(name: .TPPSyncEnded, object: nil, userInfo: nil)
    }
  }

  private(set) var state: RegistryState = .unloaded {
    didSet {
      syncState.value = (state == .syncing)
      DispatchQueue.main.async {
        NotificationCenter.default.post(name: .TPPBookRegistryStateDidChange, object: nil, userInfo: nil)
      }
    }
  }

  private var syncUrl: URL?

  private override init() {
    super.init()
    syncQueue.setSpecific(key: syncQueueKey, value: ())
  }

  fileprivate init(account: String) {
    super.init()
    load(account: account)
  }

  func with(account: String, perform block: (_ registry: TPPBookRegistry) -> Void) {
    block(TPPBookRegistry(account: account))
  }

  func registryUrl(for account: String) -> URL? {
    return TPPBookContentMetadataFilesHelper.directory(for: account)?
      .appendingPathComponent(registryFolderName)
      .appendingPathComponent(registryFileName)
  }

  func load(account: String? = nil) {
    guard let account = account ?? AccountsManager.shared.currentAccountId,
          let registryFileUrl = self.registryUrl(for: account)
    else { return }
    state = .loading
    syncQueue.async {
      self.registry.removeAll()
      if FileManager.default.fileExists(atPath: registryFileUrl.path),
         let registryData = try? Data(contentsOf: registryFileUrl),
         let jsonObject = try? JSONSerialization.jsonObject(with: registryData),
         let registryObject = jsonObject as? TPPBookRegistryData,
         let records = registryObject.array(for: .records) {
        for recordObject in records {
          guard let record = TPPBookRegistryRecord(record: recordObject) else {
            continue
          }
          if record.state == .downloading || record.state == .SAMLStarted {
            record.state = .downloadFailed
          }
          self.registry[record.book.identifier] = record
        }
      }
      DispatchQueue.main.async { [weak self] in
        self?.state = .loaded
      }
    }
  }

  func reset(_ account: String) {
    state = .unloaded
    syncUrl = nil
    syncQueue.async {
      self.registry.removeAll()
    }
    if let registryUrl = registryUrl(for: account) {
      do {
        try FileManager.default.removeItem(at: registryUrl)
      } catch {
        Log.error(#file, "Error deleting registry data: \(error.localizedDescription)")
      }
    }
  }

  func sync(completion: ((_ errorDocument: [AnyHashable: Any]?, _ newBooks: Bool) -> Void)? = nil) {
    guard let loansUrl = AccountsManager.shared.currentAccount?.loansUrl else { return }

    if state == .syncing {
      return
    }

    state = .syncing
    syncUrl = loansUrl

    TPPOPDSFeed.withURL(loansUrl, shouldResetCache: true, useTokenIfAvailable: true) { [weak self] feed, errorDocument in
      DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        if self.syncUrl != loansUrl { return }

        if let errorDocument = errorDocument {
          self.state = .loaded
          self.syncUrl = nil
          completion?(errorDocument, false)
          return
        }

        guard let feed = feed else {
          self.state = .loaded
          self.syncUrl = nil
          completion?(nil, false)
          return
        }
        if let licensor = feed.licensor as? [String: Any] {
          TPPUserAccount.sharedAccount().setLicensor(licensor)
        }

        var changesMade = false
        self.syncQueue.sync {
          var recordsToDelete = Set<String>(self.registry.keys)
          for entry in feed.entries {
            guard let opdsEntry = entry as? TPPOPDSEntry,
                  let book = TPPBook(entry: opdsEntry)
            else { continue }
            recordsToDelete.remove(book.identifier)
            if self.registry[book.identifier] != nil {
              self.updateBook(book)
              changesMade = true
            } else {
              self.addBook(book)
              changesMade = true
            }
          }
          recordsToDelete.forEach { identifier in
            if let state = self.registry[identifier]?.state,
               state == .downloadSuccessful || state == .used {
              MyBooksDownloadCenter.shared.deleteLocalContent(for: identifier)
            }
            self.registry[identifier]?.state = .unregistered
            self.removeBook(forIdentifier: identifier)
            changesMade = true
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

        self.state = .synced
        self.syncUrl = nil
        completion?(nil, changesMade)
      }
    }
  }

  private func save() {
    guard let account = AccountsManager.shared.currentAccount?.uuid,
          let registryUrl = registryUrl(for: account)
    else { return }
    syncQueue.async {
      do {
        if !FileManager.default.fileExists(atPath: registryUrl.path) {
          try FileManager.default.createDirectory(at: registryUrl.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let registryValues = self.registry.values.map { $0.dictionaryRepresentation }
        let registryObject = [TPPBookRegistryKey.records.rawValue: registryValues]
        let registryData = try JSONSerialization.data(withJSONObject: registryObject, options: .fragmentsAllowed)
        try registryData.write(to: registryUrl, options: .atomic)
        DispatchQueue.main.async {
          NotificationCenter.default.post(name: .TPPBookRegistryDidChange, object: nil, userInfo: nil)
        }
      } catch {
        Log.error(#file, "Error saving book registry: \(error.localizedDescription)")
      }
    }
  }

  func load() { load(account: nil) }
  func sync() { sync(completion: nil) }

  private func performSync<T>(_ block: () -> T) -> T {
    if DispatchQueue.getSpecific(key: syncQueueKey) != nil {
      return block()
    } else {
      return syncQueue.sync { block() }
    }
  }

  var allBooks: [TPPBook] {
    return performSync {
      registry.values.filter { TPPBookStateHelper.allBookStates().contains($0.state.rawValue) }.map { $0.book }
    }
  }

  var heldBooks: [TPPBook] {
    return performSync {
      registry
        .map { $0.value }
        .filter { $0.state == .holding }
        .map { $0.book }
    }
  }

  var myBooks: [TPPBook] {
    let matchingStates: [TPPBookState] = [
      .downloadNeeded, .downloading, .SAMLStarted, .downloadFailed, .downloadSuccessful, .used
    ]
    return performSync {
      registry
        .map { $0.value }
        .filter { matchingStates.contains($0.state) }
        .map { $0.book }
    }
  }
  
  /// Adds a book to the book registry until it is manually removed. It allows the application to
  /// present information about obtained books when offline. Attempting to add a book already present
  /// will overwrite the existing book as if `updateBook` were called. The location may be nil. The
  /// state provided must be one of `TPPBookState` and must not be `TPPBookState.unregistered`.
  func addBook(_ book: TPPBook, location: TPPBookLocation? = nil, state: TPPBookState = .downloadNeeded, fulfillmentId: String? = nil, readiumBookmarks: [TPPReadiumBookmark]? = nil, genericBookmarks: [TPPBookLocation]? = nil) {
    // Cache the thumbnail image if it exists
    DispatchQueue.main.async { [weak self] in
      self?.coverRegistry.thumbnailImageForBook(book) { _ in }
    }
    syncQueue.async {
      self.registry[book.identifier] = TPPBookRegistryRecord(book: book, location: location, state: state, fulfillmentId: fulfillmentId, readiumBookmarks: readiumBookmarks, genericBookmarks: genericBookmarks)
      self.save()


      DispatchQueue.main.async {
        self.registrySubject.send(self.registry)
      }
    }
  }

  func updateAndRemoveBook(_ book: TPPBook) {
    syncQueue.async { [weak self] in
      guard let self, let existingRecord = self.registry[book.identifier] else { return }
      self.coverRegistry.cachedThumbnailImageForBook(book)
      existingRecord.book = book
      existingRecord.state = .unregistered
      self.save()
    }
  }

  func removeBook(forIdentifier bookIdentifier: String) {
    syncQueue.async {
      let book = self.registry[bookIdentifier]?.book
      self.registry.removeValue(forKey: bookIdentifier)
      self.save()

      DispatchQueue.main.async {
        self.registrySubject.send(self.registry)
      }

      //TODO: Investigate why we are doing this
      if let book = book {
        DispatchQueue.main.async { [weak self] in
          self?.coverRegistry.cachedThumbnailImageForBook(book)
        }
      }
    }
  }

  func updateBook(_ book: TPPBook) {
    syncQueue.async {
      guard let record = self.registry[book.identifier] else { return }
      TPPUserNotifications.compareAvailability(cachedRecord: record, andNewBook: book)
      self.registry[book.identifier] = TPPBookRegistryRecord(
        book: book,
        location: record.location,
        state: record.state,
        fulfillmentId: record.fulfillmentId,
        readiumBookmarks: record.readiumBookmarks,
        genericBookmarks: record.genericBookmarks
      )
    }

    DispatchQueue.main.async {
      self.registrySubject.send(self.registry)
    }
  }

  func updatedBookMetadata(_ book: TPPBook) -> TPPBook? {
    return performSync {
      guard let bookRecord = self.registry[book.identifier] else { return nil }
      let updatedBook = bookRecord.book.bookWithMetadata(from: book)
      self.registry[book.identifier]?.book = updatedBook
      self.save()
      return updatedBook
    }
  }

  func state(for bookIdentifier: String?) -> TPPBookState {
    guard let bookIdentifier = bookIdentifier, !bookIdentifier.isEmpty else { return .unregistered }
    return performSync {
      self.registry[bookIdentifier]?.state ?? .unregistered
    }
  }

  func setState(_ state: TPPBookState, for bookIdentifier: String) {
    syncQueue.async {
    self.registry[bookIdentifier]?.state = state
    self.postStateNotification(bookIdentifier: bookIdentifier, state: state)
    self.save()

      DispatchQueue.main.async {
        self.bookStateSubject.send((bookIdentifier, state)) // 🔹 Publish state change
      }
    }
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
    guard let bookIdentifier = bookIdentifier, !bookIdentifier.isEmpty else { return nil }
    guard let record = performSync({ self.registry[bookIdentifier] }) else { return nil }
    return record.book
  }

  func setFulfillmentId(_ fulfillmentId: String, for bookIdentifier: String) {
    syncQueue.async {
      self.registry[bookIdentifier]?.fulfillmentId = fulfillmentId
      self.save()
    }
  }

  func fulfillmentId(forIdentifier bookIdentifier: String?) -> String? {
    guard let bookIdentifier = bookIdentifier, !bookIdentifier.isEmpty else { return nil }
    guard let record = performSync({ self.registry[bookIdentifier] }) else { return nil }
    return record.fulfillmentId
  }

  func setProcessing(_ processing: Bool, for bookIdentifier: String) {
    syncQueue.async {
      if processing {
        self.processingIdentifiers.insert(bookIdentifier)
      } else {
        self.processingIdentifiers.remove(bookIdentifier)
      }
      DispatchQueue.main.async {
        NotificationCenter.default.post(name: .TPPBookProcessingDidChange, object: nil, userInfo: [
          TPPNotificationKeys.bookProcessingBookIDKey: bookIdentifier,
          TPPNotificationKeys.bookProcessingValueKey: processing
        ])
      }
    }
  }

  func processing(forIdentifier bookIdentifier: String) -> Bool {
    return performSync {
      self.processingIdentifiers.contains(bookIdentifier)
    }
  }

  func cachedThumbnailImage(for book: TPPBook) -> UIImage? {
    return coverRegistry.cachedThumbnailImageForBook(book)
  }

  @MainActor
  func thumbnailImage(for book: TPPBook?, handler: @escaping (_ image: UIImage?) -> Void) {
    guard let book = book else {
      handler(nil)
      return
    }
    coverRegistry.thumbnailImageForBook(book, handler: handler)
  }

  @MainActor
  func thumbnailImages(forBooks books: Set<TPPBook>, handler: @escaping (_ bookIdentifiersToImages: [String: UIImage]) -> Void) {
    coverRegistry.thumbnailImagesForBooks(books, handler: handler)
  }
  
  /// Returns cover image if it exists, or falls back to thumbnail image load.
  func coverImage(for book: TPPBook, handler: @escaping (_ image: UIImage?) -> Void) {
    DispatchQueue.main.async { [weak self] in
      self?.coverRegistry.coverImageForBook(book, handler: handler)
    }
  }
}

extension TPPBookRegistry: TPPBookRegistryProvider {
  func setLocation(_ location: TPPBookLocation?, forIdentifier bookIdentifier: String) {
    guard !bookIdentifier.isEmpty else { return }
    syncQueue.async {
      self.registry[bookIdentifier]?.location = location
      self.save()
    }
  }

  func location(forIdentifier bookIdentifier: String) -> TPPBookLocation? {
    return performSync {
      self.registry[bookIdentifier]?.location
    }
  }

  func readiumBookmarks(forIdentifier bookIdentifier: String) -> [TPPReadiumBookmark] {
    return performSync {
      guard let record = self.registry[bookIdentifier] else { return [] }
      return record.readiumBookmarks?.sorted { $0.progressWithinBook < $1.progressWithinBook } ?? []
    }
  }

  func add(_ bookmark: TPPReadiumBookmark, forIdentifier bookIdentifier: String) {
    syncQueue.async {
      guard self.registry[bookIdentifier] != nil else { return }
      if self.registry[bookIdentifier]?.readiumBookmarks == nil {
        self.registry[bookIdentifier]?.readiumBookmarks = [TPPReadiumBookmark]()
      }
      self.registry[bookIdentifier]?.readiumBookmarks?.append(bookmark)
      self.save()
    }
  }

  func delete(_ bookmark: TPPReadiumBookmark, forIdentifier bookIdentifier: String) {
    syncQueue.async {
      self.registry[bookIdentifier]?.readiumBookmarks?.removeAll { $0 == bookmark }
      self.save()
    }
  }

  func replace(_ oldBookmark: TPPReadiumBookmark, with newBookmark: TPPReadiumBookmark, forIdentifier bookIdentifier: String) {
    syncQueue.async {
      self.registry[bookIdentifier]?.readiumBookmarks?.removeAll { $0 == oldBookmark }
      self.registry[bookIdentifier]?.readiumBookmarks?.append(newBookmark)
      self.save()
    }
  }

  func genericBookmarksForIdentifier(_ bookIdentifier: String) -> [TPPBookLocation] {
    return performSync {
      self.registry[bookIdentifier]?.genericBookmarks ?? []
    }
  }

  func addOrReplaceGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) {
    syncQueue.async {
      guard self.registry[bookIdentifier] != nil else { return }
      if self.registry[bookIdentifier]?.genericBookmarks == nil {
        self.registry[bookIdentifier]?.genericBookmarks = [TPPBookLocation]()
      }
      self.deleteGenericBookmark(location, forIdentifier: bookIdentifier)
      self.addGenericBookmark(location, forIdentifier: bookIdentifier)
      self.save()
    }
  }

  func addGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) {
    syncQueue.async {
      guard self.registry[bookIdentifier] != nil else { return }
      if self.registry[bookIdentifier]?.genericBookmarks == nil {
        self.registry[bookIdentifier]?.genericBookmarks = [TPPBookLocation]()
      }
      
      self.registry[bookIdentifier]?.genericBookmarks?.append(location)
      self.save()
    }
  }

  func deleteGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) {
    syncQueue.async {
      self.registry[bookIdentifier]?.genericBookmarks?.removeAll { $0.isSimilarTo(location) }
      self.save()
    }
  }

  func replaceGenericBookmark(_ oldLocation: TPPBookLocation, with newLocation: TPPBookLocation, forIdentifier bookIdentifier: String) {
    syncQueue.async {
      self.deleteGenericBookmark(oldLocation, forIdentifier: bookIdentifier)
      self.addGenericBookmark(newLocation, forIdentifier: bookIdentifier)
    }
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
    let excludedKeys = ["timeStamp", "annotationId"]
    let filteredDict = locationDict.filter { !excludedKeys.contains($0.key) }
    let filteredOtherDict = otherLocationDict.filter { !excludedKeys.contains($0.key) }
    return NSDictionary(dictionary: filteredDict).isEqual(to: filteredOtherDict)
  }
}

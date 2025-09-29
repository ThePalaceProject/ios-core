import Combine
import Foundation
import UIKit

// MARK: - TPPBookRegistryProvider

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
  func replace(
    _ oldBookmark: TPPReadiumBookmark,
    with newBookmark: TPPReadiumBookmark,
    forIdentifier identifier: String
  )
  func genericBookmarksForIdentifier(_ bookIdentifier: String) -> [TPPBookLocation]
  func addOrReplaceGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String)
  func addGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String)
  func deleteGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String)
  func replaceGenericBookmark(_ oldLocation: TPPBookLocation, with newLocation: TPPBookLocation, forIdentifier: String)
  func addBook(
    _ book: TPPBook,
    location: TPPBookLocation?,
    state: TPPBookState,
    fulfillmentId: String?,
    readiumBookmarks: [TPPReadiumBookmark]?,
    genericBookmarks: [TPPBookLocation]?
  )
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
    self[key.rawValue]
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

// MARK: - TPPBookRegistryKey

enum TPPBookRegistryKey: String {
  case records
  case book = "metadata"
  case state
  case fulfillmentId
  case location
  case readiumBookmarks = "bookmarks"
  case genericBookmarks
}

// MARK: - BoolWithDelay

private class BoolWithDelay {
  private var switchBackDelay: Double
  private var resetTask: DispatchWorkItem?
  private var onChange: ((_ value: Bool) -> Void)?
  init(delay: Double = 5, onChange: ((_ value: Bool) -> Void)? = nil) {
    switchBackDelay = delay
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

// MARK: - TPPBookRegistry

@objcMembers
class TPPBookRegistry: NSObject, TPPBookRegistrySyncing {
  private let syncQueueKey = DispatchSpecificKey<Void>()

  @objc enum RegistryState: Int {
    case unloaded
    case loading
    case loaded
    case syncing
    case synced
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
        guard let self else {
          return
        }
        registrySubject.send(registry)
        NotificationCenter.default.post(name: .TPPBookRegistryDidChange, object: nil, userInfo: nil)
      }
    }
  }

  private var coverRegistry = TPPBookCoverRegistry.shared
  private let syncQueue = DispatchQueue(
    label: "com.palace.syncQueue",
    attributes: .concurrent
  )
  private var processingIdentifiers = Set<String>()

  static let shared = TPPBookRegistry()

  private(set) var isSyncing: Bool {
    get { syncState.value }
    set {}
  }

  private let registrySubject = CurrentValueSubject<[String: TPPBookRegistryRecord], Never>([:])
  private let bookStateSubject = PassthroughSubject<(String, TPPBookState), Never>()

  var registryPublisher: AnyPublisher<[String: TPPBookRegistryRecord], Never> {
    registrySubject
      .receive(on: RunLoop.main)
      .eraseToAnyPublisher()
  }

  var bookStatePublisher: AnyPublisher<(String, TPPBookState), Never> {
    bookStateSubject
      .receive(on: RunLoop.main)
      .eraseToAnyPublisher()
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

  /// Keeps loans URL of current synchronisation process.
  /// TPPBookRegistry is a shared object, this value is used to cancel synchronisation callback when the user changes library account.
  private var syncUrl: URL?

  override private init() {
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
    TPPBookContentMetadataFilesHelper.directory(for: account)?
      .appendingPathComponent(registryFolderName)
      .appendingPathComponent(registryFileName)
  }

  func load(account: String? = nil) {
    guard let account = account ?? AccountsManager.shared.currentAccountId,
          let url = registryUrl(for: account)
    else {
      return
    }

    DispatchQueue.main.async { self.state = .loading }

    syncQueue.async(flags: .barrier) {
      var newRegistry = [String: TPPBookRegistryRecord]()
      if FileManager.default.fileExists(atPath: url.path),
         let data = try? Data(contentsOf: url),
         let json = try? JSONSerialization.jsonObject(with: data) as? TPPBookRegistryData,
         let records = json.array(for: .records)
      {
        for obj in records {
          guard var record = TPPBookRegistryRecord(record: obj) else {
            continue
          }
          if record.state == .downloading || record.state == .SAMLStarted {
            record.state = .downloadFailed
          }
          newRegistry[record.book.identifier] = record
        }
      }

      self.registry = newRegistry

      DispatchQueue.main.async {
        self.state = .loaded
        self.registrySubject.send(self.registry)
        NotificationCenter.default.post(name: .TPPBookRegistryDidChange, object: nil)
      }
    }
  }

  func reset(_ account: String) {
    state = .unloaded
    syncUrl = nil
    syncQueue.async(flags: .barrier) {
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
    guard let loansUrl = AccountsManager.shared.currentAccount?.loansUrl else {
      return
    }

    if state == .syncing {
      return
    }

    state = .syncing
    syncUrl = loansUrl

    TPPOPDSFeed
      .withURL(loansUrl, shouldResetCache: true, useTokenIfAvailable: true) { [weak self] feed, errorDocument in
        DispatchQueue.main.async { [weak self] in
          guard let self = self else {
            return
          }
          if syncUrl != loansUrl {
            return
          }

          if let errorDocument = errorDocument {
            state = .loaded
            syncUrl = nil
            completion?(errorDocument, false)
            return
          }

          guard let feed = feed else {
            state = .loaded
            syncUrl = nil
            completion?(nil, false)
            return
          }

          var changesMade = false
          syncQueue.sync {
            var recordsToDelete = Set<String>(self.registry.keys)
            for entry in feed.entries {
              guard let opdsEntry = entry as? TPPOPDSEntry,
                    let book = TPPBook(entry: opdsEntry)
              else {
                continue
              }
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
              if let recordState = self.registry[identifier]?.state,
                 recordState == .downloadSuccessful || recordState == .used
              {
                MyBooksDownloadCenter.shared.deleteLocalContent(for: identifier)
              }
              self.registry[identifier]?.state = .unregistered
              self.removeBook(forIdentifier: identifier)
              changesMade = true
            }
            self.save()
          }

          state = .synced
          syncUrl = nil
          completion?(nil, changesMade)
        }
      }
  }

  private func save() {
    guard let account = AccountsManager.shared.currentAccount?.uuid,
          let registryUrl = registryUrl(for: account)
    else {
      return
    }

    let snapshot: [[String: Any]] = performSync {
      self.registry.values.map(\.dictionaryRepresentation)
    }
    let registryObject = [TPPBookRegistryKey.records.rawValue: snapshot]

    DispatchQueue.global(qos: .utility).async {
      do {
        let directoryURL = registryUrl.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
          try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
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
      block()
    } else {
      syncQueue.sync { block() }
    }
  }

  var allBooks: [TPPBook] {
    performSync {
      registry.values.filter { TPPBookStateHelper.allBookStates().contains($0.state.rawValue) }.map(\.book)
    }
  }

  var heldBooks: [TPPBook] {
    performSync {
      registry
        .map(\.value)
        .filter { $0.state == .holding }
        .map(\.book)
    }
  }

  var myBooks: [TPPBook] {
    let matchingStates: [TPPBookState] = [
      .downloadNeeded, .downloading, .SAMLStarted, .downloadFailed, .downloadSuccessful, .used
    ]
    return performSync {
      registry
        .map(\.value)
        .filter { matchingStates.contains($0.state) }
        .map(\.book)
    }
  }

  /// Adds a book to the book registry until it is manually removed. It allows the application to
  /// present information about obtained books when offline. Attempting to add a book already present
  /// will overwrite the existing book as if `updateBook` were called. The location may be nil. The
  /// state provided must be one of `TPPBookState` and must not be `TPPBookState.unregistered`.
  func addBook(
    _ book: TPPBook,
    location: TPPBookLocation? = nil,
    state: TPPBookState = .downloadNeeded,
    fulfillmentId: String? = nil,
    readiumBookmarks: [TPPReadiumBookmark]? = nil,
    genericBookmarks: [TPPBookLocation]? = nil
  ) {
    TPPBookCoverRegistryBridge.shared.thumbnailImageForBook(book) { _ in }

    syncQueue.async(flags: .barrier) { [weak self] in
      guard let self else {
        return
      }
      registry[book.identifier] = TPPBookRegistryRecord(
        book: book,
        location: location,
        state: state,
        fulfillmentId: fulfillmentId,
        readiumBookmarks: readiumBookmarks,
        genericBookmarks: genericBookmarks
      )
      save()
      DispatchQueue.main.async {
        self.registrySubject.send(self.registry)
      }
    }
  }

  func updateAndRemoveBook(_ book: TPPBook) {
    TPPBookCoverRegistryBridge.shared.thumbnailImageForBook(book) { _ in }

    syncQueue.async(flags: .barrier) { [weak self] in
      guard let self, let record = registry[book.identifier] else {
        return
      }
      record.book = book
      record.state = .unregistered
      save()
    }
  }

  func removeBook(forIdentifier bookIdentifier: String) {
    guard !bookIdentifier.isEmpty else {
      Log.error(#file, "removeBook called with empty bookIdentifier")
      return
    }

    syncQueue.async(flags: .barrier) {
      let removedBook = self.registry[bookIdentifier]?.book
      self.registry.removeValue(forKey: bookIdentifier)
      self.save()
      DispatchQueue.main.async {
        self.registrySubject.send(self.registry)
        if let book = removedBook {
          TPPBookCoverRegistryBridge.shared.thumbnailImageForBook(book) { _ in }
        }
      }
    }
  }

  func updateBook(_ book: TPPBook) {
    syncQueue.async(flags: .barrier) { [weak self] in
      guard let self, let record = registry[book.identifier] else {
        return
      }

      var nextState = record.state
      if record.state == .unregistered {
        book.defaultAcquisition?.availability.matchUnavailable(
          nil,
          limited: nil,
          unlimited: nil,
          reserved: { _ in nextState = .holding },
          ready: { _ in nextState = .holding }
        )
      }

      TPPUserNotifications.compareAvailability(cachedRecord: record, andNewBook: book)
      registry[book.identifier] = TPPBookRegistryRecord(
        book: book,
        location: record.location,
        state: nextState,
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
    performSync {
      guard let bookRecord = self.registry[book.identifier] else {
        return nil
      }
      let updatedBook = bookRecord.book.bookWithMetadata(from: book)
      self.registry[book.identifier]?.book = updatedBook
      self.save()
      return updatedBook
    }
  }

  func state(for bookIdentifier: String?) -> TPPBookState {
    guard let bookIdentifier = bookIdentifier, !bookIdentifier.isEmpty else {
      return .unregistered
    }
    return performSync {
      self.registry[bookIdentifier]?.state ?? .unregistered
    }
  }

  func setState(_ state: TPPBookState, for bookIdentifier: String) {
    syncQueue.async(flags: .barrier) { [weak self] in
      guard let self else {
        return
      }

      registry[bookIdentifier]?.state = state
      postStateNotification(bookIdentifier: bookIdentifier, state: state)
      save()

      DispatchQueue.main.async {
        self.bookStateSubject.send((bookIdentifier, state))
      }
    }
  }

  @available(*, deprecated, message: "Use Combine publishers instead.")
  private func postStateNotification(bookIdentifier: String, state: TPPBookState) {
    DispatchQueue.main.async {
      NotificationCenter.default.post(
        name: .TPPBookRegistryStateDidChange,
        object: nil,
        userInfo: [
          "bookIdentifier": bookIdentifier,
          "state": state.rawValue
        ]
      )
    }
  }

  /// Returns the book for a given identifier if it is registered, else nil.
  func book(forIdentifier bookIdentifier: String?) -> TPPBook? {
    guard let bookIdentifier = bookIdentifier, !bookIdentifier.isEmpty else {
      return nil
    }
    guard let record = performSync({ self.registry[bookIdentifier] }) else {
      return nil
    }
    return record.book
  }

  func setFulfillmentId(_ fulfillmentId: String, for bookIdentifier: String) {
    syncQueue.async(flags: .barrier) { [weak self] in
      guard let self else {
        return
      }

      registry[bookIdentifier]?.fulfillmentId = fulfillmentId
      save()
    }
  }

  func fulfillmentId(forIdentifier bookIdentifier: String?) -> String? {
    guard let bookIdentifier = bookIdentifier, !bookIdentifier.isEmpty else {
      return nil
    }
    guard let record = performSync({ self.registry[bookIdentifier] }) else {
      return nil
    }
    return record.fulfillmentId
  }

  func setProcessing(_ processing: Bool, for bookIdentifier: String) {
    syncQueue.async(flags: .barrier) { [weak self] in
      guard let self else {
        return
      }

      if processing {
        processingIdentifiers.insert(bookIdentifier)
      } else {
        processingIdentifiers.remove(bookIdentifier)
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
    performSync {
      self.processingIdentifiers.contains(bookIdentifier)
    }
  }

  func cachedThumbnailImage(for book: TPPBook) -> UIImage? {
    let simpleKey = book.identifier
    let thumbnailKey = "\(book.identifier)_thumbnail"
    return book.imageCache.get(for: simpleKey) ?? book.imageCache.get(for: thumbnailKey)
  }

  func thumbnailImage(
    for book: TPPBook?,
    handler: @escaping (_ image: UIImage?) -> Void
  ) {
    guard let book = book else {
      handler(nil)
      return
    }

    TPPBookCoverRegistryBridge
      .shared
      .thumbnailImageForBook(book, completion: handler)
  }

  func thumbnailImages(
    forBooks books: Set<TPPBook>,
    handler: @escaping (_ bookIdentifiersToImages: [String: UIImage]) -> Void
  ) {
    let group = DispatchGroup()
    var result = [String: UIImage]()

    for book in books {
      group.enter()
      TPPBookCoverRegistryBridge
        .shared
        .thumbnailImageForBook(book) { image in
          if let img = image {
            result[book.identifier] = img
          }
          group.leave()
        }
    }

    group.notify(queue: .main) {
      handler(result)
    }
  }

  /// Single‐book cover (with thumbnail fallback inside bridge)
  func coverImage(
    for book: TPPBook,
    handler: @escaping (_ image: UIImage?) -> Void
  ) {
    TPPBookCoverRegistryBridge
      .shared
      .coverImageForBook(book, completion: handler)
  }
}

// MARK: TPPBookRegistryProvider

extension TPPBookRegistry: TPPBookRegistryProvider {
  func setLocation(_ location: TPPBookLocation?, forIdentifier bookIdentifier: String) {
    guard !bookIdentifier.isEmpty else {
      return
    }
    syncQueue.async(flags: .barrier) { [weak self] in
      guard let self else {
        return
      }

      registry[bookIdentifier]?.location = location
      save()
    }
  }

  func location(forIdentifier bookIdentifier: String) -> TPPBookLocation? {
    performSync {
      self.registry[bookIdentifier]?.location
    }
  }

  func readiumBookmarks(forIdentifier bookIdentifier: String) -> [TPPReadiumBookmark] {
    performSync {
      guard let record = self.registry[bookIdentifier] else {
        return []
      }
      return record.readiumBookmarks?.sorted { $0.progressWithinBook < $1.progressWithinBook } ?? []
    }
  }

  func add(_ bookmark: TPPReadiumBookmark, forIdentifier bookIdentifier: String) {
    syncQueue.async(flags: .barrier) { [weak self] in
      guard let self else {
        return
      }

      guard registry[bookIdentifier] != nil else {
        return
      }
      if registry[bookIdentifier]?.readiumBookmarks == nil {
        registry[bookIdentifier]?.readiumBookmarks = [TPPReadiumBookmark]()
      }
      registry[bookIdentifier]?.readiumBookmarks?.append(bookmark)
      save()
    }
  }

  func delete(_ bookmark: TPPReadiumBookmark, forIdentifier bookIdentifier: String) {
    syncQueue.async(flags: .barrier) { [weak self] in
      guard let self else {
        return
      }

      registry[bookIdentifier]?.readiumBookmarks?.removeAll { $0 == bookmark }
      save()
    }
  }

  func replace(
    _ oldBookmark: TPPReadiumBookmark,
    with newBookmark: TPPReadiumBookmark,
    forIdentifier bookIdentifier: String
  ) {
    syncQueue.async(flags: .barrier) { [weak self] in
      guard let self else {
        return
      }

      registry[bookIdentifier]?.readiumBookmarks?.removeAll { $0 == oldBookmark }
      registry[bookIdentifier]?.readiumBookmarks?.append(newBookmark)
      save()
    }
  }

  func genericBookmarksForIdentifier(_ bookIdentifier: String) -> [TPPBookLocation] {
    performSync {
      self.registry[bookIdentifier]?.genericBookmarks ?? []
    }
  }

  func addOrReplaceGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) {
    syncQueue.async(flags: .barrier) { [weak self] in
      guard let self else {
        return
      }

      guard registry[bookIdentifier] != nil else {
        return
      }
      if registry[bookIdentifier]?.genericBookmarks == nil {
        registry[bookIdentifier]?.genericBookmarks = [TPPBookLocation]()
      }
      deleteGenericBookmark(location, forIdentifier: bookIdentifier)
      addGenericBookmark(location, forIdentifier: bookIdentifier)
      save()
    }
  }

  func addGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) {
    syncQueue.async(flags: .barrier) { [weak self] in
      guard let self else {
        return
      }

      guard registry[bookIdentifier] != nil else {
        return
      }
      if registry[bookIdentifier]?.genericBookmarks == nil {
        registry[bookIdentifier]?.genericBookmarks = [TPPBookLocation]()
      }

      registry[bookIdentifier]?.genericBookmarks?.append(location)
      save()
    }
  }

  func deleteGenericBookmark(_ location: TPPBookLocation, forIdentifier bookIdentifier: String) {
    syncQueue.async(flags: .barrier) {
      self.registry[bookIdentifier]?.genericBookmarks?.removeAll { $0.isSimilarTo(location) }
      self.save()
    }
  }

  func replaceGenericBookmark(
    _ oldLocation: TPPBookLocation,
    with newLocation: TPPBookLocation,
    forIdentifier bookIdentifier: String
  ) {
    syncQueue.async(flags: .barrier) { [weak self] in
      guard let self else {
        return
      }

      deleteGenericBookmark(oldLocation, forIdentifier: bookIdentifier)
      addGenericBookmark(newLocation, forIdentifier: bookIdentifier)
    }
  }
}

extension TPPBookLocation {
  func locationStringDictionary() -> [String: Any]? {
    guard let data = locationString.data(using: .utf8),
          let dictionary = try? JSONSerialization.jsonObject(with: data, options: .allowFragments) as? [String: Any]
    else {
      return nil
    }
    return dictionary
  }

  func isSimilarTo(_ location: TPPBookLocation) -> Bool {
    guard renderer == location.renderer,
          let locationDict = locationStringDictionary(),
          let otherLocationDict = location.locationStringDictionary()
    else {
      return false
    }
    let excludedKeys = ["timeStamp", "annotationId"]
    let filteredDict = locationDict.filter { !excludedKeys.contains($0.key) }
    let filteredOtherDict = otherLocationDict.filter { !excludedKeys.contains($0.key) }
    return NSDictionary(dictionary: filteredDict).isEqual(to: filteredOtherDict)
  }
}

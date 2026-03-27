import Foundation

/// Handles server synchronization for the book registry.
/// Manages syncing loans from the OPDS feed and loading/saving from disk.
class BookRegistrySync {

  private let store: BookRegistryStore
  private let registryFolderName = "registry"
  private let registryFileName = "registry.json"

  var syncUrl: URL?
  var loadingAccount: String?

  init(store: BookRegistryStore) {
    self.store = store
  }

  func registryUrl(for account: String) -> URL? {
    return TPPBookContentMetadataFilesHelper.directory(for: account)?
      .appendingPathComponent(registryFolderName)
      .appendingPathComponent(registryFileName)
  }

  func load(account: String?, setState: @escaping (TPPBookRegistry.RegistryState) -> Void) {
    guard let account = account ?? AccountsManager.shared.currentAccountId,
          let url = registryUrl(for: account)
    else { return }

    // Prevent re-entrant loads for the same account
    if loadingAccount == account {
      Log.debug(#file, "Skipping duplicate load for account: \(account) (already loading)")
      return
    }

    loadingAccount = account
    Log.info(#file, "Loading registry for account: \(account)")
    DispatchQueue.main.async {
      setState(.loading)
    }

    store.mutateRegistry { [weak self] registry in
      guard let self else { return }

      var newRegistry = [String: TPPBookRegistryRecord]()
      if FileManager.default.fileExists(atPath: url.path),
         let data = try? Data(contentsOf: url),
         let json = try? JSONSerialization.jsonObject(with: data) as? TPPBookRegistryData,
         let records = json.array(for: .records) {

        Log.debug(#file, "  Found \(records.count) books in registry")

        for obj in records {
          guard var record = TPPBookRegistryRecord(record: obj) else { continue }
          let originalState = record.state

          // Validate file existence for download states
          if record.state == .downloading || record.state == .SAMLStarted || record.state == .downloadSuccessful {
            let fileExists = self.checkIfBookFileExists(for: record.book, account: account)

            if record.state == .downloading {
              if fileExists {
                Log.info(#file, "  '\(record.book.title)' was downloading but file exists - marking as successful")
                record.state = .downloadSuccessful
              } else {
                Log.warn(#file, "  '\(record.book.title)' was downloading but file missing - marking as failed")
                record.state = .downloadFailed
              }
            } else if record.state == .SAMLStarted {
              if fileExists {
                Log.info(#file, "  '\(record.book.title)' was in SAML flow but file exists - marking as download needed")
                record.state = .downloadNeeded
              } else {
                Log.warn(#file, "  '\(record.book.title)' was in SAML flow but file missing - marking as failed")
                record.state = .downloadFailed
              }
            } else if record.state == .downloadSuccessful {
              if !fileExists {
                Log.error(#file, "  '\(record.book.title)' marked as downloaded but FILE MISSING - marking as download needed")
                Log.error(#file, "     This suggests the file was deleted or the path is wrong")
                record.state = .downloadNeeded
              } else {
                Log.debug(#file, "  '\(record.book.title)' downloaded and file verified")
              }
            }

            if originalState != record.state {
              Log.info(#file, "  State changed for '\(record.book.title)': \(originalState) -> \(record.state)")
            }
          }

          newRegistry[record.book.identifier] = record
        }
      } else {
        Log.info(#file, "  No existing registry file found or failed to parse")
      }

      registry = newRegistry

      // Capture states and snapshot while on sync queue
      let bookStates = newRegistry.map { ($0.key, $0.value.state) }
      let snapshot = registry
      let bookCount = snapshot.count
      let loadedAccount = account

      DispatchQueue.main.async { [weak self] in
        guard let self else { return }

        if self.loadingAccount == loadedAccount {
          self.loadingAccount = nil
        }

        setState(.loaded)
        self.store.registrySubject.send(snapshot)

        for (identifier, state) in bookStates {
          self.store.bookStateSubject.send((identifier, state))
        }

        NotificationCenter.default.post(name: .TPPBookRegistryDidChange, object: nil)
        Log.info(#file, "  Registry loaded with \(bookCount) books")
      }
    }
  }

  func sync(
    currentState: TPPBookRegistry.RegistryState,
    setState: @escaping (TPPBookRegistry.RegistryState) -> Void,
    save: @escaping () -> Void,
    completion: ((_ errorDocument: [AnyHashable: Any]?, _ newBooks: Bool) -> Void)? = nil
  ) {
    guard let loansUrl = AccountsManager.shared.currentAccount?.loansUrl else { return }

    if currentState == .syncing { return }

    setState(.syncing)
    syncUrl = loansUrl

    TPPOPDSFeed.withURL(loansUrl, shouldResetCache: true, useTokenIfAvailable: true) { [weak self] feed, errorDocument in
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        if self.syncUrl != loansUrl { return }

        if let errorDocument {
          setState(.loaded)
          self.syncUrl = nil
          completion?(errorDocument, false)
          return
        }

        guard let feed else {
          setState(.loaded)
          self.syncUrl = nil
          completion?(nil, false)
          return
        }

        var changesMade = false
        self.store.mutateRegistrySync { registry in
          var recordsToDelete = Set<String>(registry.keys)
          for entry in feed.entries {
            guard let opdsEntry = entry as? TPPOPDSEntry,
                  let book = TPPBook(entry: opdsEntry)
            else { continue }
            recordsToDelete.remove(book.identifier)

            if let record = registry[book.identifier] {
              var nextState = record.state
              if record.state == .unregistered {
                book.defaultAcquisition?.availability.matchUnavailable(
                  nil, limited: nil, unlimited: nil,
                  reserved: { _ in nextState = .holding },
                  ready: { _ in nextState = .holding }
                )
              }
              NotificationService.compareAvailability(cachedRecord: record, andNewBook: book)
              registry[book.identifier] = TPPBookRegistryRecord(
                book: book,
                location: record.location,
                state: nextState,
                fulfillmentId: record.fulfillmentId,
                readiumBookmarks: record.readiumBookmarks,
                genericBookmarks: record.genericBookmarks
              )
              changesMade = true
            } else {
              let initialState = TPPBookRegistryRecord.deriveInitialState(for: book)
              registry[book.identifier] = TPPBookRegistryRecord(
                book: book,
                state: initialState
              )
              changesMade = true
            }
          }

          // Guard against bulk deletion from truncated server responses
          let localCount = registry.count
          let feedCount = feed.entries.count
          let deletionCount = recordsToDelete.count
          let deletionRatio = localCount > 0 ? Double(deletionCount) / Double(localCount) : 0

          let shouldSkipBulkDeletion = localCount > 2
            && feedCount == 0
            && deletionCount > 0

          let shouldWarnLargeDeletion = localCount > 4
            && deletionRatio > 0.5
            && deletionCount > 2

          if shouldSkipBulkDeletion {
            Log.error(#file, "Sync returned EMPTY feed but \(localCount) local books exist - skipping deletion (possible server issue)")
          } else if shouldWarnLargeDeletion {
            Log.warn(#file, "Sync would remove \(deletionCount)/\(localCount) books (\(Int(deletionRatio * 100))%) - proceeding but logging for investigation")
          }

          if !shouldSkipBulkDeletion {
            recordsToDelete.forEach { identifier in
              guard let record = registry[identifier] else { return }

              let wasDownloaded = record.state == .downloadSuccessful || record.state == .used

              if wasDownloaded {
                Log.info(#file, "Removing expired/returned book '\(record.book.title)' (not in server feed)")
                MyBooksDownloadCenter.shared.deleteLocalContent(for: identifier)
              }

              registry[identifier]?.state = .unregistered
              registry.removeValue(forKey: identifier)
              changesMade = true
            }
          }
          save()
        }

        setState(.synced)
        self.syncUrl = nil
        completion?(nil, changesMade)
      }
    }
  }

  func save() {
    guard let account = AccountsManager.shared.currentAccount?.uuid,
          let registryUrl = registryUrl(for: account)
    else { return }

    let snapshot = store.registrySnapshot()
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

  func saveSync() {
    guard let account = AccountsManager.shared.currentAccount?.uuid,
          let registryUrl = registryUrl(for: account)
    else { return }

    let snapshot = store.registrySnapshot()
    let registryObject = [TPPBookRegistryKey.records.rawValue: snapshot]

    do {
      let directoryURL = registryUrl.deletingLastPathComponent()
      if !FileManager.default.fileExists(atPath: directoryURL.path) {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
      }
      let registryData = try JSONSerialization.data(withJSONObject: registryObject, options: .fragmentsAllowed)
      try registryData.write(to: registryUrl, options: .atomic)
      Log.debug(#file, "Synchronously saved registry to disk")
    } catch {
      Log.error(#file, "Error saving book registry synchronously: \(error.localizedDescription)")
    }
  }

  func validateDownloadedContent() {
    guard let account = AccountsManager.shared.currentAccount?.uuid else { return }

    var didChange = false
    store.mutateRegistrySync { registry in
      for (identifier, record) in registry {
        guard record.state == .downloadSuccessful || record.state == .used else { continue }
        let fileExists = self.checkIfBookFileExists(for: record.book, account: account)
        if !fileExists {
          Log.warn(#file, "Post-update validation: '\(record.book.title)' file missing - marking as downloadNeeded")
          registry[identifier]?.state = .downloadNeeded
          didChange = true
        }
      }
    }
    if didChange {
      save()
      DispatchQueue.main.async {
        NotificationCenter.default.post(name: .TPPBookRegistryDidChange, object: nil)
      }
    }
  }

  func reset(_ account: String) {
    syncUrl = nil
    store.removeAll()
    if let registryUrl = registryUrl(for: account) {
      do {
        try FileManager.default.removeItem(at: registryUrl)
      } catch {
        Log.error(#file, "Error deleting registry data: \(error.localizedDescription)")
      }
    }
  }

  func checkIfBookFileExists(for book: TPPBook, account: String) -> Bool {
    guard let bookURL = MyBooksDownloadCenter.shared.fileUrl(for: book, account: account) else {
      return false
    }

    let fileExists = FileManager.default.fileExists(atPath: bookURL.path)

    #if LCP
    if LCPAudiobooks.canOpenBook(book) {
      let licenseURL = bookURL.deletingPathExtension().appendingPathExtension("lcpl")
      let licenseExists = FileManager.default.fileExists(atPath: licenseURL.path)

      if licenseExists {
        Log.debug(#file, "  LCP audiobook license file exists (content file: \(fileExists ? "yes" : "streaming-only"))")
        return true
      }

      return fileExists
    }
    #endif

    return fileExists
  }
}

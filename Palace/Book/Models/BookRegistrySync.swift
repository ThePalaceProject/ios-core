import Foundation
import PalaceLogging
import PalaceCatalog

/// Handles server synchronization for the book registry.
/// Manages syncing loans from the OPDS feed and loading/saving from disk.
class BookRegistrySync {

  private let store: BookRegistryStore
  private let accountsManager: AccountsManager
  /// Resolved lazily because `MyBooksDownloadCenter` reads the registry
  /// via `AppContainer.production().bookRegistry` for its own default args
  /// — taking the instance at BookRegistrySync construction time would
  /// deadlock the static-let initialization chain (BookRegistrySync is
  /// constructed inside `TPPBookRegistry.init` which runs while
  /// `AppContainer._cached` is still resolving). The closure runs only
  /// inside async dispatched blocks, by which point
  /// `AppContainer.production().downloadCenter` has settled.
  private let downloadCenterProvider: () -> MyBooksDownloadCenter
  private let opdsFeedServiceProvider: () -> OPDSFeedService
  private let registryFolderName = "registry"
  private let registryFileName = "registry.json"
  /// Serial queue for disk writes — prevents out-of-order save races where a stale
  /// snapshot could overwrite a newer one if two saves dispatch concurrently.
  private let diskWriteQueue = DispatchQueue(label: "com.palace.registryDiskWrite")

  var syncUrl: URL?
  var loadingAccount: String?

  /// Resolved-on-demand accessors. Tests may inject closures returning
  /// fakes; production wires `AppContainer.production().downloadCenter`
  /// (and the `.shared` OPDS feed service) at construction time.
  private var downloadCenter: MyBooksDownloadCenter { downloadCenterProvider() }
  private var opdsFeedService: OPDSFeedService { opdsFeedServiceProvider() }

  init(
    store: BookRegistryStore,
    accountsManager: AccountsManager,
    downloadCenterProvider: @escaping () -> MyBooksDownloadCenter,
    opdsFeedServiceProvider: @escaping () -> OPDSFeedService
  ) {
    self.store = store
    self.accountsManager = accountsManager
    self.downloadCenterProvider = downloadCenterProvider
    self.opdsFeedServiceProvider = opdsFeedServiceProvider
  }

  func registryUrl(for account: String) -> URL? {
    return TPPBookContentMetadataFilesHelper.directory(for: account)?
      .appendingPathComponent(registryFolderName)
      .appendingPathComponent(registryFileName)
  }

  func load(
    account: String?,
    setState: @escaping (TPPBookRegistry.RegistryState) -> Void,
    completion: (() -> Void)? = nil
  ) {
    guard let account = account ?? accountsManager.currentAccountId,
          let url = registryUrl(for: account)
    else {
      completion?()
      return
    }

    // Prevent re-entrant loads for the same account
    if loadingAccount == account {
      Log.debug(#file, "Skipping duplicate load for account: \(account) (already loading)")
      completion?()
      return
    }

    loadingAccount = account
    Log.info(#file, "Loading registry for account: \(account)")
    DispatchQueue.main.async {
      setState(.loading)
    }

    store.mutateRegistry { [weak self] registry in
      guard let self else { return }

      // PP-4129: books whose registry state says "downloaded" but whose content file
      // has vanished. After the load settles on main we schedule a silent background
      // re-download so the user doesn't end up on the helpspot #17669 "can't open,
      // can't delete, loops on missing file" path.
      var lcpBooksNeedingBackgroundRedownload = [TPPBook]()
      var orphanedBooksNeedingRedownload = [TPPBook]()

      var newRegistry = [String: TPPBookRegistryRecord]()
      if FileManager.default.fileExists(atPath: url.path),
         let data = try? Data(contentsOf: url),
         let json = try? JSONSerialization.jsonObject(with: data) as? TPPBookRegistryData,
         let records = json.array(for: .records) {

        Log.debug(#file, "  Found \(records.count) books in registry")

        for obj in records {
          guard let record = TPPBookRegistryRecord(record: obj) else { continue }
          let originalState = record.state

          // Validate file existence for download states. `.used` is included
          // because a book that has been opened at least once transitions from
          // .downloadSuccessful to .used, and if its file was evicted pre-fix
          // the reader otherwise shows "unable to load PDF/EPUB" instead of
          // the correct "Download" affordance. Treat missing-file the same
          // as .downloadSuccessful: flip to .downloadNeeded and schedule
          // auto-restart.
          if record.state == .downloading || record.state == .SAMLStarted || record.state == .downloadSuccessful || record.state == .downloadNeeded || record.state == .used {
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
            } else if record.state == .downloadNeeded {
              // Migration heal: the pre-PR-#856 sync-before-load race (plus the
              // UpdatedKey parse regression that silently dropped records during
              // load) could leave a downloaded book persisted as .downloadNeeded
              // even though its content file was still on disk. If we see that
              // combination now, promote to .downloadSuccessful so the user
              // doesn't get a spurious "Download" button for a book they already
              // have locally. No-op for the normal case where .downloadNeeded
              // genuinely has no file.
              if fileExists {
                Log.info(#file, "  '\(record.book.title)' state was .downloadNeeded but file present — healing to .downloadSuccessful")
                record.state = .downloadSuccessful
              }
            } else if record.state == .used {
              // A book the user has opened at least once. If its content file
              // was evicted by the LRU budget (pre-fix) the reader fails to
              // load with "unable to open PDF/EPUB". Same heal as
              // .downloadSuccessful: flip to .downloadNeeded + auto-restart.
              if !fileExists {
                Log.error(#file, "  '\(record.book.title)' was .used but FILE MISSING — marking as download needed")
                record.state = .downloadNeeded
                orphanedBooksNeedingRedownload.append(record.book)
              } else {
                Log.debug(#file, "  '\(record.book.title)' used and file verified")
              }
            } else if record.state == .downloadSuccessful {
              if !fileExists {
                Log.error(#file, "  '\(record.book.title)' marked as downloaded but FILE MISSING - marking as download needed")
                Log.error(#file, "     This suggests the file was deleted or the path is wrong")
                record.state = .downloadNeeded
                orphanedBooksNeedingRedownload.append(record.book)
              } else {
                #if LCP
                // LCP audiobooks pass checkIfBookFileExists as soon as the .lcpl
                // license exists (playable via streaming). If the .lcpa content
                // file is missing, schedule a silent background re-download so
                // subsequent opens use the local copy instead of ranged reads
                // from GCS (PP-3704).
                if LCPAudiobooks.canOpenBook(record.book),
                   let bookURL = downloadCenter.fileUrl(for: record.book, account: account),
                   !FileManager.default.fileExists(atPath: bookURL.path) {
                  Log.warn(#file, "  '\(record.book.title)' LCP audiobook playable via streaming but .lcpa MISSING - scheduling background re-download")
                  lcpBooksNeedingBackgroundRedownload.append(record.book)
                } else {
                  Log.debug(#file, "  '\(record.book.title)' downloaded and file verified")
                }
                #else
                Log.debug(#file, "  '\(record.book.title)' downloaded and file verified")
                #endif
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
        guard let self else {
          completion?()
          return
        }

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

        // Fire the completion AFTER state is .loaded and subscribers have been
        // notified — callers that chain sync() off load (e.g. the account-change
        // observer, AppDelegate cold-launch) need the store populated before
        // sync's reconciliation runs.
        completion?()

        // PP-4129: schedule recovery for orphaned downloads. Each scheduled block
        // re-checks that the account that ran the load is still current before
        // firing downloads — switching libraries during the wait would otherwise
        // kick off a re-download with the wrong auth context.
        #if LCP
        if !lcpBooksNeedingBackgroundRedownload.isEmpty {
          Log.info(#file, "  Scheduling background .lcpa re-download for \(lcpBooksNeedingBackgroundRedownload.count) orphaned LCP audiobook(s)")
          DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [accountsManager, downloadCenter] in
            guard accountsManager.currentAccountId == loadedAccount else {
              Log.info(#file, "  Skipping LCP background re-download — account changed during wait")
              return
            }
            for book in lcpBooksNeedingBackgroundRedownload {
              downloadCenter.redownloadLCPContentFile(for: book)
            }
          }
        }
        #endif

        if !orphanedBooksNeedingRedownload.isEmpty {
          Log.info(#file, "  Scheduling auto-restart for \(orphanedBooksNeedingRedownload.count) orphaned download(s)")
          DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [accountsManager, downloadCenter] in
            guard accountsManager.currentAccountId == loadedAccount else {
              Log.info(#file, "  Skipping orphan auto-restart — account changed during wait")
              return
            }
            for book in orphanedBooksNeedingRedownload {
              downloadCenter.startDownload(for: book)
            }
          }
        }
      }
    }
  }

  func sync(
    currentState: TPPBookRegistry.RegistryState,
    setState: @escaping (TPPBookRegistry.RegistryState) -> Void,
    completion: ((_ errorDocument: [AnyHashable: Any]?, _ newBooks: Bool) -> Void)? = nil
  ) {
    // Guard against running sync() before load() has populated the in-memory
    // registry. If we reach the reconciliation block below with an empty store,
    // every loan in the feed is written as a fresh .downloadNeeded record —
    // overwriting the on-disk file and destroying location/bookmarks for every
    // previously-downloaded book. On cold launches the only path that calls
    // load() is the account-change observer; if its notification is missed
    // (race with singleton init on a background queue) or if load's disk I/O
    // is still in flight when a view triggers sync(), this guard is the last
    // line of defence.
    if currentState == .unloaded || currentState == .loading {
      Log.warn(#file, "sync() called before load completed (state=\(currentState)) — skipping to protect on-disk state")
      return
    }

    // Capture the syncing account at the top so that if the user switches
    // libraries while the feed fetch is in flight, we persist the result to
    // the account that was syncing — not the one that happens to be current
    // when the save commits (PP-4129 regression).
    guard let currentAccount = accountsManager.currentAccount,
          let loansUrl = currentAccount.loansUrl
    else { return }
    let accountUUID = currentAccount.uuid

    // Skip the loans fetch when no credentials are stored for the current
    // account. The `loansUrl` from the OPDS auth document is only useful
    // when we can authenticate the request — without credentials we get a
    // guaranteed 401 (or get blocked by the test stub during instrumented
    // runs). Originally written as `!needsAuth && !hasCredentials` to
    // target anonymous libraries, but chaos-qa dogfood-4 surfaced that
    // `needsAuth` returns conservatively-true during the relaunch
    // hydration race (auth document not yet loaded), defeating the gate.
    // The `hasCredentials` check alone is sufficient: post-sign-in the
    // auth-state-changed observer triggers a fresh sync(); during the
    // unhydrated window we just defer.
    //
    // Discovered by chaos-qa dogfood-3 → F-007 (PP-4164).
    // Refined by chaos-qa dogfood-4 → F-DG4-001.
    let userAccount = TPPUserAccount.sharedAccount(libraryUUID: accountUUID)
    if !userAccount.hasCredentials() {
      Log.debug(#file, "Skipping loans sync — no credentials for account \(accountUUID)")
      setState(.loaded)
      completion?(nil, false)
      return
    }

    if currentState == .syncing { return }

    setState(.syncing)
    syncUrl = loansUrl

    Task { [weak self] in
      guard let self else { return }

      let feed: TPPOPDSFeed
      do {
        feed = try await opdsFeedService.fetchFeed(from: loansUrl, resetCache: true)
      } catch {
        let errorDocument = (error as NSError).userInfo as? [AnyHashable: Any]
        Log.warn(#file, "Loans sync failed: \(error.localizedDescription)")
        await MainActor.run {
          setState(.loaded)
          self.syncUrl = nil
          completion?(errorDocument, false)
        }
        return
      }

      await MainActor.run { [weak self] in
        guard let self else { return }
        if self.syncUrl != loansUrl { return }

        var changesMade = false
        // Collected inside the barrier; the filesystem deletes (which resolve
        // the content file URL and touch audiobook manifests on disk) run AFTER
        // the barrier releases. Calling deleteLocalContent inside the barrier
        // re-enters the registry via bookRegistry.book(forIdentifier:) and trips
        // Swift's exclusivity trap — same class of bug as the save() note below.
        var booksToDeleteLocally: [TPPBook] = []
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
                book.defaultAcquisition?.availability.match(unavailable:
                  nil, limited: nil, unlimited: nil,
                  reserved: { _ in nextState = .holding },
                  ready: { _ in nextState = .holding }
                )
              }
              NotificationService.compareAvailability(cachedRecord: record, andNewBook: book)
              // Preserve metadata already in the registry if the loans feed's
              // entry for this book came back lean (authors / summary /
              // categories missing). The CM's loans endpoint has been observed
              // to omit those fields intermittently — without this guard, a
              // later sync overwrites a previously-enriched record and MyBooks
              // cells lose their author line until a catalog visit refills it.
              let mergedBook = record.book.mergingPreservingMetadata(from: book)
              registry[book.identifier] = TPPBookRegistryRecord(
                book: mergedBook,
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

          let shouldSkipBulkDeletion = BookRegistrySync.shouldSkipBulkDeletion(
            localCount: localCount, feedCount: feedCount, deletionCount: deletionCount
          )

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
                booksToDeleteLocally.append(record.book)
              }

              registry[identifier]?.state = .unregistered
              registry.removeValue(forKey: identifier)
              changesMade = true
            }
          }
          // NOTE: do NOT call save(for:) inside the mutateRegistrySync barrier —
          // save() reads the store's snapshot via performSync, which tries to
          // re-enter registry access while this barrier still holds the `inout`
          // on it. That triggers a Swift exclusivity trap ("Simultaneous
          // accesses to registry, but modification requires exclusive access").
          // The save call lives below, after the barrier has released.
        }

        // Run the filesystem deletes outside the barrier. Using the book-based
        // overload so the call never re-enters the registry to look up the book
        // by identifier (the record is already gone at this point anyway).
        for book in booksToDeleteLocally {
          downloadCenter.deleteLocalContent(forBook: book, account: accountUUID)
        }

        if changesMade {
          self.save(for: accountUUID)
        }

        setState(.synced)
        self.syncUrl = nil
        completion?(nil, changesMade)
      }
    }
  }

  /// Persist the registry for the given account. The caller MUST pass the account
  /// that owns the mutation being persisted (captured synchronously at the moment
  /// of dispatch), not `accountsManager.currentAccount` looked up at save
  /// time. In async flows, a mutation queued on account A can execute after the
  /// user has switched to account B; looking up the current account inside `save()`
  /// would persist A's state to B's registry file and cause cross-account
  /// contamination (PP-4129 regression).
  func save(for account: String) {
    guard let registryUrl = registryUrl(for: account) else { return }

    let snapshot = store.registrySnapshot()
    let registryObject = [TPPBookRegistryKey.records.rawValue: snapshot]

    diskWriteQueue.async {
      do {
        let directoryURL = registryUrl.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
          try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        BackupExclusionMigration.excludeFromBackup(directoryURL)
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

  /// Blocking save — used on teardown (scene disconnect, last-read-position) where
  /// the caller cannot yield. Same account-capture contract as `save(for:)`.
  func saveSync(for account: String) {
    guard let registryUrl = registryUrl(for: account) else { return }

    let snapshot = store.registrySnapshot()
    let registryObject = [TPPBookRegistryKey.records.rawValue: snapshot]

    do {
      let directoryURL = registryUrl.deletingLastPathComponent()
      if !FileManager.default.fileExists(atPath: directoryURL.path) {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
      }
      BackupExclusionMigration.excludeFromBackup(directoryURL)
      let registryData = try JSONSerialization.data(withJSONObject: registryObject, options: .fragmentsAllowed)
      try registryData.write(to: registryUrl, options: .atomic)
      Log.debug(#file, "Synchronously saved registry to disk")
    } catch {
      Log.error(#file, "Error saving book registry synchronously: \(error.localizedDescription)")
    }
  }

  func validateDownloadedContent() {
    guard let account = accountsManager.currentAccount?.uuid else { return }

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
      save(for: account)
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

  /// Decides whether a sync() reconciliation should skip deleting books that
  /// are absent from the feed response.
  ///
  /// Any empty feed paired with any non-empty local registry is treated as a
  /// transient server/CDN error rather than a legitimate "all loans returned".
  /// The prior `localCount > 2` floor let 1- and 2-book shelves fall through
  /// and delete every downloaded book on a single bad response — the pattern
  /// that caused previously-downloaded books to show "Download" again after
  /// relaunch across a wifi→cellular→wifi transition.
  ///
  /// Static + internal so tests can call it directly without mocking the full
  /// feed-fetch pipeline.
  static func shouldSkipBulkDeletion(localCount: Int, feedCount: Int, deletionCount: Int) -> Bool {
    return localCount >= 1 && feedCount == 0 && deletionCount > 0
  }

  func checkIfBookFileExists(for book: TPPBook, account: String) -> Bool {
    guard let bookURL = downloadCenter.fileUrl(for: book, account: account) else {
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

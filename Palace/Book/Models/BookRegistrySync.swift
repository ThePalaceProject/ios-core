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

  /// Upper bound on how long a single `sync()` pass will block on the current
  /// account's `awaitReady()` before giving up and reverting to `.loaded` so a
  /// later trigger retries. Without a bound, a wedged `authentication_document`
  /// fetch (its network completion dropped, account stuck at `.detailsLoading`)
  /// makes `awaitReady()` hang forever — registry sync never completes, My Books
  /// shows empty, and an incidental empty save can then persist over the good
  /// on-disk shelf (HelpSpot #18414 data-loss). 30s is comfortably above a
  /// healthy auth-doc round-trip while still self-healing a dropped-completion
  /// wedge within one foreground/account-change retry cycle.
  static let authReadinessTimeout: TimeInterval = 30
  /// Serial queue for disk writes — prevents out-of-order save races where a stale
  /// snapshot could overwrite a newer one if two saves dispatch concurrently.
  private let diskWriteQueue = DispatchQueue(label: "com.palace.registryDiskWrite")
  /// Identifies execution already inside `diskWriteQueue` so a reentrant
  /// `saveSync` runs its write inline instead of a nested `diskWriteQueue.sync`
  /// (which would deadlock). See `saveSync(for:)`.
  private let diskWriteQueueKey = DispatchSpecificKey<Void>()

  var syncUrl: URL?
  var loadingAccount: String?

  /// INV-1 (Reliability WS-B / #1212): set true when `load` finds the registry
  /// file corrupt/unrecoverable and leaves the in-memory shelf empty. While
  /// true, `save(for:)`/`saveSync(for:)` refuse to persist an EMPTY snapshot
  /// over a non-empty last-good `.bak` unless the save is marked
  /// server-authoritative (`sync()`'s loans-feed reconciliation). Cleared by the
  /// next successful non-empty or authoritative save. Lock-guarded so the
  /// disk-write queue can read it race-free against the main-thread publish.
  private let rebuildFlagLock = NSLock()
  private var _needsRebuildFromServer = false
  var needsRebuildFromServer: Bool {
    get { rebuildFlagLock.lock(); defer { rebuildFlagLock.unlock() }; return _needsRebuildFromServer }
    set { rebuildFlagLock.lock(); defer { rebuildFlagLock.unlock() }; _needsRebuildFromServer = newValue }
  }

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
    diskWriteQueue.setSpecific(key: diskWriteQueueKey, value: ())
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
      var needsRebuild = false

      // Reliability WS-B / INV-1 (#1212): distinguish an ABSENT registry file
      // from an existing-but-CORRUPT one. The old code conflated both into a
      // single `else` that silently zeroed the shelf, and the next save() then
      // overwrote the (recoverable) corrupt file with a valid-but-empty one —
      // erasing the patron's whole shelf on a single bad write. We now classify
      // the bytes, quarantine a corrupt file (never destroy), and try the
      // last-good `.bak` before falling back to empty + a rebuild flag.
      let fileExists = FileManager.default.fileExists(atPath: url.path)
      let fileData: Data? = fileExists ? try? Data(contentsOf: url) : nil
      let classification: RegistryFileRecovery.Classification
      if !fileExists {
        classification = .empty
      } else if let fileData {
        classification = RegistryFileRecovery.classify(data: fileData)
      } else {
        // File exists but could not be read — treat as corrupt (recoverable).
        classification = .corrupt
      }

      var recordsToParse: [TPPBookRegistryData]? = nil
      switch classification {
      case .valid(let records):
        recordsToParse = records
        if RegistryFileRecovery.needsMigration(data: fileData) {
          Log.info(#file, "  Registry file is unversioned (legacy) — will migrate to schema v\(RegistryFileRecovery.currentSchemaVersion) on next save")
        }
      case .empty:
        Log.info(#file, "  No existing registry file found — starting with an empty registry")
      case .corrupt:
        Log.error(#file, "  Registry file exists but is CORRUPT — quarantining (never overwriting/destroying)")
        if let quarantined = RegistryFileRecovery.quarantine(corruptFileAt: url) {
          Log.error(#file, "  Quarantined corrupt registry to \(quarantined.lastPathComponent)")
        }
        if let recovered = RegistryFileRecovery.recoverFromBackup(for: url) {
          Log.info(#file, "  Recovered \(recovered.count) record(s) from last-good .bak backup")
          recordsToParse = recovered
        } else {
          Log.error(#file, "  No usable .bak backup — leaving registry empty and flagging needsRebuildFromServer (next authenticated sync repopulates from the loans feed)")
          needsRebuild = true
        }
      }

      if let records = recordsToParse {

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
            let presence = self.contentPresence(for: record.book, account: account)
            let fileExists = presence != .absent

            if record.state == .downloading {
              if self.isDownloadInFlight(for: record.book) {
                // A warm `load()` (foreground, hold change) can land in the
                // middle of a healthy multi-minute `.lcpa` transfer. Leave it be;
                // its own completion will settle the state.
                Log.debug(#file, "  '\(record.book.title)' is downloading and a transfer is in flight — leaving alone")
              } else {
                switch presence {
                case .present:
                  Log.info(#file, "  '\(record.book.title)' was downloading but file exists - marking as successful")
                  record.state = .downloadSuccessful
                case .licenseOnly:
                  // Interrupted between the license landing and the content
                  // arriving. Not playable, and it must not be promoted to
                  // `.downloadSuccessful` — that offers Listen with no audio and
                  // skips the content re-download scheduled from the
                  // `.downloadSuccessful` arm below.
                  Log.warn(#file, "  '\(record.book.title)' was downloading with license but no content - marking download needed and scheduling content re-download")
                  record.state = .downloadNeeded
                  lcpBooksNeedingBackgroundRedownload.append(record.book)
                case .absent:
                  Log.warn(#file, "  '\(record.book.title)' was downloading but file missing - marking as failed")
                  record.state = .downloadFailed
                }
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
              // Only REAL content heals this. Promoting on a license alone is
              // how the interrupted-download case came back one load later: the
              // arm above writes `.downloadNeeded`, and this heal then promoted
              // it straight to `.downloadSuccessful` on the next launch.
              switch presence {
              case .present:
                Log.info(#file, "  '\(record.book.title)' state was .downloadNeeded but content present — healing to .downloadSuccessful")
                record.state = .downloadSuccessful
              case .licenseOnly:
                Log.debug(#file, "  '\(record.book.title)' has a license but no content — scheduling content re-download")
                lcpBooksNeedingBackgroundRedownload.append(record.book)
              case .absent:
                break
              }
            } else if record.state == .used {
              // A book the user has opened at least once. If its content file
              // was evicted by the LRU budget (pre-fix) the reader fails to
              // load with "unable to open PDF/EPUB". Same heal as
              // .downloadSuccessful: flip to .downloadNeeded + auto-restart.
              switch presence {
              case .present:
                Log.debug(#file, "  '\(record.book.title)' used and content verified")
              case .licenseOnly:
                Log.error(#file, "  '\(record.book.title)' was .used but content MISSING (license only) — marking download needed and scheduling content re-download")
                record.state = .downloadNeeded
                lcpBooksNeedingBackgroundRedownload.append(record.book)
              case .absent:
                Log.error(#file, "  '\(record.book.title)' was .used but FILE MISSING — marking as download needed")
                record.state = .downloadNeeded
                orphanedBooksNeedingRedownload.append(record.book)
              }
            } else if record.state == .downloadSuccessful {
              // The PP-3704 special case that used to live here — re-derive
              // "LCP audiobook with a license but no .lcpa" inline — is now the
              // `.licenseOnly` case of the shared predicate.
              switch presence {
              case .present:
                Log.debug(#file, "  '\(record.book.title)' downloaded and content verified")
              case .licenseOnly:
                // Was marked playable, but the content is gone. Streaming can no
                // longer cover for it, so report it honestly and re-fetch in the
                // background (PP-3704 lineage).
                Log.warn(#file, "  '\(record.book.title)' LCP audiobook has a license but the .lcpa is MISSING - marking download needed and scheduling background re-download")
                record.state = .downloadNeeded
                lcpBooksNeedingBackgroundRedownload.append(record.book)
              case .absent:
                Log.error(#file, "  '\(record.book.title)' marked as downloaded but FILE MISSING - marking as download needed")
                Log.error(#file, "     This suggests the file was deleted or the path is wrong")
                record.state = .downloadNeeded
                orphanedBooksNeedingRedownload.append(record.book)
              }
            }

            if originalState != record.state {
              Log.info(#file, "  State changed for '\(record.book.title)': \(originalState) -> \(record.state)")
            }
          }

          newRegistry[record.book.identifier] = record
        }
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

        // INV-1: publish the rebuild flag on main (matches this class's
        // main-thread-confinement invariant for its mutable state). While set,
        // save() refuses to persist an empty snapshot over a non-empty backup
        // until an authoritative server sync repopulates the shelf.
        self.needsRebuildFromServer = needsRebuild

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
    guard let currentAccount = accountsManager.currentAccount else { return }
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

    Task { [weak self] in
      guard let self else { return }

      // PHASE 1 (swarm_81b5099e Bucket A — PP-4407): the loansUrl read used
      // to happen on the sync `sync()` call frame above. Hoisted into the
      // Task block so we can await `Account.LoadState` readiness via
      // `awaitReady()`. Pre-Phase-1 this silently returned on first cold-
      // launch (details still loading → loansUrl nil → guard bailed →
      // registry stuck `.loaded` empty until the next sync trigger). Now
      // we block on terminal state, but BOUNDED by `authReadinessTimeout`
      // (HelpSpot #18414): a wedged auth-doc fetch used to hang this await
      // forever. On any `AccountLoadError` — including `.readinessTimedOut` —
      // we revert state to `.loaded` so BookRegistrySync's own retry policy
      // (`waitForLoadThenRunSync` / account-change notifications) drives the
      // next attempt. Crucially, aborting here means we NEVER reach the
      // reconciliation/save block with an empty in-memory shelf, so a wedge
      // cannot trigger an empty-over-good persist.
      let details: AccountDetails
      do {
        details = try await currentAccount.awaitReady(timeout: Self.authReadinessTimeout)
      } catch {
        Log.warn(#file, "BookRegistrySync abort: awaitReady failed for \(accountUUID): \(error)")
        await MainActor.run {
          setState(.loaded)
          self.syncUrl = nil
          completion?(nil, false)
        }
        return
      }

      guard let loansUrl = details.loansUrl else {
        Log.debug(#file, "BookRegistrySync abort: account \(accountUUID) has no loansUrl after awaitReady — anonymous library")
        await MainActor.run {
          setState(.loaded)
          self.syncUrl = nil
          completion?(nil, false)
        }
        return
      }

      await MainActor.run { [weak self] in
        self?.syncUrl = loansUrl
      }

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
          // Server-authoritative: this snapshot is the result of reconciling
          // against the loans feed (guarded by shouldSkipBulkDeletion), so it is
          // allowed to persist an empty shelf and it clears needsRebuildFromServer.
          self.save(for: accountUUID, serverAuthoritative: true)
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
    save(for: account, serverAuthoritative: false)
  }

  /// - Parameter serverAuthoritative: `true` only when the snapshot being
  ///   persisted is the result of an authoritative server reconciliation
  ///   (`sync()`'s loans-feed pass). An authoritative save may persist an empty
  ///   registry (e.g. all loans genuinely returned) and clears
  ///   `needsRebuildFromServer`. A non-authoritative save (local mutation,
  ///   content validation) is REFUSED when it would overwrite a non-empty
  ///   last-good `.bak` with an empty snapshot during the post-corrupt rebuild
  ///   window (INV-1).
  func save(for account: String, serverAuthoritative: Bool) {
    guard let registryUrl = registryUrl(for: account) else { return }

    let snapshot = store.registrySnapshot()
    let isEmpty = snapshot.isEmpty
    let needsRebuild = needsRebuildFromServer
    let registryObject: [String: Any] = [
      RegistryFileRecovery.schemaVersionKey: RegistryFileRecovery.currentSchemaVersion,
      TPPBookRegistryKey.records.rawValue: snapshot
    ]

    diskWriteQueue.async { [self] in
      // INV-1 (broadened, HelpSpot #18414): only an authoritative server sync
      // may persist an EMPTY shelf over a non-empty on-disk registry. Refuse any
      // NON-authoritative empty save whenever a non-empty shelf exists on disk —
      // whether via the last-good `.bak` (post-corrupt rebuild window) OR the
      // primary file itself. D1 guarded only the `needsRebuild` window; that
      // missed the wedge path where the shelf was never corrupted (no `.bak`
      // minted) but registry sync wedged, leaving an empty in-memory shelf about
      // to clobber a healthy primary. A genuine zero-book patron still persists
      // empty via `sync()`'s authoritative save (serverAuthoritative == true),
      // so nobody is trapped.
      if isEmpty, !serverAuthoritative,
         (needsRebuild || RegistryFileRecovery.onDiskHasRecords(for: registryUrl)) {
        Log.error(#file, "INV-1: refusing to persist an EMPTY registry (no server authority) over a non-empty on-disk shelf — needsRebuild: \(needsRebuild), onDiskHasRecords: \(RegistryFileRecovery.onDiskHasRecords(for: registryUrl))")
        return
      }
      do {
        let directoryURL = registryUrl.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
          try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        directoryURL.excludeFromBackup()
        let registryData = try JSONSerialization.data(withJSONObject: registryObject, options: .fragmentsAllowed)
        // Refresh the last-good `.bak` BEFORE overwriting the primary, but only
        // for a good snapshot (non-empty, or a server-authoritative empty) so a
        // transient empty can never clobber the backup.
        if !isEmpty || serverAuthoritative {
          try? RegistryFileRecovery.writeBackup(data: registryData, for: registryUrl)
        }
        try registryData.write(to: registryUrl, options: .atomic)
        if !isEmpty || serverAuthoritative {
          needsRebuildFromServer = false
        }
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

    // Snapshot in the CALLER's context — NOT inside `diskWriteQueue`. `saveSync`
    // is reached from `BookmarkManager.setLocationSync`'s `onComplete`, which
    // runs inside a `BookRegistryStore.syncQueue` barrier. Taking the snapshot
    // inside `diskWriteQueue.sync` re-entered `syncQueue` (`registrySnapshot` →
    // `performSync` → `syncQueue.sync`) from a thread already holding that
    // barrier → deadlock (8afb1c66 — the hang #1061 traded for the disk-write
    // race). The in-memory snapshot is independent of disk-flush ordering, so
    // reading it here is behavior-equivalent for persistence.
    let snapshot = store.registrySnapshot()
    let isEmpty = snapshot.isEmpty
    let needsRebuild = needsRebuildFromServer
    let registryObject: [String: Any] = [
      RegistryFileRecovery.schemaVersionKey: RegistryFileRecovery.currentSchemaVersion,
      TPPBookRegistryKey.records.rawValue: snapshot
    ]

    // Serialize the disk write through `diskWriteQueue` so a sync save can't run
    // its `.atomic` rename-replace concurrently with an in-flight async write to
    // the same URL (the race #1061 fixed — preserved). Reentrancy-safe: if we are
    // ALREADY executing on `diskWriteQueue`, run inline — a nested
    // `diskWriteQueue.sync` would deadlock against itself.
    let write = {
      // INV-1 (broadened, HelpSpot #18414): saveSync is teardown persistence
      // (bookmarks/location), never a server reconciliation — so it is always
      // non-authoritative. Refuse an empty snapshot whenever a non-empty shelf
      // exists on disk (primary OR `.bak`), not only during the corrupt-rebuild
      // window — a bookmark-flush on scene disconnect must never erase a healthy
      // primary while an in-memory shelf is transiently empty (e.g. sync wedged).
      if isEmpty,
         (needsRebuild || RegistryFileRecovery.onDiskHasRecords(for: registryUrl)) {
        Log.error(#file, "INV-1: refusing synchronous EMPTY registry save over a non-empty on-disk shelf — needsRebuild: \(needsRebuild), onDiskHasRecords: \(RegistryFileRecovery.onDiskHasRecords(for: registryUrl))")
        return
      }
      do {
        let directoryURL = registryUrl.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
          try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        directoryURL.excludeFromBackup()
        let registryData = try JSONSerialization.data(withJSONObject: registryObject, options: .fragmentsAllowed)
        if !isEmpty {
          try? RegistryFileRecovery.writeBackup(data: registryData, for: registryUrl)
        }
        try registryData.write(to: registryUrl, options: .atomic)
        if !isEmpty {
          self.needsRebuildFromServer = false
        }
        Log.debug(#file, "Synchronously saved registry to disk")
      } catch {
        Log.error(#file, "Error saving book registry synchronously: \(error.localizedDescription)")
      }
    }

    if DispatchQueue.getSpecific(key: diskWriteQueueKey) != nil {
      write()
    } else {
      diskWriteQueue.sync(execute: write)
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
      // Also drop the 3.2.3 sidecars (last-good `.bak` + `.corrupt-<ts>`
      // quarantine copies). Deleting only the primary left the signed-out
      // patron's whole shelf readable on disk and recoverable into the next
      // patron's session at the same library.
      RegistryFileRecovery.purgeSidecars(for: registryUrl)
    }
    needsRebuildFromServer = false
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

  /// What is actually on disk for a book.
  ///
  /// `checkIfBookFileExists` answers a weaker question: for an LCP audiobook it
  /// reports `true` on the `.lcpl` LICENSE alone, because while streaming worked
  /// a license WAS enough to play. That assumption is denormalized across the
  /// reconciliation arms below, and it is the reason three separate defects were
  /// found in this file: each arm independently treated "a file exists" as "the
  /// book is playable", so an interrupted or cancelled LCP download was promoted
  /// to `.downloadSuccessful` and offered a Listen button with no audio behind
  /// it.
  ///
  /// Streaming is unusable upstream, so the license alone no longer means
  /// playable. This makes the distinction explicit and gives every arm one
  /// predicate to consume instead of re-deriving it.
  enum ContentPresence {
    /// Nothing on disk.
    case absent
    /// LCP audiobook whose `.lcpl` license is present but whose `.lcpa` content
    /// package is not. Not playable; recoverable by re-fetching the content.
    case licenseOnly
    /// Real, playable content on disk.
    case present
  }

  func contentPresence(for book: TPPBook, account: String) -> ContentPresence {
    guard let bookURL = downloadCenter.fileUrl(for: book, account: account) else {
      return .absent
    }
    if FileManager.default.fileExists(atPath: bookURL.path) {
      return .present
    }
    #if LCP
    if LCPAudiobooks.canOpenBook(book) {
      let licenseURL = bookURL.deletingPathExtension().appendingPathExtension("lcpl")
      if FileManager.default.fileExists(atPath: licenseURL.path) {
        return .licenseOnly
      }
    }
    #endif
    return .absent
  }

  /// True when the download center is currently transferring this book, so
  /// reconciliation must leave a `.downloading` record alone. `load()` is not
  /// launch-only — `TPPAppDelegate` runs it on foreground and `HoldsViewModel`
  /// on hold changes — so without this a warm load during a multi-minute `.lcpa`
  /// transfer would flip a perfectly healthy in-flight download.
  func isDownloadInFlight(for book: TPPBook) -> Bool {
    downloadCenter.downloadInfo(forBookIdentifier: book.identifier) != nil
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
